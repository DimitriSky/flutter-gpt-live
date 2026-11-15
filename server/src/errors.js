export class AppError extends Error {
  constructor(status, message, code = 'request_failed') { super(message); this.status = status; this.code = code; }
}
export function requireText(value, name, max = 12000) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) {
    throw new AppError(400, `Поле ${name}: требуется текст до ${max} символов.`, 'invalid_input');
  }
  return value.trim();
}
export function requireId(value, name = 'id') {
  const id = requireText(value, name, 160);
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new AppError(400, `Некорректное поле ${name}.`);
  return id;
}
