import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { configuration, knowledgeFiles, writeRules, writeData, readKnowledge, textCost, VOICES } from './config.js';
import { AppError, requireId } from './errors.js';
import { TaskStore, publicTask } from './task_store.js';
import { OpenAIAPI } from './agent.js';
import { TaskManager } from './task_worker.js';
import { EventSocket } from './event_socket.js';
import { LiveManager, liveCost } from './live.js';
import { CodexAppServer, CLI_VOICES, CLI_DEFAULT_VOICE } from './codex_bridge.js';
import { mkdirSync } from 'node:fs';

export function createApplication(config, dependencies = {}) {
  const store = dependencies.store || new TaskStore(config.storageDir);
  const api = dependencies.api || new OpenAIAPI(config);
  const authenticate = request => {
    const expected = Buffer.from(`Bearer ${config.token}`);
    const actual = Buffer.from(request.headers.authorization || '');
    if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) throw new AppError(401, 'Неверный токен backend.');
    return requireId(request.headers['x-client-id'], 'X-Client-ID');
  };
  const server = createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    const reply = (status, value) => { response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' }); response.end(JSON.stringify(value)); };
    try {
      const owner = authenticate(request);
      const url = new URL(request.url, 'http://localhost');
      const path = url.pathname;
      if (request.method === 'GET' && path === '/health') return reply(200, { ok: true, api_key_configured: Boolean(config.apiKey), text_model: config.textModel });
      if (request.method === 'GET' && path === '/tasks') return reply(200, { tasks: store.list(owner, url.searchParams.get('conversation_id')).map(t => publicTask(t)) });
      if (request.method === 'GET' && path === '/knowledge') {
        return reply(200, { ...knowledgeFiles(config.configDir), voices: VOICES, default_voice: 'marin', cli_voices: CLI_VOICES, cli_default_voice: CLI_DEFAULT_VOICE, max_live_seconds: config.maxLiveSeconds, pricing: config.pricing });
      }
      if (request.method === 'GET' && path === '/usage') return reply(200, usageSummary(owner));
      const taskPath = path.match(/^\/tasks\/([a-zA-Z0-9_-]+)$/);
      if (request.method === 'GET' && taskPath) return reply(200, publicTask(store.task(owner, taskPath[1]), true));
      if (request.method !== 'POST') throw new AppError(404, 'Endpoint не найден.');
      if (!(request.headers['content-type'] || '').startsWith('application/json')) throw new AppError(415, 'Требуется application/json.');
      const chunks = []; let bytes = 0;
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > 96000) throw new AppError(413, 'Слишком большой запрос.');
        chunks.push(chunk);
      }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new AppError(400, 'Некорректный JSON.'); }
      if (!body || Array.isArray(body) || typeof body !== 'object') throw new AppError(400, 'Требуется JSON object.');
      if (path === '/knowledge/rules') {
        try { writeRules(config.configDir, body.rules); } catch (error) {
          if (error instanceof RangeError) throw new AppError(400, error.message === 'empty' ? 'Инструкции не могут быть пустыми.' : 'Инструкции больше 48 KB.', 'invalid_input');
          throw error;
        }
        const knowledge = readKnowledge(config.configDir);
        const applied = live.applyRules(knowledge);
        console.log(JSON.stringify({ type: 'rules.updated', bytes: Buffer.byteLength(body.rules), ...applied }));
        return reply(200, { ...knowledgeFiles(config.configDir), ...applied });
      }
      if (path === '/knowledge/data') {
        try { writeData(config.configDir, body.data); } catch (error) {
          if (error instanceof RangeError) throw new AppError(400, error.message === 'empty' ? 'База знаний должна быть текстом.' : 'База знаний больше 48 KB.', 'invalid_input');
          throw error;
        }
        const knowledge = readKnowledge(config.configDir);
        const applied = live.applyKnowledge(knowledge, 'data');
        console.log(JSON.stringify({ type: 'data.updated', bytes: Buffer.byteLength(body.data), ...applied }));
        return reply(200, { ...knowledgeFiles(config.configDir), ...applied });
      }
      if (path === '/tasks') {
        const result = tasks.create(owner, body); return reply(result.created ? 201 : 200, result.task);
      }
      if (path === '/live/session') {
        const result = await live.create(owner, body);
        if (response.destroyed) { await live.close(owner, result.session.id); return; }
        return reply(201, result);
      }
      const control = path.match(/^\/live\/([a-zA-Z0-9_-]+)\/(close|heartbeat)$/);
      if (control) return reply(200, control[2] === 'close' ? await live.close(owner, control[1]) : live.heartbeat(owner, control[1]));
      throw new AppError(404, 'Endpoint не найден.');
    } catch (error) {
      if (response.destroyed) return;
      if (!(error instanceof AppError)) console.error(JSON.stringify({ type: 'server.error', name: error.name, code: error.code }));
      reply(error instanceof AppError ? error.status : 500, { error: error instanceof AppError ? error.message : 'Внутренняя ошибка сервера.', code: error.code || 'internal_error' });
    }
  });
  server.requestTimeout = 60000; server.headersTimeout = 10000;
  const events = new EventSocket(server, authenticate);
  const publish = (owner, event) => events.publish(owner, event);
  const usageSummary = owner => {
    const sessions = store.state.sessions.filter(s => s.owner === owner).map(s => liveCost(s, config.pricing));
    const tasksUsd = store.state.tasks.filter(t => t.owner === owner).reduce((sum, t) => sum + textCost(t.usage, config.pricing), 0);
    const voice = sessions.reduce((sum, s) => sum + s.voice_usd, 0);
    const backend = sessions.reduce((sum, s) => sum + s.backend_usd, 0);
    return { sessions: sessions.length, voice_seconds: sessions.reduce((sum, s) => sum + s.seconds, 0),
      voice_usd: voice, backend_usd: backend, tasks_usd: tasksUsd, total_usd: voice + backend + tasksUsd, pricing: config.pricing };
  };
  const tasks = new TaskManager({ store, api, config, publish });
  let codex = dependencies.codex;
  if (codex === undefined) {
    mkdirSync(config.codexCwd, { recursive: true });
    codex = new CodexAppServer({ bin: config.codexBin, cwd: config.codexCwd });
  }
  const live = new LiveManager({ store, api, tasks, config, publish, socketFactory: dependencies.socketFactory, codex });
  return {
    server, store, tasks, live,
    async start() {
      await live.recover(); tasks.recover();
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(config.port, config.host, resolve); });
      return server.address();
    },
    async stop() { await live.stop(); codex?.stop(); await tasks.stop(); events.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); store.close(); },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const app = createApplication(configuration());
    const address = await app.start();
    console.log(JSON.stringify({ type: 'server.ready', host: address.address, port: address.port }));
    let stopping = false;
    const stop = async () => { if (stopping) return; stopping = true; await app.stop(); };
    process.once('SIGINT', stop); process.once('SIGTERM', stop);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
