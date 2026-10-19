import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { SeancePlugin } from '../resources/opencode/seance.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const GLOBAL_SRC = join(HERE, '..', 'plugins', 'seance-opencode', 'index.ts');
const KILO_SRC = join(HERE, '..', 'plugins', 'seance-kilo', 'index.ts');
const MIMO_SRC = join(HERE, '..', 'plugins', 'seance-mimocode', 'index.ts');

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), "seance-plugin-' "));
  t.after(() => rm(root, { recursive: true, force: true }));
  const capture = join(root, 'events');
  // The global plugins interpolate the binary path raw into a shell command, so
  // it cannot share the quoted directory the payload-escaping tests rely on.
  const binRoot = options.source ? await mkdtemp(join(tmpdir(), 'seance-plugin-')) : root;
  t.after(() => rm(binRoot, { recursive: true, force: true }));
  const binary = join(binRoot, 'seance');
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
  Object.assign(process.env, { SEANCE_OPENCODE_BIN: binary, SEANCE_SOCKET_PATH: join(root, 'sock'),
    SEANCE_SURFACE_ID: options.surface ?? '3', SEANCE_WORKSPACE_ID: '1' });
  delete process.env.SEANCE_OPENCODE_HOOKS_DISABLED;
  delete process.env.SEANCE_KILO_HOOKS_DISABLED;
  delete process.env.SEANCE_MIMOCODE_HOOKS_DISABLED;
  const $ = (strings, ...values) => new Promise((resolve, reject) => {
    const command = strings.reduce((acc, part, i) =>
      acc + part + (i < values.length ? String(values[i]) : ''), '');
    execFile('/bin/sh', ['-c', command], (error) => (error ? reject(error) : resolve()));
  });
  const mod = options.source
    ? await import(pathToFileURL(options.source).href)
    : { SeancePlugin };
  const factory = mod.default?.server ?? mod.SeancePlugin;
  if (typeof factory !== 'function') throw new Error('plugin factory missing');
  const lookups = [];
  const hooks = await factory({ directory: "/tmp/a 'project'", $, client: { session: { get: async ({ path }) => {
    lookups.push(path.id);
    if (options.lookupFailure) throw Error('unavailable');
    return { data: { id: path.id, parentID: options.parents?.[path.id] } };
  } } } });
  process.env = previous;
  const events = async () => (await readFile(capture, 'utf8')).trim().split('\n').map(JSON.parse);
  const emit = (type, properties) => hooks.event({ event: { type, properties } });
  const status = (id, type) => emit('session.status', { sessionID: id, status: { type } });
  const notices = async () => (await events()).filter((e) => e.payload.title);
  const last = async () => (await events()).at(-1).payload;
  return { hooks, events, emit, status, notices, last, lookups, root, binary };
}

test('starts idle, tracks resumed sessions, and emits one completion with literal text', async (t) => {
  const f = await fixture(t);
  assert.deepEqual(await f.last(), { state: 'Idle' });
  await f.status('resumed', 'busy');
  await f.hooks['experimental.text.complete']({ sessionID: 'resumed' }, { text: "It’s done: 'quoted' $(touch /tmp/never) `literal`\nnext" });
  await f.status('resumed', 'idle');
  await f.emit('session.idle', { sessionID: 'resumed' });
  assert.deepEqual(f.lookups, ['resumed']);
  assert.equal((await f.notices()).length, 1);
  assert.deepEqual(await f.last(), { state: 'Idle', title: "Completed in a 'project'", message: "It’s done: 'quoted' $(touch /tmp/never) `literal` next" });
});

test('subagent idle cannot hide a working parent or announce task completion', async (t) => {
  const f = await fixture(t);
  await f.emit('session.created', { info: { id: 'root' } });
  await f.status('root', 'busy');
  await f.emit('session.created', { info: { id: 'child', parentID: 'root' } });
  await f.status('child', 'busy');
  await f.status('child', 'idle');
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 0);
  await f.status('root', 'idle');
  assert.equal((await f.notices()).length, 1);
  assert.deepEqual(f.lookups, []);
});

test('completion waits for a still running background child', async (t) => {
  const f = await fixture(t, { parents: { child: 'root' } });
  await f.status('root', 'busy');
  await f.status('child', 'busy');
  await f.status('root', 'idle');
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 0);
  await f.status('child', 'idle');
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 1);
});

test('independent sessions each notify without hiding another session activity', async (t) => {
  const f = await fixture(t);
  for (const id of ['first', 'second']) {
    await f.emit('session.created', { info: { id } });
    await f.status(id, 'busy');
  }
  await f.status('first', 'idle');
  assert.equal((await f.last()).state, 'Running');
  assert.equal((await f.notices()).length, 1);
  await f.status('second', 'idle');
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 2);
});

test('pending permissions dominate concurrent activity until every request is answered', async (t) => {
  const f = await fixture(t);
  await f.status('root', 'busy');
  await f.emit('permission.asked', { sessionID: 'root', id: 'a', permission: 'bash', patterns: ['echo hello'] });
  await f.emit('permission.asked', { sessionID: 'root', id: 'b', permission: 'edit' });
  await f.emit('permission.asked', { sessionID: 'root', id: 'b', permission: 'edit' });
  await f.status('root', 'busy');
  await f.status('child', 'busy');
  await f.status('child', 'idle');
  assert.equal((await f.last()).state, 'Needs input');
  assert.equal((await f.notices()).filter((e) => e.payload.title === 'OpenCode').length, 2);
  await f.emit('permission.replied', { sessionID: 'root', requestID: 'a', reply: 'once' });
  assert.equal((await f.last()).state, 'Needs input');
  await f.emit('permission.replied', { sessionID: 'root', requestID: 'b', reply: 'reject' });
  assert.equal((await f.last()).state, 'Running');
});

test('questions use the actual question text and clear on reply or rejection', async (t) => {
  const f = await fixture(t);
  await f.status('root', 'busy');
  for (const prefix of ['question', 'question.v2']) {
    await f.emit(`${prefix}.asked`, { sessionID: 'root', id: 'q', questions: [{ question: 'Which file?' }] });
    assert.equal((await f.last()).message, 'Which file?');
    assert.equal((await f.last()).state, 'Needs input');
    await f.emit(`${prefix}.rejected`, { sessionID: 'root', requestID: 'q' });
    assert.equal((await f.last()).state, 'Running');
  }
});

test('retry stays busy, errors are not reported as successful completion, aborts are quiet', async (t) => {
  const f = await fixture(t);
  await f.status('root', 'retry');
  assert.equal((await f.last()).state, 'Running');
  await f.emit('session.error', { sessionID: 'root', error: { name: 'APIError', data: { message: 'Request failed' } } });
  await f.status('root', 'idle');
  assert.equal((await f.last()).title, 'OpenCode error');
  assert.equal((await f.last()).message, 'Request failed');
  await f.status('root', 'busy');
  await f.emit('session.error', { sessionID: 'root', error: { name: 'MessageAbortedError' } });
  await f.status('root', 'idle');
  assert.equal((await f.notices()).length, 1);
});

test('concurrent event callbacks preserve order', async (t) => {
  const f = await fixture(t);
  await Promise.all([f.status('root', 'busy'),
    f.emit('permission.asked', { sessionID: 'root', id: 'a', permission: 'bash' }),
    f.status('root', 'busy')]);
  assert.equal((await f.last()).state, 'Needs input');
  assert.deepEqual((await f.events()).map((e) => e.payload.state), ['Idle', 'Running', 'Needs input']);
});

test('unknown ancestry cannot cause false subagent completion notices', async (t) => {
  const f = await fixture(t, { lookupFailure: true });
  await f.status('unknown', 'busy');
  await f.status('unknown', 'idle');
  assert.equal((await f.last()).state, 'Idle');
  assert.equal((await f.notices()).length, 0);
});

test('plugin captures pane context, filters streaming traffic, and disposes', async (t) => {
  const a = await fixture(t, { surface: '3' });
  const b = await fixture(t, { surface: '4' });
  for (let i = 0; i < 100; i++) await a.emit('message.part.delta', { sessionID: 'root' });
  assert.equal((await a.events()).length, 1);
  await a.status('root', 'busy');
  await b.status('root', 'busy');
  await a.hooks.dispose();
  await a.status('root', 'busy');
  assert.equal((await a.events()).at(-1).args.at(-1), 'session-end');
  assert.ok((await a.events()).every((e) => e.surface === '3'));
  assert.ok((await b.events()).every((e) => e.surface === '4'));
  assert.equal((await b.last()).state, 'Running');
});

test('broken and stalled bridge commands never reject OpenCode hooks', async (t) => {
  const f = await fixture(t, { fail: true });
  await f.status('root', 'busy');
  await f.status('root', 'idle');
  await f.hooks.dispose();
  const start = Date.now();
  const stalled = await fixture(t, { hang: true });
  await stalled.status('root', 'busy');
  await stalled.hooks.dispose();
  assert.ok(Date.now() - start < 4000);
});

test('plugin is inert outside a wrapper launch and when disabled', async () => {
  const previous = { ...process.env };
  try {
    delete process.env.SEANCE_OPENCODE_BIN;
    assert.deepEqual(await SeancePlugin({}), {});
    process.env.SEANCE_OPENCODE_BIN = '/missing';
    process.env.SEANCE_OPENCODE_HOOKS_DISABLED = '1';
    assert.deepEqual(await SeancePlugin({}), {});
  } finally { process.env = previous; }
});

// MiMo Code moved to the modern module + session.post lifecycle hooks, so it
// no longer answers session.idle; its coverage lives in the block below.
for (const [agent, source, hook] of [
  ['opencode', GLOBAL_SRC, 'opencode-hook'],
  ['kilo', KILO_SRC, 'kilo-hook'],
]) {
  test(`global ${agent}: session-start and stop carry the launch directory`, async (t) => {
    const f = await fixture(t, { source });
    await f.emit('session.created', { sessionID: 'root' });
    const events = await f.events();
    assert.deepEqual(events.map((e) => e.args.at(-1)), ['session-start', 'prompt-submit']);
    assert.equal(events[0].args.at(-2), hook);
    assert.equal(events[0].payload.cwd, process.cwd());
    assert.equal('cwd' in events[1].payload, false);
    await f.emit('session.idle', { sessionID: 'root' });
    const stop = (await f.events()).at(-1);
    assert.equal(stop.args.at(-1), 'stop');
    assert.equal(stop.payload.cwd, process.cwd());
  });
}

test('mimocode is inert without a socket and when hooks are disabled', async () => {
  const previous = { ...process.env };
  const { default: mod } = await import(pathToFileURL(MIMO_SRC).href);
  try {
    delete process.env.SEANCE_SOCKET_PATH;
    delete process.env.SEANCE_MIMOCODE_HOOKS_DISABLED;
    assert.deepEqual(await mod.server({ $: async () => {} }), {});
    process.env.SEANCE_SOCKET_PATH = '/tmp/seance-sock';
    process.env.SEANCE_MIMOCODE_HOOKS_DISABLED = '1';
    assert.deepEqual(await mod.server({ $: async () => {} }), {});
  } finally { process.env = previous; }
});

test('mimocode session-created adopts the session with the launch directory', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  const events = await f.events();
  assert.deepEqual(events.map((e) => e.args.at(-1)), ['session-start', 'prompt-submit']);
  assert.ok(events.every((e) => e.args.at(-2) === 'mimocode-hook'));
  assert.equal(events[0].payload.cwd, process.cwd());
  assert.equal('cwd' in events[1].payload, false);
});

test('mimocode session.post completed stops with cwd and escaped final text', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  await f.hooks['session.post']({ sessionID: 'root', outcome: 'completed', finalText: "Done: 'q'" }, {});
  const stop = await f.last();
  assert.equal((await f.events()).at(-1).args.at(-1), 'stop');
  assert.equal(stop.cwd, process.cwd());
  assert.equal(stop.message, "Done: 'q'");

  await f.hooks['session.post']({ sessionID: 'root', outcome: 'completed' }, {});
  assert.equal('message' in await f.last(), false);
});

test('mimocode session.post error ends the session and resets counts', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  await f.hooks['session.post']({ sessionID: 'root', outcome: 'error', error: new Error('boom') }, {});
  const events = await f.events();
  assert.equal(events.at(-1).args.at(-1), 'session-end');
  assert.equal(events.at(-2).args.at(-1), 'subagent-update');
  assert.equal(events.at(-2).payload.subagent_count, 0);
});

test('mimocode session.post ignores a different session', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  const before = (await f.events()).length;
  await f.hooks['session.post']({ sessionID: 'other', outcome: 'completed', finalText: 'x' }, {});
  await f.hooks['session.post']({ sessionID: 'other', outcome: 'error' }, {});
  assert.equal((await f.events()).length, before);
});

test('mimocode actor.registered counts subagents and skips infrastructure agents', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  await f.emit('actor.registered', { sessionID: 'root', actorID: 'a1', mode: 'subagent', agent: 'general' });
  const afterGeneral = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.equal(afterGeneral.length, 1);
  assert.equal(afterGeneral[0].payload.subagent_count, 1);

  for (const agent of ['title', 'checkpoint-writer', 'dream', 'compaction']) {
    await f.emit('actor.registered', { sessionID: 'root', actorID: `i-${agent}`, mode: 'subagent', agent });
  }
  const updates = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.equal(updates.length, 1);
  assert.equal(updates.at(-1).payload.subagent_count, 1);
});

test('mimocode actor.registered background flag feeds background_count', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  await f.emit('actor.registered', { sessionID: 'root', actorID: 'b1', mode: 'subagent', agent: 'general', background: true });
  const update = (await f.events()).find((e) => e.args.at(-1) === 'subagent-update');
  assert.equal(update.payload.subagent_count, 1);
  assert.equal(update.payload.background_count, 1);

  await f.hooks['actor.postStop'].run({ actorID: 'b1' });
  const after = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update').at(-1);
  assert.equal(after.payload.subagent_count, 0);
  assert.equal(after.payload.background_count, 0);
});

test('mimocode actor.postStop decrements and reports a subagent going idle', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  await f.emit('actor.registered', { sessionID: 'root', actorID: 'a1', mode: 'subagent', agent: 'general' });
  await f.hooks['actor.postStop'].run({ actorID: 'a1' });
  const events = await f.events();
  const update = events.filter((e) => e.args.at(-1) === 'subagent-update').at(-1);
  assert.equal(update.payload.subagent_count, 0);
  assert.equal(events.at(-1).args.at(-1), 'prompt-submit');
  // Unknown actors are not counted down twice.
  await f.hooks['actor.postStop'].run({ actorID: 'nope' });
  const second = (await f.events()).filter((e) => e.args.at(-1) === 'subagent-update');
  assert.equal(second.length, 2);
  assert.equal(second.at(-1).payload.subagent_count, 0);
});

test('mimocode permission.asked notifies with the permission detail', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  await f.emit('permission.asked', { sessionID: 'root', permission: 'bash', patterns: ['echo hello'] });
  await f.emit('permission.asked', { sessionID: 'root', permission: 'edit' });
  const notices = (await f.events()).filter((e) => e.args.at(-1) === 'notification');
  assert.equal(notices.length, 2);
  assert.equal(notices[0].payload.message, 'bash: echo hello');
  assert.equal(notices[1].payload.message, 'edit');
});

test('mimocode session.pre reports busy only for the adopted session', async (t) => {
  const f = await fixture(t, { source: MIMO_SRC });
  await f.emit('session.created', { sessionID: 'root' });
  const before = (await f.events()).length;
  await f.hooks['session.pre']({ sessionID: 'other' }, {});
  assert.equal((await f.events()).length, before);
  await f.hooks['session.pre']({ sessionID: 'root' }, {});
  const events = await f.events();
  assert.equal(events.at(-1).args.at(-1), 'prompt-submit');
  assert.equal(events.length, before + 1);
});
