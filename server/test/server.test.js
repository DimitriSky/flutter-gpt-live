import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { EventEmitter, once } from 'node:events';
import WebSocket from 'ws';
import { createApplication } from '../src/server.js';
import { configuration, readKnowledge } from '../src/config.js';
import { TaskStore } from '../src/task_store.js';
import { sessionConfig } from '../src/live.js';
import { TaskManager } from '../src/task_worker.js';
import { EventEmitter as Emitter } from 'node:events';

function fixture() {
  const dir = mkdtempSync(resolve(tmpdir(), 'gpt-live-test-'));
  writeFileSync(resolve(dir, 'data.txt'), 'Название проекта: Project Alpha');
  writeFileSync(resolve(dir, 'rules.md'), '# Разговор\nГовори по-русски.\n# Знания и задачи\nНе выдумывай.');
  const config = { ...configuration({ DEV_CLIENT_TOKEN: 'test-token-with-more-than-24-chars', OPENAI_API_KEY: 'unit-test-key', PORT: '0' }), configDir: dir, storageDir: resolve(dir, 'storage') };
  return { dir, config };
}
function fakeSocket() {
  const ws = new EventEmitter(); ws.readyState = WebSocket.OPEN; ws.sent = [];
  ws.send = raw => {
    const e = JSON.parse(raw); ws.sent.push(e);
    if (e.type === 'session.close') queueMicrotask(() => ws.emit('message', Buffer.from(JSON.stringify({ type: 'session.closed', event_id: 'final', usage: { seconds: 3 }, reason: 'close_requested' }))));
  };
  ws.close = () => { ws.readyState = WebSocket.CLOSED; ws.emit('close'); };
  ws.terminate = ws.close;
  queueMicrotask(() => ws.emit('open'));
  return ws;
}
async function setup(t, options = {}) {
  const { dir, config } = fixture();
  let complete;
  const done = new Promise(resolve => { complete = resolve; });
  const sockets = []; const offers = []; const sessions = [];
  const api = { post: async (path, body) => {
    if (path === '/live/sessions') { offers.push(body.transport.sdp); sessions.push(body.session); return { session: { id: sessions.length === 1 ? 'live_test' : `live_test_${sessions.length}` }, transport: { type: 'webrtc', sdp: 'answer' } }; }
    return {};
  }, runTask: async (task, signal) => Promise.race([done, new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }))]) };
  const codex = options.codex === undefined ? null : options.codex;
  const app = createApplication({ ...config, ...options }, { api, codex, socketFactory: () => { const ws = fakeSocket(); sockets.push(ws); return ws; } });
  const address = await app.start();
  t.after(() => app.stop());
  const headers = { Authorization: `Bearer ${config.token}`, 'X-Client-ID': 'client_a', 'Content-Type': 'application/json' };
  const request = async (path, body, extra = {}) => {
    const response = await fetch(`http://127.0.0.1:${address.port}${path}`, { headers: { ...headers, ...extra }, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() };
  };
  const taskBody = { conversation_id: 'conversation_a', title: 'Отчёт', description: 'Составь отчёт по моей базе', idempotency_key: 'request_a' };
  return { app, config, dir, request, taskBody, sockets, offers, sessions, complete: () => complete({ result: 'Отчёт: Project Alpha', response_id: 'resp_test', usage: { output_tokens: 10 } }) };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('HTTP and WebSocket require a dev token; client data is isolated', async t => {
  const f = await setup(t);
  assert.equal((await f.request('/tasks', null, { Authorization: 'Bearer invalid' })).status, 401);
  const task = await f.request('/tasks', f.taskBody);
  assert.equal((await f.request(`/tasks/${task.body.id}`, null, { 'X-Client-ID': 'client_b' })).status, 404);
  assert.deepEqual((await f.request('/tasks', null, { 'X-Client-ID': 'client_b' })).body.tasks, []);
  const ws = new WebSocket(`ws://127.0.0.1:${f.app.server.address().port}/events`);
  ws.on('error', () => {});
  const [response] = await once(ws, 'unexpected-response');
  // ws passes request first, response second; the connection must be rejected.
  assert.ok(response); ws.terminate();
});

test('idempotency survives completed jobs and rejects key reuse with different text', async t => {
  const f = await setup(t);
  const first = await f.request('/tasks', f.taskBody);
  const retry = await f.request('/tasks', f.taskBody);
  assert.equal(first.status, 201); assert.equal(retry.status, 200); assert.equal(first.body.id, retry.body.id);
  assert.equal((await f.request('/tasks', { ...f.taskBody, description: 'Другое задание' })).status, 409);
  f.complete(); await tick(); await tick();
  assert.equal((await f.request('/tasks', f.taskBody)).body.id, first.body.id);
  assert.equal(f.app.store.state.tasks.length, 1);
});

test('knowledge and conversation are snapshotted at acceptance', async t => {
  const f = await setup(t);
  const first = await f.request('/tasks', f.taskBody);
  writeFileSync(resolve(f.dir, 'data.txt'), 'Другой проект');
  const second = await f.request('/tasks', { ...f.taskBody, idempotency_key: 'request_b' });
  assert.match(f.app.store.task('client_a', first.body.id).snapshot.data, /Project Alpha/);
  assert.equal(f.app.store.task('client_a', second.body.id).snapshot.data, 'Другой проект');
  assert.equal(first.body.snapshot, undefined);
});

test('task outlives confirmed Live close and result is fetched over HTTP', async t => {
  const f = await setup(t);
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  const task = await f.request('/tasks', f.taskBody); await tick();
  const closed = await f.request('/live/live_test/close', {});
  assert.equal(closed.body.finalization_confirmed, true);
  assert.equal((await f.request(`/tasks/${task.body.id}`)).body.status, 'Running');
  f.complete(); await tick(); await tick();
  const ready = await f.request(`/tasks/${task.body.id}`);
  assert.equal(ready.body.status, 'Completed'); assert.match(ready.body.result, /Project Alpha/);
  assert.equal(ready.body.response_id, 'resp_test');
});

test('separate event socket receives task completion after voice closes', async t => {
  const f = await setup(t);
  const ws = new WebSocket(`ws://127.0.0.1:${f.app.server.address().port}/events`, { headers: { Authorization: `Bearer ${f.config.token}`, 'X-Client-ID': 'client_a' } });
  t.after(() => ws.terminate()); await once(ws, 'open');
  const received = []; ws.on('message', d => received.push(JSON.parse(d)));
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  await f.request('/tasks', f.taskBody); await f.request('/live/live_test/close', {}); f.complete();
  for (let i = 0; i < 30 && !received.some(e => e.type === 'task.completed'); i++) await new Promise(r => setTimeout(r, 5));
  assert.ok(received.some(e => e.type === 'task.completed'));
  assert.equal(received.find(e => e.type === 'task.completed').task.result, undefined);
});

test('sideband handles real-shaped function items exactly once and continues Responses', async t => {
  const f = await setup(t);
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  const item = { type: 'response.event', event_id: 'tool_event', delegation_id: 'delegation_1', event: { type: 'response.output_item.done', item: {
    type: 'function_call', call_id: 'call_1', name: 'enqueue_text_task', arguments: JSON.stringify({ title: 'Отчёт', description: 'Составь отчёт по базе в фоне' }),
  } } };
  f.sockets[0].emit('message', Buffer.from(JSON.stringify(item)));
  f.sockets[0].emit('message', Buffer.from(JSON.stringify(item)));
  assert.equal(f.app.store.state.tasks.length, 1);
  const sent = f.sockets[0].sent;
  assert.deepEqual(sent.map(e => e.type), ['response.item.create', 'response.create']);
  assert.equal(JSON.parse(sent[0].item.output).durable, true);
  assert.equal(sent.some(e => e.type === 'session.start'), false);
});

test('pending-task limit prevents unbounded costs', async t => {
  const f = await setup(t, { maxPending: 1 });
  assert.equal((await f.request('/tasks', f.taskBody)).status, 201);
  assert.equal((await f.request('/tasks', { ...f.taskBody, idempotency_key: 'request_b' })).status, 429);
});

test('new session includes exact completed result; style reloads from rules', () => {
  const { config, dir } = fixture();
  writeFileSync(resolve(dir, 'rules.md'), '# Разговор\nAnswer only in English.\n# Анализ\nUse facts.');
  const s = sessionConfig(config, readKnowledge(dir), { transcripts: [] }, { description: 'Отчёт', result: 'Exact saved report 123' });
  assert.match(s.instructions, /Answer only in English/);
  assert.match(s.input.find(i => i.role === 'user').content[0].text, /Exact saved report 123/);
  assert.equal(s.audio?.format, undefined);
  assert.equal(s.delegation.type, 'responses');
  assert.match(s.delegation.responses.instructions, /Project Alpha/);
});

test('atomic store survives restart; second process cannot open live storage', () => {
  const { config } = fixture();
  const store = new TaskStore(config.storageDir);
  store.conversation('owner', 'conversation');
  assert.throws(() => new TaskStore(config.storageDir), /already open/);
  store.close();
  const reopened = new TaskStore(config.storageDir);
  assert.equal(reopened.conversation('owner', 'conversation').owner, 'owner'); reopened.close();
});

test('restart retains queued jobs and marks ambiguous Running jobs Failed', () => {
  const { config } = fixture();
  const store = new TaskStore(config.storageDir);
  store.commit(s => {
    s.tasks.push({ id: 'running', status: 'Running' }, { id: 'queued', status: 'Queued' });
  });
  store.close();
  const reopened = new TaskStore(config.storageDir);
  const worker = new TaskManager({ store: reopened, api: {}, config, publish: () => {} });
  worker.stopping = true; worker.recover();
  assert.equal(reopened.state.tasks[0].status, 'Failed');
  assert.match(reopened.state.tasks[0].error, /перезапущен/);
  assert.equal(reopened.state.tasks[1].status, 'Queued');
  reopened.close();
});

test('expired client lease closes Live with confirmed usage', async t => {
  const f = await setup(t);
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  f.app.live.connections.get('live_test').lease = Date.now() - 1;
  f.app.live.sweep(); await tick(); await tick();
  assert.equal(f.app.store.session('client_a', 'live_test').finalization_confirmed, true);
});

test('worker timeout becomes a durable Failed task', async t => {
  const f = await setup(t, { taskTimeout: 1000 });
  const task = await f.request('/tasks', f.taskBody);
  await new Promise(resolve => setTimeout(resolve, 1050));
  const failed = (await f.request(`/tasks/${task.body.id}`)).body;
  assert.equal(failed.status, 'Failed'); assert.match(failed.error, /таймаут/);
});

test('missing session.closed remains explicitly Unconfirmed', async t => {
  const f = await setup(t);
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  f.sockets[0].send = raw => f.sockets[0].sent.push(JSON.parse(raw));
  const closed = await f.request('/live/live_test/close', {});
  assert.equal(closed.body.finalization_confirmed, false);
  assert.equal(closed.body.state, 'Unconfirmed');
});

 test('SDP retains its exact terminating CRLF at the upstream boundary', async t => {
  const f = await setup(t);
  const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp });
  assert.equal(f.offers[0], sdp);
});

test('voice and per-session limit reach the Live config; unknown voice is rejected', async t => {
  const f = await setup(t);
  assert.equal((await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', voice: 'not-a-voice' })).status, 400);
  assert.equal((await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', max_seconds: 5 })).status, 400);
  const created = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', voice: 'cedar', max_seconds: 300 });
  assert.equal(created.status, 201);
  assert.deepEqual(f.sessions.at(-1).audio, { output: { voice: 'cedar' } });
  assert.equal(created.body.session.max_seconds, 300);
  assert.equal(created.body.pricing.live_per_minute, 0.05);
  const record = f.app.store.state.sessions.at(-1);
  assert.equal(record.max_seconds, 300);
  // Longer than the server cap is clamped, not trusted.
  await f.request(`/live/${record.id}/close`, {});
  const capped = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', max_seconds: 999999 });
  assert.equal(capped.body.session.max_seconds, f.config.maxLiveSeconds);
  const plain = sessionConfig(f.config, readKnowledge(f.dir), { transcripts: [] }, null, null);
  assert.equal(plain.audio, undefined);
});

test('editing rules persists, keeps a default copy and updates a running session', async t => {
  const f = await setup(t);
  const knowledge = await f.request('/knowledge');
  assert.match(knowledge.body.data, /Project Alpha/);
  assert.ok(knowledge.body.voices.includes('marin'));
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  const original = readFileSync(resolve(f.dir, 'rules.md'), 'utf8');
  const rules = '# Разговор\nОтвечай только стихами.\n# Знания и задачи\nНе выдумывай.';
  const saved = await f.request('/knowledge/rules', { rules });
  assert.equal(saved.status, 200);
  assert.equal(saved.body.applied_sessions, 1);
  assert.equal(readFileSync(resolve(f.dir, 'rules.md'), 'utf8'), rules);
  assert.equal(readFileSync(resolve(f.dir, 'rules.default.md'), 'utf8'), original);
  const sent = f.sockets[0].sent;
  const update = sent.find(e => e.type === 'session.update');
  assert.equal(update.session.delegation.type, 'responses');
  assert.match(update.session.delegation.responses.instructions, /Не выдумывай/);
  const appended = sent.filter(e => e.type === 'session.instructions.append');
  assert.ok(appended.length >= 1);
  assert.equal(appended[0].delegation_id, null);
  assert.match(appended.map(e => e.content).join(''), /стихами/);
  assert.ok(appended.every(e => e.content.length < 1100));
  assert.equal((await f.request('/knowledge/rules', { rules: '  ' })).status, 400);
});

test('usage combines voice seconds, delegation tokens and task tokens', async t => {
  const f = await setup(t);
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' });
  const ws = f.sockets[0];
  const emit = e => ws.emit('message', Buffer.from(JSON.stringify(e)));
  emit({ type: 'session.usage.updated', event_id: 'u1', usage: { seconds: 120 } });
  const done = { type: 'response.event', event: { type: 'response.completed', response: { id: 'resp_1', usage: { input_tokens: 1000000, output_tokens: 0 } } } };
  emit({ ...done, event_id: 'r1' }); emit({ ...done, event_id: 'r2' });
  const id = f.app.store.state.sessions.at(-1).id;
  const beat = await f.request(`/live/${id}/heartbeat`, {});
  assert.ok(Math.abs(beat.body.cost.voice_usd - 0.1) < 1e-9);
  assert.ok(Math.abs(beat.body.cost.backend_usd - 0.1) < 1e-9, 'same response counted once');
  await f.request('/tasks', f.taskBody); f.complete(); await tick(); await tick();
  const usage = await f.request('/usage');
  assert.equal(usage.status, 200);
  assert.ok(Math.abs(usage.body.tasks_usd - 10 * 0.5 / 1e6) < 1e-12);
  assert.ok(usage.body.total_usd > 0.2);
});

test('voice switch replaces the running session and keeps the conversation', async t => {
  const f = await setup(t);
  const first = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', voice: 'marin' });
  f.sockets[0].emit('message', Buffer.from(JSON.stringify({ type: 'session.input_transcript.delta', event_id: 'tx1', delta: 'Расскажи про Project Alpha' })));
  // Without replaces a second session is refused.
  assert.equal((await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer' })).status, 409);
  const second = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', voice: 'cedar', replaces: first.body.session.id });
  assert.equal(second.status, 201);
  assert.notEqual(second.body.session.id, first.body.session.id);
  await tick();
  assert.equal(f.app.store.session('client_a', first.body.session.id).finalization_confirmed, true);
  assert.ok(f.app.live.connections.has(second.body.session.id));
  assert.match(second.body.opening, /сменил твой голос/);
  const config = f.sessions.at(-1);
  assert.deepEqual(config.audio, { output: { voice: 'cedar' } });
  assert.ok(config.input.some(i => i.role === 'user' && /Project Alpha/.test(i.content[0].text)));
  assert.ok(config.input.some(i => i.role === 'developer'));
  assert.ok(f.sockets[0].sent.some(e => e.type === 'session.close'), 'old session is closed');
  assert.equal((await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', replaces: 'unknown_id' })).status, 404);
});

function fakeCodex() {
  const codex = new Emitter(); codex.calls = []; codex.threads = 0;
  codex.ensureThread = async (id) => id || `thread_${++codex.threads}`;
  codex.stop = () => {};
  const note = (method, params) => queueMicrotask(() => codex.emit('notification', { method, params }));
  codex.note = note;
  codex.call = async (method, params) => {
    codex.calls.push({ method, params });
    if (method === 'thread/realtime/start') { note('thread/realtime/started', { threadId: params.threadId, version: 'v3' }); note('thread/realtime/sdp', { threadId: params.threadId, sdp: 'cli-answer' }); }
    if (method === 'thread/realtime/stop') note('thread/realtime/closed', { threadId: params.threadId, reason: 'requested' });
    return {};
  };
  return codex;
}

test('CLI mode: Codex realtime v3 answers the SDP; transcript and close are relayed', async t => {
  const codex = fakeCodex();
  const f = await setup(t, { codex });
  assert.equal((await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', mode: 'cli', voice: 'marin' })).status, 400, 'API voices are not CLI voices');
  const created = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', mode: 'cli', voice: 'sol' });
  assert.equal(created.status, 201);
  assert.equal(created.body.transport.sdp, 'cli-answer');
  assert.equal(created.body.session.mode, 'cli');
  const start = codex.calls.find(c => c.method === 'thread/realtime/start').params;
  assert.equal(start.version, 'v3'); assert.equal(start.transport.type, 'webrtc'); assert.equal(start.voice, 'sol');
  assert.equal(f.sessions.length, 0, 'no paid API session is created');
  assert.equal(f.app.store.conversation('client_a', 'conversation_a').codex_thread_id, 'thread_1');
  const beat = await f.request(`/live/${created.body.session.id}/heartbeat`, {});
  assert.equal(beat.body.mode, 'cli');
  const closed = await f.request(`/live/${created.body.session.id}/close`, {});
  assert.equal(closed.body.finalization_confirmed, true);
  assert.ok(codex.calls.some(c => c.method === 'thread/realtime/stop'));
});

test('CLI mode: a Codex turn finishing after hang-up becomes a callback task', async t => {
  const codex = fakeCodex();
  const f = await setup(t, { codex });
  const created = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', mode: 'cli' });
  codex.emit('notification', { method: 'turn/started', params: { threadId: 'thread_1', turn: { id: 'turn_1' } } });
  codex.emit('notification', { method: 'item/completed', params: { threadId: 'thread_1', turnId: 'turn_1', item: { type: 'userMessage', content: [{ type: 'text', text: '<realtime_delegation>\n<input>Посчитай файлы</input>\n</realtime_delegation>' }] } } });
  let task = f.app.store.state.tasks.at(-1);
  assert.equal(task.status, 'Running'); assert.equal(task.title, 'Посчитай файлы'); assert.equal(task.mode, 'cli');
  await f.request(`/live/${created.body.session.id}/close`, {});
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread_1', turn: { id: 'turn_1', status: 'completed', items: [
    { type: 'agentMessage', phase: 'commentary', text: 'Считаю…' }, { type: 'agentMessage', phase: 'final_answer', text: 'В папке 3 файла.' }] } } });
  task = f.app.store.state.tasks.at(-1);
  assert.equal(task.status, 'Completed'); assert.equal(task.result, 'В папке 3 файла.'); assert.equal(task.delivered, false);
  // "Answer" resumes the same Codex thread in CLI mode.
  const answer = await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', task_id: task.id });
  assert.equal(answer.status, 201); assert.equal(answer.body.session.mode, 'cli');
  assert.equal(codex.calls.filter(c => c.method === 'thread/realtime/start').at(-1).params.threadId, 'thread_1');
});

test('CLI mode: a turn finishing during the call is marked delivered (no callback)', async t => {
  const codex = fakeCodex();
  const f = await setup(t, { codex });
  await f.request('/live/session', { conversation_id: 'conversation_a', sdp: 'offer', mode: 'cli' });
  codex.emit('notification', { method: 'turn/started', params: { threadId: 'thread_1', turn: { id: 'turn_live' } } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'thread_1', turn: { id: 'turn_live', status: 'completed', items: [{ type: 'agentMessage', phase: 'final_answer', text: 'Готово' }] } } });
  assert.equal(f.app.store.taskByTurn('turn_live').delivered, true);
});
