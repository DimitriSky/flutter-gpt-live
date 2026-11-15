import { AppError } from './errors.js';
import { agentInstructions } from './config.js';

export class OpenAIAPI {
  constructor(config, fetcher = fetch) { this.config = config; this.fetcher = fetcher; }
  async post(path, body, signal = AbortSignal.timeout(45000)) {
    if (!this.config.apiKey) throw new AppError(503, 'На сервере не настроен OPENAI_API_KEY.', 'missing_api_key');
    const response = await this.fetcher(`https://api.openai.com/v1${path}`, {
      method: 'POST', headers: { Authorization: `Bearer ${this.config.apiKey}`, 'Content-Type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal,
    });
    if (!response.ok) {
      const requestId = response.headers.get('x-request-id');
      let detail;
      try { detail = (await response.json()).error; } catch { /* non-JSON upstream failure */ }
      console.error(JSON.stringify({ type: 'openai.error', status: response.status, request_id: requestId, code: detail?.code, param: detail?.param }));
      throw new AppError(502, `OpenAI отклонил запрос (HTTP ${response.status}). Проверьте доступ к модели и лимиты проекта.`, 'upstream_error');
    }
    if (response.status === 204 || response.headers.get('content-length') === '0') return {};
    const text = await response.text();
    return text ? JSON.parse(text) : {};
  }
  async runTask(task, signal) {
    const response = await this.post('/responses', {
      model: this.config.textModel, instructions: agentInstructions(task.snapshot),
      input: [...task.snapshot.history, { role: 'user', content: task.description }],
      max_output_tokens: this.config.maxOutputTokens, store: false,
    }, signal);
    const result = response.output?.flatMap(item => item.content || []).filter(c => c.type === 'output_text').map(c => c.text).join('\n') || '';
    if (response.status !== 'completed' || !result.trim()) {
      const error = new AppError(502, 'Модель не завершила отчёт. Проверьте лимит output tokens.', 'incomplete_response');
      error.responseId = response.id; error.usage = response.usage; throw error;
    }
    return { result, response_id: response.id, usage: response.usage };
  }
}
