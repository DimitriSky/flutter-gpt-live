import { mkdirSync, readFileSync, openSync, writeFileSync, fsyncSync, closeSync, renameSync, unlinkSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { AppError } from './errors.js';

// One server process per storage directory. Every mutation is an atomic fsynced snapshot.
export class TaskStore {
  constructor(dir) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    this.file = resolve(dir, 'state.json');
    this.lock = resolve(dir, 'server.lock');
    try {
      const pid = Number(readFileSync(this.lock, 'utf8'));
      try { process.kill(pid, 0); throw new Error('Storage is already open by another server'); }
      catch (error) { if (error.code !== 'ESRCH') throw error; }
      unlinkSync(this.lock);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const fd = openSync(this.lock, 'wx', 0o600);
    writeFileSync(fd, String(process.pid)); closeSync(fd);
    try {
      try { this.state = JSON.parse(readFileSync(this.file, 'utf8')); }
      catch (error) {
        if (error.code !== 'ENOENT') throw error;
        this.state = { version: 1, tasks: [], conversations: [], sessions: [] };
      }
      if (this.state.version !== 1 || !Array.isArray(this.state.tasks) || !Array.isArray(this.state.sessions)) throw new Error('Invalid storage format');
    } catch (error) { this.close(); throw error; }
  }
  commit(change) {
    const next = structuredClone(this.state);
    const result = change(next);
    const temp = `${this.file}.${randomUUID()}.tmp`;
    const fd = openSync(temp, 'wx', 0o600);
    try { writeFileSync(fd, JSON.stringify(next)); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(temp, this.file);
    this.state = next;
    return structuredClone(result);
  }
  close() { try { unlinkSync(this.lock); } catch (e) { if (e.code !== 'ENOENT') throw e; } }
  conversation(owner, id) {
    const c = this.state.conversations.find(c => c.id === id);
    if (c && c.owner !== owner) throw new AppError(404, 'Разговор не найден.');
    if (c) return structuredClone(c);
    return this.commit(s => {
      const c = { id, owner, created_at: new Date().toISOString(), transcripts: [] };
      s.conversations.push(c); return c;
    });
  }
  transcript(owner, conversationId, sessionId, event) {
    this.commit(s => {
      const c = s.conversations.find(c => c.id === conversationId && c.owner === owner);
      if (!c) throw new Error('Conversation missing');
      if (event.event_id && c.transcripts.some(t => t.event_id === event.event_id)) return;
      c.transcripts.push({ session_id: sessionId, event_id: event.event_id,
        role: event.type.includes('input_transcript') ? 'user' : 'assistant',
        text: event.delta, start_ms: event.start_ms, end_ms: event.end_ms });
      c.transcripts = c.transcripts.slice(-600);
    });
  }
  list(owner, conversationId) { return structuredClone(this.state.tasks.filter(t => t.owner === owner && (!conversationId || t.conversation_id === conversationId))); }
  task(owner, id) {
    const task = this.state.tasks.find(t => t.id === id && t.owner === owner);
    if (!task) throw new AppError(404, 'Задача не найдена.');
    return structuredClone(task);
  }
  existing(owner, key) { return structuredClone(this.state.tasks.find(t => t.owner === owner && t.idempotency_key === key)); }
  insertTask(task, maxPending) {
    return this.commit(s => {
      const existing = s.tasks.find(t => t.owner === task.owner && t.idempotency_key === task.idempotency_key);
      if (existing) return { task: existing, created: false };
      if (s.tasks.filter(t => ['Queued', 'Running'].includes(t.status)).length >= maxPending) throw new AppError(429, 'Очередь заполнена. Дождитесь завершения задач.');
      s.tasks.push(task); return { task, created: true };
    });
  }
  /**
   * #SINGLE-USER migration (runs once): personal clients become one owner,
   * the most recently used conversation becomes the shared one, and every
   * finished task is marked acknowledged so old results never ring again.
   * Test clients (probe_/smoke_) are left alone.
   */
  migrateSingleUser(owner, main) {
    if (this.state.single_user_migrated) return null;
    return this.commit(s => {
      const personal = o => o !== owner && !/^(probe_|smoke_)/.test(o);
      let moved = 0;
      for (const list of [s.tasks, s.sessions, s.conversations]) {
        for (const r of list) if (personal(r.owner)) { r.owner = owner; moved++; }
      }
      // The conversation with the most history wins (sessions, then transcripts),
      // so a fresh device never replaces the real ongoing conversation.
      const sessionsOf = id => s.sessions.filter(x => x.conversation_id === id).length;
      const mainConv = s.conversations.filter(c => c.owner === owner)
        .sort((a, b) => sessionsOf(b.id) - sessionsOf(a.id) || (b.transcripts?.length || 0) - (a.transcripts?.length || 0))[0];
      let renamed = null;
      if (mainConv && mainConv.id !== main && !s.conversations.some(c => c.id === main)) {
        renamed = mainConv.id;
        for (const r of [...s.tasks, ...s.sessions]) if (r.conversation_id === renamed) r.conversation_id = main;
        mainConv.id = main;
      }
      let acknowledged = 0;
      for (const t of s.tasks) {
        if (t.owner === owner && ['Completed', 'Failed'].includes(t.status) && !t.acknowledged) { t.acknowledged = true; acknowledged++; }
      }
      s.single_user_migrated = new Date().toISOString();
      return { moved, renamed, acknowledged };
    });
  }
  insertCodexTask(task) { return this.commit(s => { s.tasks.push(task); return task; }); }
  taskByTurn(turnId) { return structuredClone(this.state.tasks.find(t => t.codex_turn_id === turnId)); }
  setConversationThread(owner, id, threadId) {
    this.commit(s => { const c = s.conversations.find(c => c.id === id && c.owner === owner); if (c) c.codex_thread_id = threadId; });
  }
  conversationByThread(threadId) { return structuredClone(this.state.conversations.find(c => c.codex_thread_id === threadId)); }
  updateTask(id, patch) { return this.commit(s => Object.assign(s.tasks.find(t => t.id === id), patch)); }
  saveSession(session) { return this.commit(s => { s.sessions.push(session); return session; }); }
  updateSession(id, patch) { return this.commit(s => Object.assign(s.sessions.find(t => t.id === id), patch)); }
  session(owner, id) {
    const session = this.state.sessions.find(t => t.id === id && t.owner === owner);
    if (!session) throw new AppError(404, 'Сессия не найдена.');
    return structuredClone(session);
  }
}

export function publicTask(task, includeResult = false) {
  const { snapshot, owner, idempotency_key, ...rest } = task;
  if (!includeResult) delete rest.result;
  return rest;
}

export function historyInput(conversation, maxCharacters = 6000) {
  const messages = [];
  for (const t of conversation.transcripts.slice(-100)) {
    const previous = messages.at(-1);
    if (previous?.role === t.role && previous.session_id === t.session_id) previous.text += t.text;
    else messages.push({ role: t.role, text: t.text, session_id: t.session_id });
  }
  // Conservative character budget, including Russian text; no false turn-completion claim.
  let budget = maxCharacters;
  const selected = [];
  for (const m of messages.reverse()) {
    if (budget <= 0) break;
    const text = m.text.slice(-Math.min(budget, 2000)); budget -= text.length;
    selected.unshift({ type: 'message', role: m.role, content: [{ type: m.role === 'assistant' ? 'output_text' : 'input_text', text }] });
  }
  return selected;
}
