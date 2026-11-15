import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { EventEmitter, once } from 'node:events';
import WebSocket from 'ws';
import { createApplication } from '../src/server.js';
import { configuration, readKnowledge } from '../src/config.js';
import { TaskStore } from '../src/task_store.js';
import { sessionConfig } from '../src/live.js';
import { TaskManager } from '../src/task_worker.js';

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
  const sockets = []; const offers = [];
  const api = { post: async (path, body) => {
    if (path === '/live/sessions') { offers.push(body.transport.sdp); return { session: { id: 'live_test' }, transport: { type: 'webrtc', sdp: 'answer' } }; }
    return {};
  }, runTask: async (task, signal) => Promise.race([done, new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }))]) };
  const app = createApplication({ ...config, ...options }, { api, socketFactory: () => { const ws = fakeSocket(); sockets.push(ws); return ws; } });
  const address = await app.start();
  t.after(() => app.stop());
  const headers = { Authorization: `Bearer ${config.token}`, 'X-Client-ID': 'client_a', 'Content-Type': 'application/json' };
  const request = async (path, body, extra = {}) => {
    const response = await fetch(`http://127.0.0.1:${address.port}${path}`, { headers: { ...headers, ...extra }, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() };
  };
  const taskBody = { conversation_id: 'conversation_a', title: 'Отчёт', description: 'Составь отчёт по моей базе', idempotency_key: 'request_a' };
  return { app, config, dir, request, taskBody, sockets, offers, complete: () => complete({ result: 'Отчёт: Project Alpha', response_id: 'resp_test', usage: { output_tokens: 10 } }) };
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
