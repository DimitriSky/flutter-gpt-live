class BackgroundTask {
  const BackgroundTask({
    required this.id,
    required this.conversationId,
    required this.title,
    required this.description,
    required this.status,
    this.result,
    this.error,
    this.mode = 'api',
    this.delivered = false,
    this.acknowledged = false,
  });
  final String id, conversationId, title, description, status;
  final String? result, error;

  /// 'cli' for work done by a Codex thread, 'api' for the Responses worker.
  final String mode;

  /// True when the result was already spoken during the call (no callback).
  final bool delivered;

  /// #SINGLE-USER: answered or postponed on any device; no more calls.
  final bool acknowledged;
  bool get completed => status == 'Completed';
  bool get terminal => completed || status == 'Failed';
  factory BackgroundTask.fromJson(Map<String, dynamic> json) => BackgroundTask(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    status: json['status'] as String,
    result: json['result'] as String?,
    error: json['error'] as String?,
    mode: json['mode'] as String? ?? 'api',
    delivered: json['delivered'] == true,
    acknowledged: json['acknowledged'] == true,
  );
}
