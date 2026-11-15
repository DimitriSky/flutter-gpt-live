import { createHash, randomUUID } from 'node:crypto';
import { readKnowledge } from './config.js';
import { historyInput, publicTask } from './task_store.js';
import { AppError, requireText, requireId } from './errors.js';

export class TaskManager {
  constructor({ store, api, config, publish }) {
    Object.assign(this, { store, api, config, publish });
    this.active = new Map(); this.stopping = false;
  }
  recover() {
    // Retrying an ambiguous paid call could duplicate work and spend. Keep its failure visible.
    for (const task of this.store.state.tasks.filter(t => t.status === 'Running')) {
      this.store.updateTask(task.id, { status: 'Failed', completed_at: new Date().toISOString(),
        error: 'Сервер был перезапущен во время выполнения. Результат API не подтверждён; автоматический повтор отключён.' });
    }
    this.schedule();
  }
  create(owner, body, knowledge) {
    const conversationId = requireId(body.conversation_id, 'conversation_id');
    const description = requireText(body.description, 'description');
    const title = requireText(body.title || description.slice(0, 70), 'title', 120);
    const key = requireText(body.idempotency_key, 'idempotency_key', 240);
    const existing = this.store.existing(owner, key);
    if (existing) {
      if (existing.description !== description || existing.conversation_id !== conversationId || existing.title !== title) throw new AppError(409, 'Этот ключ уже использован для другого задания.');
      return { task: publicTask(existing), created: false };
    }
    if (!this.config.apiKey) throw new AppError(503, 'На сервере не настроен OPENAI_API_KEY.');
    const conversation = this.store.conversation(owner, conversationId);
    const snapshot = { ...(knowledge || readKnowledge(this.config.configDir)), history: historyInput(conversation) };
    const result = this.store.insertTask({ id: randomUUID(), owner, conversation_id: conversationId,
      description, title, idempotency_key: key, status: 'Queued', created_at: new Date().toISOString(),
      started_at: null, completed_at: null, result: null, error: null, response_id: null, usage: null, snapshot,
    }, this.config.maxPending);
    if (result.created) { this.emit(result.task, 'task.created'); this.schedule(); }
    return { task: publicTask(result.task), created: result.created };
  }
  createFromTool(owner, conversationId, args, knowledge) {
    const description = requireText(args.description, 'description');
    const hash = createHash('sha256').update(description).digest('hex');
    // A reconnect or a repeated model call cannot launch the same confirmed task twice.
    return this.create(owner, { ...args, conversation_id: conversationId, idempotency_key: `voice:${conversationId}:${hash}` }, knowledge);
  }
  emit(task, type) { this.publish(task.owner, { type, task: publicTask(task) }); }
  schedule() {
    if (this.stopping || this.scheduled) return;
    this.scheduled = true;
    setImmediate(() => { this.scheduled = false; this.pump(); });
  }
  pump() {
    if (this.stopping) return;
    while (this.active.size < this.config.concurrency) {
      const task = this.store.state.tasks.find(t => t.status === 'Queued');
      if (!task) break;
      const controller = new AbortController();
      const promise = this.run(task.id, controller);
      this.active.set(task.id, { controller, promise });
      promise.finally(() => { this.active.delete(task.id); this.schedule(); }).catch(() => {});
    }
  }
  async run(id, controller) {
    const timer = setTimeout(() => controller.abort(new Error('timeout')), this.config.taskTimeout);
    try {
      const task = this.store.updateTask(id, { status: 'Running', started_at: new Date().toISOString() });
      this.emit(task, 'task.running');
      const result = await this.api.runTask(task, controller.signal);
      if (controller.signal.aborted) throw controller.signal.reason;
      const completed = this.store.updateTask(id, { ...result, status: 'Completed', completed_at: new Date().toISOString() });
      console.log(JSON.stringify({ type: 'task.usage', task_id: id, response_id: result.response_id, usage: result.usage }));
      this.emit(completed, 'task.completed');
    } catch (error) {
      const failed = this.store.updateTask(id, { status: 'Failed', completed_at: new Date().toISOString(),
        error: controller.signal.aborted ? 'Выполнение прервано по таймауту или при остановке сервера. Итог API не подтверждён.' : error instanceof AppError ? error.message : 'Ошибка выполнения текстового задания.',
        response_id: error.responseId || null, usage: error.usage || null });
      this.emit(failed, 'task.failed');
    } finally { clearTimeout(timer); }
  }
  async stop() {
    this.stopping = true;
    for (const { controller } of this.active.values()) controller.abort();
    await Promise.allSettled([...this.active.values()].map(a => a.promise));
  }
}
