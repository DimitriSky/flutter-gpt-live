import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/app_theme.dart';
import 'package:flutter_gpt_live/screens/voice_screen.dart';
import 'package:flutter_gpt_live/services/task_events_service.dart';
import 'package:flutter_gpt_live/voice_controller.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';

void main() {
  testWidgets('the journal lists only the 10 newest tasks', (tester) async {
    tester.view.physicalSize = const Size(450, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'backend_token': 'a-trusted-test-token-longer-than-24',
      'handled_tasks': [for (var i = 1; i <= 23; i++) 't$i'],
    });
    final tasks = [
      for (var i = 1; i <= 23; i++)
        {
          'id': 't$i',
          'conversation_id': 'c',
          'title': 'Задача $i',
          'description': 'd',
          'status': 'Completed',
        },
    ];
    final api = BackendApi(
      await SharedPreferences.getInstance(),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'tasks': tasks}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final controller = VoiceController(api, eventService: _QuietEvents(api));
    await tester.pumpWidget(
      MaterialApp(
        theme: ConsoleTheme.light,
        home: VoiceScreen(api: api, controller: controller),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('10 ИЗ 23'), findsOneWidget);
    expect(find.text('Задача 23'), findsOneWidget, reason: 'newest shown');
    expect(find.text('Задача 14'), findsOneWidget);
    expect(find.text('Задача 13'), findsNothing, reason: 'older ones hidden');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
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
