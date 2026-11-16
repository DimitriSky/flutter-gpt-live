import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import { AppError } from './errors.js';

// Voices accepted by Codex realtime v3 (`thread/realtime/listVoices`, codex 0.169).
export const CLI_VOICES = ['juniper', 'maple', 'spruce', 'ember', 'vale', 'breeze', 'arbor', 'sol', 'cove',
  'aube', 'bubbie', 'haetsal', 'hanul', 'himari', 'leher', 'miko', 'neer', 'porto', 'rindo', 'rio', 'rivage',
  'selva', 'sonna', 'tinta', 'viola'];
export const CLI_DEFAULT_VOICE = 'cove';

/**
 * Minimal JSON-RPC client for `codex app-server` over stdio (EXPERIMENTAL API).
 * Emits every server notification as 'notification' ({method, params}).
 * Auth is the user's ChatGPT login stored by Codex; no API key is involved.
 */
export class CodexAppServer extends EventEmitter {
  constructor({ bin = 'codex', cwd } = {}) {
    super();
    this.bin = bin; this.cwd = cwd;
    this.proc = null; this.ready = null; this.nextId = 1; this.pending = new Map();
    this.loaded = new Set();
  }
  start() {
    if (this.ready) return this.ready;
    this.ready = (async () => {
      const proc = spawn(this.bin, ['app-server'], { cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe'] });
      this.proc = proc;
      proc.on('error', error => this.fail(new AppError(503, `Не удалось запустить Codex (${error.code || error.message}). Установите codex CLI.`, 'codex_unavailable')));
      proc.on('exit', code => this.fail(new AppError(503, `Codex app-server завершился (код ${code}).`, 'codex_exited')));
      proc.stderr.on('data', () => {});
      createInterface({ input: proc.stdout }).on('line', line => this.onLine(line));
      await this.request('initialize', { clientInfo: { name: 'gpt-live', title: 'GPT Live', version: '1.1.0' },
        capabilities: { experimentalApi: true } }, 20000);
      this.write({ method: 'initialized' });
    })();
    this.ready.catch(() => { this.ready = null; });
    return this.ready;
  }
  fail(error) {
    for (const { reject } of this.pending.values()) reject(error);
    this.pending.clear(); this.loaded.clear();
    this.ready = null; this.proc = null;
    this.emit('exit', error);
  }
  write(message) {
    if (!this.proc?.stdin.writable) throw new AppError(503, 'Codex app-server недоступен.', 'codex_unavailable');
    this.proc.stdin.write(`${JSON.stringify(message)}\n`);
  }
  request(method, params, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new AppError(504, `Codex не ответил на ${method}.`, 'codex_timeout')); }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve: v => { clearTimeout(timer); resolve(v); }, reject: e => { clearTimeout(timer); reject(e); } });
      try { this.write({ id, method, params }); } catch (error) { this.pending.get(id)?.reject(error); this.pending.delete(id); }
    });
  }
  async call(method, params, timeoutMs) {
    await this.start();
    return this.request(method, params, timeoutMs);
  }
  onLine(line) {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.id != null && !message.method) {
      const waiter = this.pending.get(message.id);
      if (!waiter) return;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new AppError(502, `Codex: ${message.error.message || 'ошибка'}`, 'codex_error'));
      else waiter.resolve(message.result ?? {});
      return;
    }
    if (message.id != null && message.method) {
      // Voice sessions run with approvalPolicy "never"; anything interactive is refused.
      this.write({ id: message.id, error: { code: -32601, message: 'Not supported by GPT Live bridge' } });
      return;
    }
    if (message.method) this.emit('notification', message);
  }
  /** Ensures a persisted thread is loaded in this app-server process. */
  async ensureThread(threadId, settings) {
    if (threadId && this.loaded.has(threadId)) return threadId;
    if (threadId) {
      try { await this.call('thread/resume', { threadId, ...settings }); this.loaded.add(threadId); return threadId; }
      catch { /* thread missing or not resumable: start a fresh one */ }
    }
    const started = await this.call('thread/start', settings);
    const id = started.thread?.id;
    if (!id) throw new AppError(502, 'Codex не создал тред.', 'codex_error');
    this.loaded.add(id);
    return id;
  }
  stop() {
    const proc = this.proc;
    this.proc = null; this.ready = null;
    if (proc) { try { proc.stdin.end(); proc.kill('SIGTERM'); } catch { /* already gone */ } }
  }
}

/** Waits for the first notification matching `match`, or rejects on timeout/abort match. */
export function waitFor(emitter, match, timeoutMs, failMatch) {
  return new Promise((resolve, reject) => {
    const onNote = note => {
      const failure = failMatch?.(note);
      if (failure) { cleanup(); reject(failure); return; }
      if (match(note)) { cleanup(); resolve(note); }
    };
    const onExit = error => { cleanup(); reject(error); };
    const timer = setTimeout(() => { cleanup(); reject(new AppError(504, 'Codex не ответил вовремя.', 'codex_timeout')); }, timeoutMs);
    timer.unref?.();
    const cleanup = () => { clearTimeout(timer); emitter.off('notification', onNote); emitter.off('exit', onExit); };
    emitter.on('notification', onNote); emitter.on('exit', onExit);
  });
}

/** Extracts the spoken task from Codex's `<realtime_delegation><input>…</input>` user item. */
export function delegationInput(text) {
  const match = /<input>([\s\S]*?)<\/input>/.exec(text || '');
  return (match ? match[1] : text || '').trim();
}
