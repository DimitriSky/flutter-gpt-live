import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';
import 'package:flutter_gpt_live/services/live_service.dart';
import 'package:flutter_gpt_live/services/task_events_service.dart';
import 'package:flutter_gpt_live/voice_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  voiceSwitchTests();
  cliModeTests();
  knowledgeEditTests();
  test(
    'voice and session limit persist and are sent with a new session',
    () async {
      SharedPreferences.setMockInitialValues({
        'backend_token': 'a-trusted-test-token-longer-than-24',
      });
      Map<String, dynamic>? sent;
      final api = BackendApi(
        await SharedPreferences.getInstance(),
        client: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'session': {'id': 'live_1'},
              'transport': {'sdp': 'answer'},
            }),
            201,
          );
        }),
      );
      expect(api.mode, 'cli', reason: 'CLI is the default mode');
      await api.setMode('api');
      expect(api.voice, 'marin');
      expect(api.sessionMinutes, 5);
      await api.setVoice('cedar');
      await api.setSessionMinutes(99);
      expect(api.sessionMinutes, BackendApi.maxSessionMinutes);
      await api.setSessionMinutes(0);
      expect(api.sessionMinutes, BackendApi.minSessionMinutes);
      await api.setSessionMinutes(7);
      await api.createSession('offer');
      expect(sent!['voice'], 'cedar');
      expect(sent!['max_seconds'], 420);
    },
  );

  test(
    'cost estimate uses the larger of local and server seconds plus backend',
    () async {
      SharedPreferences.setMockInitialValues({});
      final live = LiveService(
        BackendApi(await SharedPreferences.getInstance()),
      );
      live.pricePerMinute = 0.05;
      live.sessionSeconds = 60;
      live.elapsedSeconds = 60;
      live.serverSeconds = 120;
      live.backendUsd = 0.01;
      expect(live.costUsd, closeTo(0.11, 1e-9));
      live.limitSeconds = 300;
      expect(live.remainingSeconds, 240);
    },
  );
}

class _SwitchLive extends LiveService {
  _SwitchLive(super.api);
  int switches = 0;
  @override
  Future<void> switchVoice() async => switches++;
}

class _QuietEvents extends TaskEventsService {
  _QuietEvents(super.api);
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  void start() {}
  @override
  void stop() {}
  @override
  Future<void> dispose() async {}
}

void voiceSwitchTests() {
  test(
    'picking a new voice mid-call swaps the session; same voice does not',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = BackendApi(await SharedPreferences.getInstance());
      final live = _SwitchLive(api);
      final controller = VoiceController(
        api,
        liveService: live,
        eventService: _QuietEvents(api),
      );
      addTearDown(controller.dispose);
      await controller.setVoice('ash');
      expect(live.switches, 0, reason: 'not in a call');
      live.status = LiveStatus.connected;
      await controller.setVoice('cedar');
      expect(api.voice, 'cedar');
      expect(live.switches, 1);
      await controller.setVoice('cedar');
      expect(live.switches, 1);
    },
  );
}

void cliModeTests() {
  test('CLI mode sends its own voice; API voice is kept separately', () async {
    SharedPreferences.setMockInitialValues({
      'backend_token': 'a-trusted-test-token-longer-than-24',
    });
    Map<String, dynamic>? sent;
    final api = BackendApi(
      await SharedPreferences.getInstance(),
      client: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          '{"session":{"id":"cli_1","mode":"cli"},"transport":{"sdp":"a"}}',
          201,
        );
      }),
    );
    expect(api.mode, 'cli');
    await api.setMode('api');
    expect(api.mode, 'api', reason: 'an explicit API choice is remembered');
    await api.setMode('cli');
    await api.setVoiceFor('cli', 'sol');
    expect(api.voice, 'marin', reason: 'API voice untouched');
    await api.createSession('offer');
    expect(sent!['mode'], 'cli');
    expect(sent!['voice'], 'sol');
    await api.createSession('offer', mode: 'api');
    expect(sent!['voice'], 'marin');
  });

  test(
    'results already spoken during the call never ring; relayed captions show',
    () async {
      SharedPreferences.setMockInitialValues({
        'backend_token': 'a-trusted-test-token-longer-than-24',
      });
      final api = BackendApi(
        await SharedPreferences.getInstance(),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'tasks': [
                {
                  'id': 'spoken',
                  'conversation_id': 'c',
                  'title': 'a',
                  'description': 'a',
                  'status': 'Completed',
                  'mode': 'cli',
                  'delivered': true,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final live = _SwitchLive(api);
      final events = _StreamEvents(api);
      final controller = VoiceController(
        api,
        liveService: live,
        eventService: events,
      );
      addTearDown(controller.dispose);
      await controller.sync();
      expect(controller.incoming, isNull);
      expect(controller.tasks.single.mode, 'cli');
      live.sessionId = 'cli_1';
      events.stream.add({
        'type': 'live.transcript',
        'session_id': 'cli_1',
        'role': 'assistant',
        'delta': 'Готово',
      });
      await Future<void>.delayed(Duration.zero);
      expect(live.assistantTranscript, 'Готово');
    },
  );
}

class _StreamEvents extends TaskEventsService {
  _StreamEvents(super.api);
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  Future<void> dispose() => stream.close();
}

void knowledgeEditTests() {
  test(
    'knowledge base edits are posted to /knowledge/data (#KB-EDIT)',
    () async {
      SharedPreferences.setMockInitialValues({
        'backend_token': 'a-trusted-test-token-longer-than-24',
      });
      late http.Request seen;
      final api = BackendApi(
        await SharedPreferences.getInstance(),
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({'data': 'Проект Beta', 'applied_sessions': 1}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await api.saveData('Проект Beta');
      expect(seen.url.path, '/knowledge/data');
      expect(jsonDecode(seen.body), {'data': 'Проект Beta'});
      expect(result['applied_sessions'], 1);
    },
  );
}
