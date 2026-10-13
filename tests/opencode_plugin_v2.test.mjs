import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, mkdir, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const INLINE_SRC = join(HERE, '..', 'resources', 'opencode', 'seance-v2.mjs');
const GLOBAL_SRC = join(HERE, '..', 'plugins', 'seance-opencode', 'index-v2.ts');

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
  const binary = join(root, 'seance');
  await writeFile(binary, `#!/usr/bin/env node
const { appendFileSync } = require('node:fs');
(async () => {
let text = '';
for await (const chunk of process.stdin) text += chunk;
appendFileSync(${JSON.stringify(capture)}, JSON.stringify({args: process.argv.slice(2), payload: JSON.parse(text), surface: process.env.SEANCE_SURFACE_ID}) + '\\n');
${options.hang ? 'setInterval(() => {}, 1000);' : ''}
${options.fail ? 'process.exitCode = 1;' : ''}
})();
`, { mode: 0o755 });
  const previous = { ...process.env };
  delete process.env.SEANCE_OPENCODE_HOOKS_DISABLED;
  if (options.inert === 'missing-vars') {
    delete process.env.SEANCE_OPENCODE_BIN;
    delete process.env.SEANCE_SOCKET_PATH;
    delete process.env.SEANCE_SURFACE_ID;
    delete process.env.SEANCE_WORKSPACE_ID;
  } else if (options.inert === 'disabled') {
    Object.assign(process.env, { SEANCE_OPENCODE_BIN: binary, SEANCE_SOCKET_PATH: join(root, 'sock'),
      SEANCE_SURFACE_ID: '3', SEANCE_WORKSPACE_ID: '1', SEANCE_OPENCODE_HOOKS_DISABLED: '1' });
  } else {
    Object.assign(process.env, { SEANCE_OPENCODE_BIN: binary, SEANCE_SOCKET_PATH: join(root, 'sock'),
      SEANCE_SURFACE_ID: options.surface ?? '3', SEANCE_WORKSPACE_ID: '1' });
  }

  const sandbox = join(root, 'sandbox');
  await mkdir(sandbox, { recursive: true });
  await installStub(sandbox);
  await copyFile(options.source ?? INLINE_SRC, join(sandbox, 'plugin.mjs'));
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
    location: { directory: "/tmp/a 'project'" },
    options: {},
  };
  const cleanup = await mod.default.setup(ctx);
  process.env = previous;
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
  return { root, capture, binary, cleanup, stream, toolHooks, exec, lookups,
    events, notices, last, commands, feed, feedBurst, missing };
}

test('inline: starts idle, runs, and emits one completion with the title but no message text', async (t) => {
  const f = await fixture(t, { source: INLINE_SRC });
  assert.deepEqual(await f.last(), { state: 'Idle' });
  await f.feed('session.execution.started', { sessionID: 'resumed' });
  assert.equal((await f.last()).state, 'Running');
  await f.feed('session.execution.succeeded', { sessionID: 'resumed' });
  assert.deepEqual(f.lookups, ['resumed']);
  assert.equal((await f.notices()).length, 1);
  const payload = await f.last();
  assert.equal(payload.title, "Completed in a 'project'");
  assert.equal(payload.message ?? '', '');
  assert.equal(payload.state, 'Idle');
  assert.equal('cwd' in payload, false); // the inline port titles its own notice
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
  assert.equal((await f.notices()).length, 1);
  assert.deepEqual(f.lookups, []);
});

test('inline: pending permissions and forms dominate until every request is answered', async (t) => {
  const f = await fixture(t);
  await f.feed('session.execution.started', { sessionID: 'root' });
  await f.feed('permission.asked', { sessionID: 'root', id: 'a', action: 'bash', resources: ['echo hello'] });
  assert.equal((await f.last()).message, 'Permission required: bash (echo hello)');
  await f.feed('permission.asked', { sessionID: 'root', id: 'a', action: 'bash', resources: ['echo hello'] });
  await f.feed('permission.asked', { sessionID: 'root', id: 'b', action: 'edit' });
  await f.feed('form.created', { form: { id: 'q1', sessionID: 'root', title: 'Which file?' } });
  assert.equal((await f.last()).state, 'Needs input');
  assert.equal((await f.last()).message, 'Which file?');
  assert.equal((await f.notices()).filter((e) => e.payload.title === 'OpenCode').length, 3);
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
  assert.deepEqual(await f.commands(), ['session-start', 'prompt-submit']);
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
    ['session-start', 'prompt-submit', 'prompt-submit', 'notification', 'stop']);
});

test('global: session_count reports pane sessions, not subagent children', async (t) => {
  const f = await fixture(t, { source: GLOBAL_SRC });
  await f.feed('session.created', { sessionID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 1);
  await f.feed('session.created', { sessionID: 'ses_2', parentID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 1); // a child is a subagent, not a session
  await f.feed('session.created', { sessionID: 'ses_3' });
  await f.feed('session.execution.started', { sessionID: 'ses_3' });
  assert.equal((await f.events()).at(-1).payload.session_count, 2);
  await f.feed('session.execution.succeeded', { sessionID: 'ses_3' });
  const stop = (await f.events()).at(-1);
  assert.equal(stop.args.at(-1), 'stop');
  assert.equal(stop.payload.session_count, 2);
  await f.feed('session.deleted', { sessionID: 'ses_3' });
  await f.feed('session.execution.started', { sessionID: 'ses_1' });
  assert.equal((await f.events()).at(-1).payload.session_count, 1);
  const hooks = (await f.events()).filter((e) => e.args.at(-1) !== 'subagent-update');
  assert.ok(hooks.length > 0);
  assert.ok(hooks.every((e) => typeof e.payload.session_count === 'number'));
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
