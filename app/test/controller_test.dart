import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';
import 'package:flutter_gpt_live/services/live_service.dart';
import 'package:flutter_gpt_live/services/task_events_service.dart';
import 'package:flutter_gpt_live/voice_controller.dart';

class FakeLive extends LiveService {
  FakeLive(super.api);
  int starts = 0, ends = 0;
  String? answeredTask;
  @override
  Future<void> start({String? taskId, String? mode}) async {
    starts++;
    answeredTask = taskId;
    status = LiveStatus.connected;
  }

  @override
  Future<void> end({bool keepError = false}) async {
    ends++;
    status = LiveStatus.disconnected;
  }
}

class FakeEvents extends TaskEventsService {
  FakeEvents(super.api);
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

const completed = {
  'id': 'task_1',
  'conversation_id': 'conversation_1',
  'title': 'Отчёт',
  'description': 'Отчёт по базе',
  'status': 'Completed',
  'result': 'Project Alpha',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'backend_token': 'a-trusted-test-token-longer-than-24',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  Future<(VoiceController, FakeLive, FakeEvents)> make() async {
    final api = BackendApi(
      await SharedPreferences.getInstance(),
      client: MockClient((request) async {
        return http.Response(
          jsonEncode(
            request.url.path == '/tasks'
                ? {
                    'tasks': [completed],
                  }
                : completed,
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final live = FakeLive(api);
    final events = FakeEvents(api);
    final controller = VoiceController(
      api,
      liveService: live,
      eventService: events,
    );
    addTearDown(controller.dispose);
    return (controller, live, events);
  }

  test(
    'HTTP sync offers missed callback without opening microphone; Later persists',
    () async {
      final (controller, live, _) = await make();
      await controller.sync();
      expect(controller.incoming?.id, 'task_1');
      expect(live.starts, 0);
      await controller.later();
      await controller.sync();
      expect(controller.incoming, isNull);
      expect(live.starts, 0);
      expect(
        controller.api.preferences.getStringList('handled_tasks'),
        contains('task_1'),
      );
    },
  );
  test(
    'Answer fetches exact saved task and explicitly starts a new voice session',
    () async {
      final (controller, live, _) = await make();
      await controller.sync();
      await controller.answer(controller.incoming!);
      expect(live.starts, 1);
      expect(live.answeredTask, 'task_1');
      expect(controller.api.conversationId, 'conversation_1');
    },
  );
  test(
    'reconnecting event socket triggers authoritative HTTP synchronization',
    () async {
      final (controller, live, events) = await make();
      events.stream.add({'type': 'socket.connected'});
      await Future<void>.delayed(Duration.zero);
      expect(controller.eventsConnected, isTrue);
      expect(controller.incoming?.id, 'task_1');
      expect(live.starts, 0);
      events.stream.add({
        'type': 'task.running',
        'task': {...completed, 'status': 'Running'},
      });
      expect(controller.tasks.first.status, 'Completed');
    },
  );
  test('retry after failed submission reuses idempotency key', () async {
    final sent = <Map<String, dynamic>>[];
    final api = BackendApi(
      await SharedPreferences.getInstance(),
      client: MockClient((request) async {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return sent.length == 1
            ? http.Response('{"error":"temporary"}', 503)
            : http.Response(
                jsonEncode(completed),
                201,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
      }),
    );
    final controller = VoiceController(
      api,
      liveService: FakeLive(api),
      eventService: FakeEvents(api),
    );
    addTearDown(controller.dispose);
    expect(await controller.submit('Подготовь отчёт'), isFalse);
    expect(await controller.submit('Подготовь отчёт'), isTrue);
    expect(sent[0]['idempotency_key'], sent[1]['idempotency_key']);
  });

  // #DESKTOP-KEEPALIVE
  test(
    'macOS: switching apps keeps the call and callbacks; quitting ends it',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final (controller, live, _) = await make();
      await live.start();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        controller.didChangeAppLifecycleState(state);
      }
      expect(live.ends, 0);
      expect(live.status, LiveStatus.connected);
      expect(controller.active, isTrue, reason: 'incoming calls still show');
      await controller.sync();
      expect(controller.incoming?.id, 'task_1');
      controller.didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(live.ends, 1);
    },
  );

  test('Android: backgrounding still ends the call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final (controller, live, _) = await make();
    await live.start();
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(live.ends, 1);
    expect(controller.active, isFalse);
  });
}
