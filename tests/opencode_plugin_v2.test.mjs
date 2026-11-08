// Node >= 22.18 is required by these suites: the global cases import the
// plugins' TypeScript sources directly, and only unflagged type stripping
// (Node 22.18+, stable since 24.12) makes that import work. Pin this version in
// CI explicitly instead of relying on the runner's default Node.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, mkdir, copyFile, stat } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const INLINE_SRC = join(HERE, '..', 'resources', 'opencode', 'seance-v2.mjs');
const GLOBAL_SRC = join(HERE, '..', 'plugins', 'seance-opencode', 'index-v2.ts');

// Spawns a bridge the way the production plugin does: execFile without a
// shell, payload on stdin, bounded runtime, killed on timeout. `input: false`
// withholds the payload so a child sees a clean EOF instead of JSON, and
// `interpret: true` runs the bridge through the parent's own node binary
// rather than the kernel's `#!/usr/bin/env node` resolution.
function runBridge(binary, args, payload, { timeout = 5000, env = process.env, input = true, interpret = false } = {}) {
  return new Promise((resolve) => {
    const child = execFile(interpret ? process.execPath : binary, interpret ? [binary, ...args] : args, {
      encoding: 'utf8', maxBuffer: 4096, timeout, killSignal: 'SIGKILL', env,
    }, (error, stdout, stderr) => resolve({ error, stdout, stderr }));
    // EPIPE is expected when a child exits before draining its stdin; the
    // child's own status is what the caller diagnoses.
    child.stdin.on('error', () => {});
    child.stdin.end(input ? JSON.stringify(payload) : '');
  });
}

// Executing the generated fixture bridge once at setup turns a broken child
// environment (node missing from PATH for the shebang, noexec /tmp, unwritable
// capture target) into one diagnosed failure with captured stderr instead of a
// cascade of ENOENTs when tests later read the events file. SEANCE_TEST_CAPTURE
// keeps the preflight emission out of the capture every assertion reads.
async function preflight(t, dir, capture, options = {}) {
  const binary = join(dir, 'seance');
  t.after(() => rm(binary, { force: true }));
  if (!options.missing) {
    const record = options.malformed
      ? `appendFileSync(process.env.SEANCE_TEST_CAPTURE || ${JSON.stringify(capture)}, 'not-json\\n');`
      : `appendFileSync(process.env.SEANCE_TEST_CAPTURE || ${JSON.stringify(capture)}, JSON.stringify({args: process.argv.slice(2), payload: JSON.parse(text), bytes: Buffer.byteLength(text), surface: process.env.SEANCE_SURFACE_ID}) + '\\n');`;
    // A child that receives nothing must say so: the bare JSON.parse error it
    // would otherwise raise cannot be told apart from malformed fixture data.
    const readStdin = options.earlyClose
      ? `process.stdin.destroy();
process.exitCode = 4;
return;`
      : `for await (const chunk of process.stdin) text += chunk;
if (Buffer.byteLength(text) === 0) {
  process.stderr.write('fixture bridge received 0 stdin bytes; no payload reached the child\\n');
  process.exitCode = 3;
  return;
}`;
    const source = `#!/usr/bin/env node
const { appendFileSync } = require('node:fs');
(async () => {
let text = '';
${readStdin}
${record}
${options.hang ? 'setInterval(() => {}, 1000);' : ''}
${options.fail ? 'process.exitCode = 1;' : ''}
})();
`;
    await writeFile(binary, source, { mode: 0o755 });
    // The shebang, trailing newline and exec bit are exactly what the kernel
    // resolves when production code execs the bridge without a shell.
    if (!source.startsWith('#!/usr/bin/env node\n'))
      throw new Error(`fixture bridge shebang is broken: ${JSON.stringify(source.slice(0, 32))}`);
    if (!source.endsWith('\n')) throw new Error('fixture bridge source lost its trailing newline');
    if (!((await stat(binary)).mode & 0o100))
      throw new Error(`fixture bridge is not owner-executable: ${binary}`);
  }
  const { error, stderr } = await runBridge(binary, ['ctl', 'opencode-hook', 'state'],
    { state: 'Fixture preflight' }, { timeout: options.hang ? 600 : 5000,
      input: !options.noInput, env: { ...process.env, SEANCE_TEST_CAPTURE: `${capture}.preflight` } });
  const despawn = `fixture bridge ${binary} preflight failed: ` +
    (error ? `${error.code ?? 'no exit code'}${error.killed ? ` killed (${error.signal})` : ''}; ` : 'child exited cleanly; ') +
    `stderr: ${stderr.trim() || 'empty'}`;
  if (error && (error.code === 'ENOENT' || error.code === 'EACCES'))
    throw new Error(`${despawn} — could not execute the bridge`);
  if (options.hang ? !error?.killed : error && !options.fail)
    throw new Error(despawn);
  if (options.fail && (!error || error.code !== 1))
    throw new Error(`fail bridge exited ${error?.code ?? 0} instead of the expected 1; stderr: ${stderr.trim() || 'empty'}`);
  const raw = await readFile(`${capture}.preflight`, 'utf8').catch((readError) => {
    throw new Error(`fixture bridge preflight record unreadable (${readError.code ?? readError.message}); ${despawn}`);
  });
  let emission;
  try {
    emission = JSON.parse(raw.trim());
  } catch {
    throw new Error(`fixture bridge preflight output is malformed: ${JSON.stringify(raw.trim())}`);
  }
  // The child env snapshot is process.env at preflight time, whatever the
  // fixture's inert mode left in place; missing-vars just compares undefined.
  if (emission.payload.state !== 'Fixture preflight' || emission.surface !== process.env.SEANCE_SURFACE_ID ||
      JSON.stringify(emission.args) !== '["ctl","opencode-hook","state"]')
    throw new Error(`fixture bridge preflight record lost the representative invocation: ${JSON.stringify(emission)}`);
  return binary;
}

async function installStub(sandbox) {
  const pkg = join(sandbox, 'node_modules', '@opencode', 'plugin');
  await mkdir(pkg, { recursive: true });
  await writeFile(join(pkg, 'package.json'),
    JSON.stringify({ name: '@opencode/plugin', version: '0.0.0', type: 'module',
      main: 'index.mjs', exports: { '.': './index.mjs' } }));
  await writeFile(join(pkg, 'index.mjs'), 'export const Plugin = { define: (d) => d };\n');
}

function eventStream() {
  const queue = [];
  let waiter = null;
  let nextCalls = 0;
  let signal = null;
  const wake = () => {
    if (waiter) { const w = waiter; waiter = null; w.resolve(); }
  };
  const abortStream = () => {
    if (waiter) { const w = waiter; waiter = null; w.reject(new Error('event stream aborted')); }
  };
  const iterator = {
    async next() {
      nextCalls++;
      while (queue.length === 0) {
        if (signal?.aborted) throw new Error('event stream aborted');
        await new Promise((resolve, reject) => { waiter = { resolve, reject }; });
      }
      return { done: false, value: queue.shift() };
    },
    async return() { return { done: true, value: undefined }; },
  };
  const iterable = { [Symbol.asyncIterator]: () => iterator };
  return {
    iterable,
    subscribe({ signal: s }) {
      signal = s;
      if (s) s.addEventListener('abort', abortStream);
      return iterable;
    },
    get signal() { return signal; },
    get nextCalls() { return nextCalls; },
    push(value) { queue.push(value); wake(); },
  };
}

async function waitFor(predicate, message, timeout = 4000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${message}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "seance-v2-plugin-' "));
  t.after(() => rm(root, { recursive: true, force: true }));
  const capture = join(root, 'events');
  const previous = { ...process.env };
  try {
    delete process.env.SEANCE_OPENCODE_HOOKS_DISABLED;
    if (options.inert === 'missing-vars') {
      delete process.env.SEANCE_OPENCODE_BIN;
      delete process.env.SEANCE_SOCKET_PATH;
      delete process.env.SEANCE_SURFACE_ID;
      delete process.env.SEANCE_WORKSPACE_ID;
    } else if (options.inert === 'disabled') {
      Object.assign(process.env, { SEANCE_OPENCODE_BIN: join(root, 'seance'), SEANCE_SOCKET_PATH: join(root, 'sock'),
        SEANCE_SURFACE_ID: '3', SEANCE_WORKSPACE_ID: '1', SEANCE_OPENCODE_HOOKS_DISABLED: '1' });
    } else {
      Object.assign(process.env, { SEANCE_OPENCODE_BIN: join(root, 'seance'), SEANCE_SOCKET_PATH: join(root, 'sock'),
        SEANCE_SURFACE_ID: options.surface ?? '3', SEANCE_WORKSPACE_ID: '1' });
    }
    await preflight(t, root, capture, options);

    const sandbox = join(root, 'sandbox');
    await mkdir(sandbox, { recursive: true });
    await installStub(sandbox);
    await copyFile(options.bootFailure ?? options.source ?? INLINE_SRC, join(sandbox, 'plugin.mjs'));
    const mod = await import(pathToFileURL(join(sandbox, 'plugin.mjs')).href);

    const stream = eventStream();
    const toolHooks = {};
    const lookups = [];
    const ctx = {
      event: { subscribe: (opts) => stream.subscribe(opts) },
      tool: { hook: async (name, cb) => { toolHooks[name] = cb; } },
      session: { get: async ({ sessionID }) => {
        lookups.push(sessionID);
        if (options.lookupFailure) throw Error('unavailable');
        return { data: { id: sessionID, parentID: options.parents?.[sessionID] } };
      } },
      client: { session: { list: async () => {
        if (options.listFailure) throw Error('unavailable');
        return { data: options.existingSessions ?? [] };
      } } },
      location: { directory: "/tmp/a 'project'" },
      options: {},
    };
    const cleanup = await mod.default.setup(ctx);
    if (typeof cleanup === 'function') await waitFor(() => stream.nextCalls >= 1, 'event subscription');

    const events = async () => (await readFile(capture, 'utf8')).trim().split('\n')
      .filter(Boolean).map(JSON.parse);
    const notices = async () => (await events()).filter((e) => e.payload.title);
    const last = async () => (await events()).at(-1).payload;
    const commands = async () => (await events()).map((e) => e.args.at(-1));
    let seq = 0;
    async function feed(type, data) {
      const before = stream.nextCalls;
      stream.push({ id: `evt_${++seq}`, created: Date.now(), type, data });
      await waitFor(() => stream.nextCalls >= before + 1, `${type} handled`);
    }
    async function feedBurst(items) {
      const before = stream.nextCalls;
      for (const [type, data] of items) stream.push({ id: `evt_${++seq}`, created: Date.now(), type, data });
      await waitFor(() => stream.nextCalls >= before + items.length, 'burst handled');
    }
    const exec = (name) => {
      assert.ok(toolHooks[name], `tool hook ${name} was registered`);
      return toolHooks[name];
    };
    const missing = async () => readFile(capture, 'utf8').then(() => false, () => true);
    return { root, capture, binary: join(root, 'seance'), cleanup, stream, toolHooks, exec, lookups,
      events, notices, last, commands, feed, feedBurst, missing };
  } finally {
    // A failed import or setup must not leak the SEANCE_* knobs into the next
    // fixture, which would silently flip later hook scaffolding.
    process.env = previous;
  }
}

test('the fixture preflight proves the bridge serves one representative invocation', async (t) => {
  const previous = { ...process.env };
  try {
    Object.assign(process.env, { SEANCE_SURFACE_ID: '3' });
    const root = await mkdtemp(join(tmpdir(), "seance-v2-preflight-' "));
    t.after(() => rm(root, { recursive: true, force: true }));
    const binary = await preflight(t, root, join(root, 'events'));
    assert.ok(binary.endsWith('seance'));
  } finally { process.env = previous; }
});

test('a missing fixture executable fails the preflight with a spawn diagnostic', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'seance-v2-preflight-missing-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(preflight(t, root, join(root, 'events'), { missing: true }),
    ({ message }) => message.includes('ENOENT') && message.includes(join(root, 'seance')));
});

test('the bridge delivers the exact stdin bytes by shebang and explicit interpreter', async (t) => {
  const previous = { ...process.env };
  try {
    Object.assign(process.env, { SEANCE_SURFACE_ID: '3' });
    const root = await mkdtemp(join(tmpdir(), "seance-v2-preflight-stdin-' "));
    t.after(() => rm(root, { recursive: true, force: true }));
    const binary = await preflight(t, root, join(root, 'events'));
    // Multibyte text and shell metacharacters: the count is bytes, not chars.
    const payload = { state: "It’s 'done' ✓", note: 'line\nbreak' };
    for (const route of ['shebang', 'execPath']) {
      const target = join(root, `events-${route}`);
      const { error, stderr } = await runBridge(binary, ['ctl', 'opencode-hook', 'state'], payload,
        { env: { ...process.env, SEANCE_TEST_CAPTURE: target }, interpret: route === 'execPath' });
      assert.equal(error, null, `${route} route failed: ${stderr.trim() || 'no stderr'}`);
      const emission = JSON.parse((await readFile(target, 'utf8')).trim());
      assert.deepEqual(emission.args, ['ctl', 'opencode-hook', 'state']);
      assert.deepEqual(emission.payload, payload);
      assert.equal(emission.bytes, Buffer.byteLength(JSON.stringify(payload)));
    }
  } finally { process.env = previous; }
});

test('the preflight names zero stdin bytes when no payload reaches the child', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'seance-v2-preflight-noinput-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  // The audit signature was a child parsing an empty string; it must read as
  // lost input with a byte count, not as a spawn or fixture-data failure.
  await assert.rejects(preflight(t, root, join(root, 'events'), { noInput: true }), ({ message }) =>
    message.includes('received 0 stdin bytes') && message.includes('preflight failed: 3') &&
    !message.includes('ENOENT') && !message.includes('malformed'));
});

test('the preflight reports a child that closes stdin and exits before reading it', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'seance-v2-preflight-earlyclose-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  // The parent's write hits EPIPE, which the fixture swallows; the child's own
  // status is the only signal, so it must surface as that status.
  await assert.rejects(preflight(t, root, join(root, 'events'), { earlyClose: true }), ({ message }) =>
    message.includes('preflight failed: 4') && message.includes('stderr: empty'));
});

test('malformed fixture output fails the preflight with the raw emission', async (t) => {
  const previous = { ...process.env };
  try {
    const root = await mkdtemp(join(tmpdir(), "seance-v2-preflight-bad-' "));
    t.after(() => rm(root, { recursive: true, force: true }));
    await assert.rejects(preflight(t, root, join(root, 'events'), { malformed: true, surface: '3' }),
      ({ message }) => message.includes('not-json') && message.includes('malformed'));
  } finally { process.env = previous; }
});

test('failed fixture setup restores the captured environment', async (t) => {
  const previous = { ...process.env };
  try {
    for (const key of ['SEANCE_OPENCODE_BIN', 'SEANCE_SOCKET_PATH', 'SEANCE_SURFACE_ID', 'SEANCE_WORKSPACE_ID'])
      delete process.env[key];
    await assert.rejects(fixture(t, { bootFailure: '/this/path/does/not/exist.ts' }), /ENOENT|Cannot find module/);
    assert.deepEqual(
      ['SEANCE_OPENCODE_BIN', 'SEANCE_SOCKET_PATH', 'SEANCE_SURFACE_ID', 'SEANCE_WORKSPACE_ID']
        .filter((key) => key in process.env), []);
  } finally { process.env = previous; }
});

test('inline: starts idle, runs, and reports no completion of its own', async (t) => {
  // Success is announced by ctl's own stop handler (the global plugin sends
  // `stop`), so the inline must stay quiet — a second notice here is the
  // double alert plan 066 removed.
  const f = await fixture(t, { source: INLINE_SRC });
  assert.deepEqual(await f.last(), { state: 'Idle' });
  await f.feed('session.execution.started', { sessionID: 'resumed' });
  assert.equal((await f.last()).state, 'Running');
  await f.feed('session.execution.succeeded', { sessionID: 'resumed' });
  assert.deepEqual(f.lookups, ['resumed']);
  assert.deepEqual(await f.notices(), []);
  assert.deepEqual(await f.last(), { state: 'Idle' });
});

test('inline: subagent completion cannot hide a working parent or announce early', async (t) => {
  const f = await fixture(t);
  await f.feed('session.created', { sessionID: 'root' });
  await f.feed('session.execution.started', { sessionID: 'root' });
  await f.feed('session.created', { sessionID: 'child', parentID: 'root' });
  await f.feed('session.execution.started', { sessionID: 'child' });
  await f.feed('session.execution.succeeded', { sessionID: 'child' });
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 0);
  await f.feed('session.execution.succeeded', { sessionID: 'root' });
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 0);
  assert.deepEqual(f.lookups, []);
});

test('inline: pending permissions and forms dominate until every request is answered', async (t) => {
  const f = await fixture(t);
  await f.feed('session.execution.started', { sessionID: 'root' });
  await f.feed('permission.asked', { sessionID: 'root', id: 'a', action: 'bash', resources: ['echo hello'] });
  // A permission prompt is announced by the global plugin's `notification`
  // hook, not here — this port only publishes the status it implies.
  assert.deepEqual(await f.last(), { state: 'Needs input' });
  await f.feed('permission.asked', { sessionID: 'root', id: 'a', action: 'bash', resources: ['echo hello'] });
  await f.feed('permission.asked', { sessionID: 'root', id: 'b', action: 'edit' });
  await f.feed('form.created', { form: { id: 'q1', sessionID: 'root', title: 'Which file?' } });
  assert.equal((await f.last()).state, 'Needs input');
  assert.equal((await f.last()).message, 'Which file?');
  // Agent questions are form-driven and handled nowhere else, so the inline
  // still announces those.
  assert.equal((await f.notices()).filter((e) => e.payload.title === 'OpenCode').length, 1);
  await f.feed('permission.replied', { sessionID: 'root', requestID: 'a', reply: 'once' });
  assert.equal((await f.last()).state, 'Needs input');
  await f.feed('permission.replied', { sessionID: 'root', requestID: 'b', reply: 'reject' });
  assert.equal((await f.last()).state, 'Needs input');
  await f.feed('form.replied', { sessionID: 'root', id: 'q1' });
  assert.equal((await f.last()).state, 'Running');
});

test('inline: failures report an error notice, aborts are quiet, restarts stay busy', async (t) => {
  const f = await fixture(t);
  await f.feed('session.execution.started', { sessionID: 'root' });
  await f.feed('session.execution.failed', { sessionID: 'root', error: { type: 'provider', message: 'Request failed' } });
  assert.equal((await f.last()).title, 'OpenCode error');
  assert.equal((await f.last()).message, 'Request failed');
  await f.feed('session.execution.started', { sessionID: 'root' });
  await f.feed('session.execution.started', { sessionID: 'root' });
  assert.equal((await f.last()).state, 'Running');
  await f.feed('session.execution.interrupted', { sessionID: 'root', reason: 'user' });
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 1);
});

test('inline: cleanup sends exactly one session-end and aborts the subscribe signal', async (t) => {
  const f = await fixture(t);
  await f.feed('session.execution.started', { sessionID: 'root' });
  assert.equal(f.stream.signal.aborted, false);
  const rejections = [];
  const onUnhandled = (reason) => rejections.push(reason);
  process.on('unhandledRejection', onUnhandled);
  try {
    await f.cleanup();
    await new Promise((resolve) => setTimeout(resolve, 50));
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
  assert.equal(f.stream.signal.aborted, true);
  assert.deepEqual(rejections, []);
  const commands = await f.commands();
  assert.equal(commands.filter((c) => c === 'session-end').length, 1);
  assert.equal(commands.at(-1), 'session-end');
});

test('inline: inert without env vars and when hooks are disabled', async (t) => {
  const a = await fixture(t, { source: INLINE_SRC, inert: 'missing-vars' });
  assert.equal(a.cleanup, undefined);
  assert.equal(await a.missing(), true);
  const b = await fixture(t, { source: INLINE_SRC, inert: 'disabled' });
  assert.equal(b.cleanup, undefined);
  assert.equal(await b.missing(), true);
});

test('inline: concurrent event callbacks preserve order', async (t) => {
  const f = await fixture(t);
  await f.feedBurst([
    ['session.execution.started', { sessionID: 'root' }],
    ['session.execution.succeeded', { sessionID: 'root' }],
    ['session.execution.started', { sessionID: 'root' }],
    ['session.execution.interrupted', { sessionID: 'root', reason: 'user' }],
    ['session.execution.started', { sessionID: 'root' }],
    ['session.execution.succeeded', { sessionID: 'root' }],
  ]);
  const states = (await f.events()).map((e) => e.payload.state);
  assert.deepEqual(states, ['Idle', 'Running', 'Idle', 'Running', 'Idle', 'Running', 'Idle']);
});

test('global: first session adopts, a second session is tracked as a subagent child', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1', projectID: 'p1' });
  assert.deepEqual(await f.commands(), ['session-start', 'prompt-submit']);
  assert.equal((await f.events())[0].payload.session_id, 'ses_1');
  assert.equal((await f.events())[0].payload.cwd, "/tmp/a 'project'");
  await f.feed('session.renamed', { sessionID: 'ses_1', title: 'Renamed' });
  assert.equal((await f.commands()).length, 2);
  await f.feed('session.created', { sessionID: 'ses_2', parentID: 'ses_1' });
  assert.deepEqual(await f.commands(), ['session-start', 'prompt-submit', 'subagent-update', 'prompt-submit']);
  const counts = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.deepEqual(counts.at(-1).payload, { workspace_id: '1', subagent_count: 1, background_count: 0 });
});

test('global: child terminal untracks without stop; primary succeeded and interrupted emit stop', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1' });
  await f.feed('session.created', { sessionID: 'ses_2', parentID: 'ses_1' });
  await f.feed('session.execution.succeeded', { sessionID: 'ses_2' });
  assert.deepEqual(await f.commands(),
    ['session-start', 'prompt-submit', 'subagent-update', 'prompt-submit', 'subagent-update', 'prompt-submit']);
  const counts = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.equal(counts.at(-1).payload.subagent_count, 0);
  await f.feed('session.execution.succeeded', { sessionID: 'ses_1' });
  await f.feed('session.execution.interrupted', { sessionID: 'ses_1', reason: 'user' });
  assert.deepEqual(await f.commands(),
    ['session-start', 'prompt-submit', 'subagent-update', 'prompt-submit', 'subagent-update',
     'prompt-submit', 'stop', 'stop']);
});

test('global: tool execute hooks fire for the primary session only', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1' });
  const before = f.exec('execute.before');
  const after = f.exec('execute.after');
  await before({ tool: 'bash', sessionID: 'ses_1' });
  await after({ tool: 'read', sessionID: 'ses_1' });
  assert.deepEqual(await f.commands(),
    ['session-start', 'prompt-submit', 'pre-tool-use', 'post-tool-use']);
  const payloads = await f.events();
  assert.equal(payloads[2].payload.tool_name, 'bash');
  assert.equal(payloads[3].payload.tool_name, 'read');
  await before({ tool: 'bash', sessionID: 'other' });
  assert.equal((await f.commands()).length, 4);
  await before({ tool: 'edit' });
  assert.deepEqual((await f.commands()).at(-1), 'pre-tool-use');
});

test('global: inert without env vars and when hooks are disabled', async (t) => {
  const a = await fixture(t, { source: GLOBAL_SRC, inert: 'missing-vars' });
  assert.equal(a.cleanup, undefined);
  assert.equal(await a.missing(), true);
  const b = await fixture(t, { source: GLOBAL_SRC, inert: 'disabled' });
  assert.equal(b.cleanup, undefined);
  assert.equal(await b.missing(), true);
});

test('global: resumed session adopts on execution.started, failure stops, deletion ends', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.execution.started', { sessionID: 'ses_r' });
  assert.deepEqual(await f.commands(), ['session-start', 'prompt-submit']);
  await f.feed('session.execution.failed', { sessionID: 'ses_r', error: { message: 'boom' } });
  assert.deepEqual(await f.commands(), ['session-start', 'prompt-submit', 'stop']);
  const stop = (await f.events()).at(-1);
  assert.equal(stop.args.at(-1), 'stop');
  assert.equal(stop.payload.cwd, "/tmp/a 'project'");
  await f.feed('session.deleted', { sessionID: 'ses_r' });
  assert.deepEqual(await f.commands(),
    ['session-start', 'prompt-submit', 'stop', 'subagent-update', 'session-end']);
  const end = (await f.events()).at(-1);
  assert.equal(end.payload.session_id, 'ses_r');
  assert.equal(end.payload.subagent_count, 0);
  assert.equal(f.stream.signal.aborted, false);
  const rejections = [];
  const onUnhandled = (reason) => rejections.push(reason);
  process.on('unhandledRejection', onUnhandled);
  try {
    await f.cleanup();
    await new Promise((resolve) => setTimeout(resolve, 50));
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
  assert.equal(f.stream.signal.aborted, true);
  assert.deepEqual(rejections, []);
});

test('global: independent sessions are not subagents and share the pane status', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1' });
  await f.feed('session.created', { sessionID: 'ses_2' });
  assert.deepEqual(await f.commands(), ['session-start', 'prompt-submit', 'session-update']);
  assert.equal((await f.events()).at(-1).payload.session_count, 2);
  assert.equal((await f.events()).some((e) => e.args.at(-1) === 'subagent-update'), false);
  await f.feed('session.execution.started', { sessionID: 'ses_2' });
  await f.feed('session.execution.started', { sessionID: 'ses_1' });
  assert.equal((await f.commands()).filter((c) => c === 'prompt-submit').length, 2);
  await f.feed('permission.asked', { sessionID: 'ses_2', id: 'p1', action: 'bash', resources: ['ls'] });
  await f.feed('permission.replied', { sessionID: 'ses_2', requestID: 'p1' });
  await f.feed('session.execution.succeeded', { sessionID: 'ses_2' });
  assert.equal((await f.commands()).at(-1), 'notification'); // ses_1 still executing: no stop
  await f.feed('session.execution.succeeded', { sessionID: 'ses_1' });
  assert.deepEqual(await f.commands(),
    ['session-start', 'prompt-submit', 'session-update', 'prompt-submit', 'notification', 'stop']);
});

test('global: session_count reports pane sessions, not subagent children', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 1);
  await f.feed('session.created', { sessionID: 'ses_2', parentID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 1); // a child is a subagent, not a session
  await f.feed('session.created', { sessionID: 'ses_3' });
  // No execution and no status event: the peer count arrives on its own.
  const added = (await f.events()).at(-1);
  assert.equal(added.args.at(-1), 'session-update');
  assert.equal(added.payload.session_count, 2);
  await f.feed('session.execution.started', { sessionID: 'ses_3' });
  assert.equal((await f.events()).at(-1).payload.session_count, 2);
  await f.feed('session.execution.succeeded', { sessionID: 'ses_3' });
  const stop = (await f.events()).at(-1);
  assert.equal(stop.args.at(-1), 'stop');
  assert.equal(stop.payload.session_count, 2);
  await f.feed('session.deleted', { sessionID: 'ses_3' });
  const removed = (await f.events()).at(-1);
  assert.equal(removed.args.at(-1), 'session-update');
  assert.equal(removed.payload.session_count, 1);
  await f.feed('session.execution.started', { sessionID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 1);
  const hooks = (await f.events()).filter((e) => e.args.at(-1) !== 'subagent-update');
  assert.ok(hooks.length > 0);
  assert.ok(hooks.every((e) => typeof e.payload.session_count === 'number'));
});

test('global: startup seeding counts sessions that pre-date the pane launch', async (t) => {
  // A session that already existed when the pane launched produces no
  // session.created event, so it must be seeded from session.list.
  const f = await fixture(t, { source: GLOBAL_SRC, existingSessions: [
    { id: 'ses_old' },                    // independent session sharing the window
    { id: 'ses_sub', parentID: 'ses_old' }, // subagent of a pre-existing session
  ] });
  // The seed pushed counts before any event arrived.
  const seeded = (await f.events()).at(-1);
  assert.equal(seeded.args.at(-1), 'session-update');
  assert.equal(seeded.payload.session_count, 1); // one pre-existing peer
  assert.equal(seeded.payload.subagent_count, 1);
  // The pane's own session adopts afterwards; seeded entries must survive.
  await f.feed('session.created', { sessionID: 'ses_new' });
  const adopted = (await f.events()).at(-1);
  assert.equal(adopted.payload.session_count, 2); // primary + seeded peer
  assert.equal(adopted.payload.subagent_count, 1);
});

test('global: the adopting primary is dropped from the seed, not double-counted', async (t) => {
  // session.list runs before the pane's own session adopts, so the primary
  // can appear in the seed; adoption must remove it from the peer set.
  const f = await fixture(t, { source: GLOBAL_SRC, existingSessions: [
    { id: 'ses_1' }, { id: 'ses_2' },
  ] });
  await f.feed('session.created', { sessionID: 'ses_1' });
  const adopted = (await f.events()).at(-1);
  assert.equal(adopted.payload.session_count, 2); // ses_1 primary + ses_2 peer
  await f.feed('session.execution.started', { sessionID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 2);
  // The adoption path must not wipe the seeded peer on execution start either.
  await f.feed('session.deleted', { sessionID: 'ses_1' });
});

test('global: seeding is best-effort when session.list is unavailable', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC, listFailure: true });
  // No session-update from a failed seed; the event path still works.
  await f.feed('session.created', { sessionID: 'ses_1' });
  const adopted = (await f.events()).at(-1);
  assert.equal(adopted.payload.session_count, 1);
  await f.feed('session.created', { sessionID: 'ses_2' });
  assert.equal((await f.events()).at(-1).payload.session_count, 2);
});

test('global: subagent count only counts sessions with a parentID', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1' });
  await f.feed('session.created', { sessionID: 'ses_2', parentID: 'ses_1' });
  await f.feed('session.created', { sessionID: 'ses_3' });
  await f.feed('session.created', { sessionID: 'ses_4', parentID: 'ses_2' });
  const counts = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.deepEqual(counts.at(-1).payload, { workspace_id: '1', subagent_count: 2, background_count: 0 });
  await f.feed('session.deleted', { sessionID: 'ses_3' });
  const after = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.equal(after.length, counts.length);
  assert.equal(after.at(-1).payload.subagent_count, 2);
});
