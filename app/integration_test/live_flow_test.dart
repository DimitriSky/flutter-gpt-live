import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/screens/voice_screen.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';
import 'package:flutter_gpt_live/services/live_service.dart';
import 'package:flutter_gpt_live/voice_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Real OpenAI: close voice, finish task, Later, Answer with saved result',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      final api = BackendApi(preferences);
      if (!api.configured) {
        fail('Pass DEV_CLIENT_TOKEN with --dart-define-from-file');
      }
      final controller = VoiceController(api);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: VoiceScreen(api: api, controller: controller),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await controller.start();
      await tester.pump();
      expect(controller.live.error, isNull);
      expect(controller.live.status, LiveStatus.connected);
      final firstSession = controller.live.sessionId;
      expect(firstSession, isNotNull);
      final accepted = await controller.submit(
        'Составь краткий структурированный отчёт по моей базе знаний. Назови проект, назначение и известный стек. Не придумывай сведений.',
      );
      expect(accepted, isTrue);
      await controller.live.end();
      await tester.pump();
      expect(controller.live.finalized, isTrue);
      expect(controller.live.sessionId, isNull);
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (controller.incoming == null && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.tasks.any((t) => t.status == 'Failed')) {
          fail(controller.tasks.first.error!);
        }
      }
      expect(controller.incoming, isNotNull);
      expect(find.text('Результат готов'), findsOneWidget);
      final task = controller.incoming!;
      final report = await api.task(task.id);
      expect(report.result, contains('Project Alpha'));
      await tester.tap(find.text('Позже'));
      await tester.pump();
      expect(controller.incoming, isNull);
      expect(controller.live.sessionId, isNull);
      expect(controller.live.status, LiveStatus.disconnected);
      await controller.answer(task);
      await tester.pump();
      expect(controller.live.error, isNull);
      expect(controller.live.status, LiveStatus.connected);
      expect(controller.live.sessionId, isNot(firstSession));
      final speechDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (controller.live.assistantTranscript.isEmpty &&
          DateTime.now().isBefore(speechDeadline)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        controller.live.assistantTranscript,
        isNotEmpty,
        reason: 'Result callback must produce actual assistant speech captions',
      );
      await controller.live.end();
      await tester.pump();
      expect(controller.live.finalized, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
