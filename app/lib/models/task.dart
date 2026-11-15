class BackgroundTask {
  const BackgroundTask({
    required this.id,
    required this.conversationId,
    required this.title,
    required this.description,
    required this.status,
    this.result,
    this.error,
  });
  final String id, conversationId, title, description, status;
  final String? result, error;
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
  );
}
