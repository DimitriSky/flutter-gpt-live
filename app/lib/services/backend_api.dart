import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/task.dart';

class BackendException implements Exception {
  BackendException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackendApi {
  BackendApi(this.preferences, {http.Client? client})
    : _client = client ?? http.Client() {
    baseUrl =
        preferences.getString('backend_url') ??
        (const String.fromEnvironment('BACKEND_URL').isNotEmpty
            ? const String.fromEnvironment('BACKEND_URL')
            : defaultTargetPlatform == TargetPlatform.macOS
            ? 'http://127.0.0.1:8789'
            : 'http://10.0.2.2:8789');
    token =
        preferences.getString('backend_token') ??
        const String.fromEnvironment('DEV_CLIENT_TOKEN');
    clientId = preferences.getString('client_id') ?? const Uuid().v4();
    conversationId =
        preferences.getString('conversation_id') ?? const Uuid().v4();
  }
  static const defaultVoice = 'marin', defaultCliVoice = 'cove';
  static const minSessionMinutes = 1, maxSessionMinutes = 30;
  final SharedPreferences preferences;

  /// 'api' — GPT-Live over the OpenAI API key; 'cli' — Codex app-server on
  /// the backend machine with the ChatGPT subscription.
  String get mode =>
      preferences.getString('voice_mode') == 'cli' ? 'cli' : 'api';
  Future<void> setMode(String value) =>
      preferences.setString('voice_mode', value == 'cli' ? 'cli' : 'api');
  String get voice => preferences.getString('voice') ?? defaultVoice;
  String get cliVoice => preferences.getString('cli_voice') ?? defaultCliVoice;
  String voiceFor(String mode) => mode == 'cli' ? cliVoice : voice;
  Future<void> setVoice(String value) => preferences.setString('voice', value);
  Future<void> setVoiceFor(String mode, String value) => mode == 'cli'
      ? preferences.setString('cli_voice', value)
      : setVoice(value);
  int get sessionMinutes => (preferences.getInt('max_session_minutes') ?? 5)
      .clamp(minSessionMinutes, maxSessionMinutes);
  Future<void> setSessionMinutes(int value) => preferences.setInt(
    'max_session_minutes',
    value.clamp(minSessionMinutes, maxSessionMinutes),
  );
  final http.Client _client;
  late String baseUrl, token, clientId, conversationId;
  bool get configured => token.isNotEmpty;
  Map<String, String> get headers => {
    'Authorization': 'Bearer $token',
    'X-Client-ID': clientId,
    'Content-Type': 'application/json',
  };
  Future<void> saveIdentity() async {
    await preferences.setString('client_id', clientId);
    await preferences.setString('conversation_id', conversationId);
  }

  Future<void> configure(String url, String newToken) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw BackendException(
        'Укажите адрес вида http://192.168.1.10:8789 без пути.',
      );
    }
    if (newToken.trim().length < 24) {
      throw BackendException(
        'Нужен DEV_CLIENT_TOKEN сервера (от 24 символов).',
      );
    }
    baseUrl = url.trim().replaceFirst(RegExp(r'/$'), '');
    token = newToken.trim();
    await preferences.setString('backend_url', baseUrl);
    await preferences.setString('backend_token', token);
  }

  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response =
          await (method == 'GET'
                  ? _client.get(uri, headers: headers)
                  : _client.post(
                      uri,
                      headers: headers,
                      body: jsonEncode(body ?? {}),
                    ))
              .timeout(Duration(seconds: path == '/live/session' ? 55 : 22));
      if (response.statusCode == 404 &&
          (path.startsWith('/knowledge') || path == '/usage')) {
        throw BackendException(
          'Backend устарел: перезапустите сервер с новой версией.',
        );
      }
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode >= 400) {
        throw BackendException(
          decoded['error']?.toString() ??
              'Ошибка backend: ${response.statusCode}',
        );
      }
      return decoded;
    } on BackendException {
      rethrow;
    } catch (_) {
      throw BackendException(
        'Нет ответа от backend. Проверьте IP, Wi-Fi, токен и запущен ли сервер.',
      );
    }
  }

  Future<List<BackgroundTask>> tasks() async {
    final json = await request('GET', '/tasks');
    return (json['tasks'] as List)
        .map((j) => BackgroundTask.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<BackgroundTask> task(String id) async => BackgroundTask.fromJson(
    await request('GET', '/tasks/$id') as Map<String, dynamic>,
  );
  Future<BackgroundTask> createTask(String description, String key) async =>
      BackgroundTask.fromJson(
        await request('POST', '/tasks', {
              'conversation_id': conversationId,
              'description': description,
              'title': description.length > 70
                  ? description.substring(0, 70)
                  : description,
              'idempotency_key': key,
            })
            as Map<String, dynamic>,
      );
  Future<Map<String, dynamic>> createSession(
    String sdp, {
    String? taskId,
    String? replaces,
    int? maxSeconds,
    String? mode,
  }) async =>
      await request('POST', '/live/session', {
            'sdp': sdp,
            'conversation_id': conversationId,
            'mode': mode ?? this.mode,
            'voice': voiceFor(mode ?? this.mode),
            'max_seconds': maxSeconds ?? sessionMinutes * 60,
            'replaces': ?replaces,
            'task_id': ?taskId,
          })
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> closeSession(String id) async =>
      await request('POST', '/live/$id/close') as Map<String, dynamic>;
  Future<Map<String, dynamic>> heartbeat(String id) async =>
      await request('POST', '/live/$id/heartbeat') as Map<String, dynamic>;
  Future<Map<String, dynamic>> knowledge() async =>
      await request('GET', '/knowledge') as Map<String, dynamic>;
  Future<Map<String, dynamic>> saveData(String data) async =>
      await request('POST', '/knowledge/data', {'data': data})
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> saveRules(String rules) async =>
      await request('POST', '/knowledge/rules', {'rules': rules})
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> usage() async =>
      await request('GET', '/usage') as Map<String, dynamic>;

  Uri get eventsUri => Uri.parse(
    '$baseUrl/events',
  ).replace(scheme: baseUrl.startsWith('https:') ? 'wss' : 'ws');
  void dispose() => _client.close();
}
