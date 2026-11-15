import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { configuration } from '../src/config.js';

// Explicit opt-in live API smoke; never runs under npm test.
const config = configuration();
const origin = `http://127.0.0.1:${config.port}`;
const headers = { Authorization: `Bearer ${config.token}`, 'X-Client-ID': 'smoke_openai', 'Content-Type': 'application/json' };
async function request(path, body) {
  const r = await fetch(origin + path, { headers, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}) });
  const json = await r.json();
  if (!r.ok) throw new Error(`Backend HTTP ${r.status}: ${json.error}`);
  return json;
}
const body = { conversation_id: 'smoke_conversation', title: 'Проверка реальной базы', description: 'Как называется мой проект? Ответь одним предложением строго по базе знаний.', idempotency_key: randomUUID() };
const task = await request('/tasks', body);
assert.equal((await request('/tasks', body)).id, task.id);
const deadline = Date.now() + config.taskTimeout + 5000;
while (Date.now() < deadline) {
  const current = await request(`/tasks/${task.id}`);
  if (current.status === 'Failed') throw new Error(current.error);
  if (current.status === 'Completed') {
    assert.match(current.result, /Project Alpha/);
    console.log(JSON.stringify({ status: 'passed', task_id: current.id, response_id: current.response_id, usage: current.usage, grounded_in_knowledge: true }));
    process.exit(0);
  }
  await new Promise(r => setTimeout(r, 500));
}
throw new Error('Smoke timeout');
