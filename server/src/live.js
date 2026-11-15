import WebSocket from 'ws';
import { randomUUID } from 'node:crypto';
import { readKnowledge, agentInstructions } from './config.js';
import { historyInput } from './task_store.js';
import { AppError, requireId, requireText } from './errors.js';

export const taskTool = {
  type: 'function', name: 'enqueue_text_task',
  description: 'Register an independent background text job ONLY when the user explicitly asks for background work / a report and callback. Use the confirmed task text. Ordinary factual questions should be answered directly from knowledge. The result confirms durable acceptance, not completion.',
  strict: true,
  parameters: { type: 'object', additionalProperties: false, properties: {
    title: { type: 'string', description: 'Short Russian task title (max 120 characters)' },
    description: { type: 'string', description: 'Exact confirmed text assignment, including relevant user details and requested output (max 12000 characters)' },
  }, required: ['title', 'description'] },
};

export const callbackOpening = 'Начни разговор сейчас: кратко сообщи, что запрошенный отчёт готов, назови один-два фактических вывода из сохранённого результата и предложи обсудить детали. Соблюдай язык и стиль разговорных правил. Затем сделай паузу и слушай.';

export function sessionConfig(config, knowledge, conversation, task) {
  const input = historyInput(conversation, task ? 1000 : 6000);
  if (task) input.push({ type: 'message', role: 'user', content: [{ type: 'input_text', text:
    `Я нажал «Ответить» на готовую задачу. Задание: ${task.description.slice(0, 1000)}\nТочный сохранённый результат:\n${task.result}` }] });
  if (task) input.push({ type: 'message', role: 'developer', content: [{ type: 'input_text', text: callbackOpening }] });
  return {
    model: 'gpt-live-1', store: false,
    instructions: `${knowledge.conversationRules}\n\nСлужебные правила голоса:\n` +
      'Для фактов из базы, анализа и постановки задач обращайся к backend. ' +
      'Обычные приветствия, угу, ага и перебивания обрабатывай сам. ' +
      'Когда пользователь явно просит длительное текстовое задание в фоне и позвать по готовности, делегируй backend постановку enqueue_text_task. ' +
      'Если текст задания неоднозначен, сначала уточни и подтверди его. ' +
      'Не обещай запуск до получения task_id от сервера. После подтверждения коротко сообщи, что задача принята и можно нажать End Conversation. ' +
      'Сам не завершай звонок. Не читай внутренние идентификаторы вслух. ' +
      'Не утверждай, что предыдущее голосовое подключение продолжало работать. ' +
      (task ? 'Это новая сессия по нажатию «Ответить». Начни с краткого обзора переданного реального результата и предложи обсудить детали.' : ''),
    input,
    delegation: { type: 'responses', responses: {
      model: config.textModel,
      instructions: agentInstructions(knowledge) + '\nДля обычного вопроса по базе ответь кратко. ' +
        'Только по явному запросу фоновой работы вызови enqueue_text_task; не выполняй длительный отчёт внутри голосовой сессии. ' +
        'После успешного инструмента сообщи task_id и статус голосовому ассистенту. Если инструмент вернул ошибку, честно сообщи, что запуск не подтверждён.',
      tools: [taskTool], tool_choice: 'auto', parallel_tool_calls: false,
      max_output_tokens: config.maxOutputTokens,
    } },
  };
}

export class LiveManager {
  constructor({ config, store, api, tasks, publish, socketFactory }) {
    Object.assign(this, { config, store, api, tasks, publish });
    this.socketFactory = socketFactory || ((url, opts) => new WebSocket(url, opts));
    this.connections = new Map(); this.creating = new Set(); this.stopping = false;
    this.timer = setInterval(() => this.sweep(), 5000); this.timer.unref();
  }
  async create(owner, body) {
    if (this.stopping) throw new AppError(503, 'Сервер останавливается.');
    if (this.creating.has(owner) || [...this.connections.values()].some(c => c.record.owner === owner && !c.confirmed)) {
      throw new AppError(409, 'Сначала завершите текущую голосовую сессию.');
    }
    const conversationId = requireId(body.conversation_id, 'conversation_id');
    requireText(body.sdp, 'sdp', 64000);
    // SDP is a wire format: preserve its terminating CRLF, never trim it.
    const sdp = body.sdp;
    const conversation = this.store.conversation(owner, conversationId);
    const task = body.task_id ? this.store.task(owner, requireId(body.task_id, 'task_id')) : null;
    if (task && (task.status !== 'Completed' || task.conversation_id !== conversationId)) throw new AppError(409, 'Результат этого разговора ещё не готов.');
    const knowledge = readKnowledge(this.config.configDir);
    this.creating.add(owner);
    let record;
    try {
      const result = await this.api.post('/live/sessions', { session: sessionConfig(this.config, knowledge, conversation, task), transport: { type: 'webrtc', sdp } });
      if (!result.session?.id || !result.transport?.sdp) throw new AppError(502, 'OpenAI вернул некорректный SDP answer.');
      record = this.store.saveSession({ id: result.session.id, owner, conversation_id: conversationId,
        state: 'Active', created_at: new Date().toISOString(), usage: null, finalization_confirmed: false });
      await this.attach(record, knowledge);
      if (this.stopping) { await this.close(owner, record.id); throw new AppError(503, 'Сервер останавливается.'); }
      return { session: { id: record.id }, transport: result.transport, ...(task ? { opening: callbackOpening } : {}) };
    } catch (error) {
      if (record) {
        try { await this.close(owner, record.id); } catch { /* lease/recovery will retry */ }
      }
      throw error;
    } finally { this.creating.delete(owner); }
  }
  async attach(record, knowledge, recovering = false) {
    const ws = this.socketFactory(`wss://api.openai.com/v1/live/sessions/${encodeURIComponent(record.id)}/attach`, {
      headers: { Authorization: `Bearer ${this.config.apiKey}` }, maxPayload: 2 * 1024 * 1024,
    });
    const connection = { ws, record, knowledge, confirmed: false, closing: recovering,
      seen: new Set(), calls: new Set(), lease: Date.now() + this.config.leaseMs };
    connection.closed = new Promise(resolve => { connection.resolveClosed = resolve; });
    this.connections.set(record.id, connection);
    ws.on('message', data => {
      try { this.onEvent(connection, JSON.parse(data.toString())); }
      catch { this.publish(record.owner, { type: 'live.error', session_id: record.id, message: 'Ошибка обработки серверного события.' }); void this.close(record.owner, record.id).catch(() => {}); }
    });
    ws.on('error', () => {});
    ws.on('close', () => {
      if (connection.confirmed) return;
      this.publish(record.owner, { type: 'live.error', session_id: record.id, message: 'Потерян серверный канал голосовой сессии. Разговор завершается.' });
      void this.close(record.owner, record.id).catch(() => {});
    });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { ws.terminate(); reject(new AppError(502, 'Не удалось подключить серверный канал GPT-Live.')); }, 10000);
      const finish = fn => arg => { clearTimeout(timeout); fn(arg); };
      ws.once('open', finish(resolve)); ws.once('error', finish(() => reject(new AppError(502, 'Ошибка подключения к GPT-Live sideband.'))));
      ws.once('close', finish(() => reject(new AppError(502, 'GPT-Live sideband закрыт до подключения.'))));
    });
  }
  send(c, event) {
    if (c.ws.readyState !== WebSocket.OPEN) throw new Error('Sideband unavailable');
    c.ws.send(JSON.stringify({ event_id: randomUUID(), ...event }));
  }
  onEvent(c, event) {
    if (event.event_id) {
      if (c.seen.has(event.event_id)) return;
      c.seen.add(event.event_id);
      if (c.seen.size > 4000) c.seen.delete(c.seen.values().next().value);
    }
    if (event.type === 'session.closed') {
      c.confirmed = true;
      const final = this.store.updateSession(c.record.id, { state: 'Closed', finalization_confirmed: true,
        usage: event.usage, reason: event.reason, completed_at: new Date().toISOString() });
      console.log(JSON.stringify({ type: 'live.usage', session_id: c.record.id, usage: event.usage, reason: event.reason }));
      c.resolveClosed(final); c.ws.close();
      this.publish(c.record.owner, { type: 'live.closed', session_id: c.record.id, usage: event.usage });
      this.connections.delete(c.record.id); return;
    }
    if (event.type === 'session.usage.updated') this.store.updateSession(c.record.id, { usage: event.usage });
    if (['session.input_transcript.delta', 'session.output_transcript.delta'].includes(event.type) && typeof event.delta === 'string') {
      this.store.transcript(c.record.owner, c.record.conversation_id, c.record.id, { ...event, delta: event.delta.slice(0, 5000) });
    }
    if (event.type === 'error') {
      this.publish(c.record.owner, { type: 'live.error', session_id: c.record.id,
        message: 'GPT-Live сообщил об ошибке конфигурации или выполнения. Проверьте сервер и доступ к модели.' });
      console.error(JSON.stringify({ type: 'live.error', session_id: c.record.id, code: event.error?.code }));
    }
    if (event.type !== 'response.event') return;
    const nested = event.event;
    if (nested?.type === 'response.completed') {
      console.log(JSON.stringify({ type: 'delegation.usage', session_id: c.record.id, response_id: nested.response?.id, usage: nested.response?.usage }));
    }
    if (nested?.type !== 'response.output_item.done' || nested.item?.type !== 'function_call' || c.closing) return;
    const call = nested.item;
    if (c.calls.has(call.call_id)) return;
    c.calls.add(call.call_id);
    let output;
    try {
      if (call.name !== 'enqueue_text_task') throw new AppError(400, 'Инструмент недоступен.');
      const { task } = this.tasks.createFromTool(c.record.owner, c.record.conversation_id, JSON.parse(call.arguments), c.knowledge);
      output = { task_id: task.id, status: task.status, title: task.title, description: task.description, durable: true };
    } catch (error) { output = { error: error instanceof AppError ? error.message : 'Некорректные аргументы инструмента.', accepted: false }; }
    this.send(c, { type: 'response.item.create', item: { type: 'function_call_output', call_id: call.call_id, output: JSON.stringify(output) } });
    this.send(c, { type: 'response.create' });
  }
  heartbeat(owner, id) {
    this.store.session(owner, id);
    const c = this.connections.get(id);
    if (!c || c.closing) throw new AppError(409, 'Голосовая сессия завершена.');
    c.lease = Date.now() + this.config.leaseMs;
    return { ok: true };
  }
  async close(owner, id) {
    const saved = this.store.session(owner, id);
    if (saved.finalization_confirmed) return saved;
    const c = this.connections.get(id);
    if (c?.closeOperation) return c.closeOperation;
    const operation = (async () => {
      if (c) {
        c.closing = true;
        try { this.send(c, { type: 'session.close' }); } catch { /* try remote hangup below */ }
        const final = await Promise.race([c.closed, new Promise(resolve => {
          const t = setTimeout(() => resolve(null), 7000); t.unref(); c.closed.finally(() => clearTimeout(t));
        })]);
        if (final) return final;
      }
      // Official control endpoint is a fallback. Only session.closed confirms final usage.
      let hangupAccepted = false;
      try { await this.api.post(`/live/sessions/${encodeURIComponent(id)}/hangup`, undefined, AbortSignal.timeout(5000)); hangupAccepted = true; } catch { /* remain unconfirmed */ }
      if (c) {
        const final = await Promise.race([c.closed, new Promise(resolve => {
          const t = setTimeout(() => resolve(null), 2000); t.unref(); c.closed.finally(() => clearTimeout(t));
        })]);
        if (final) return final;
        c.ws.terminate(); this.connections.delete(id);
      }
      return this.store.updateSession(id, { state: 'Unconfirmed', finalization_confirmed: false, hangup_accepted: hangupAccepted });
    })();
    if (c) c.closeOperation = operation;
    return operation;
  }
  sweep() {
    for (const c of this.connections.values()) {
      if (Date.now() > c.lease || Date.now() - Date.parse(c.record.created_at) > this.config.maxLiveSeconds * 1000) {
        void this.close(c.record.owner, c.record.id).catch(() => {});
      }
    }
  }
  async recover() {
    for (const record of this.store.state.sessions.filter(s => !s.finalization_confirmed)) {
      try { await this.attach(record, readKnowledge(this.config.configDir), true); } catch { /* close fallback */ }
      await this.close(record.owner, record.id);
    }
  }
  async stop() {
    this.stopping = true; clearInterval(this.timer);
    await Promise.allSettled([...this.connections.values()].map(c => this.close(c.record.owner, c.record.id)));
  }
}
