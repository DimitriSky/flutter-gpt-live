import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/main.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';

void main() {
  testWidgets(
    'No configuration does not activate microphone and shows connection fields',
    (tester) async {
      tester.view.physicalSize = const Size(450, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final api = BackendApi(await SharedPreferences.getInstance());
      await tester.pumpWidget(VoiceApp(api: api));
      await tester.pump();
      expect(find.text('GPT Live'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('DEV_CLIENT_TOKEN'), findsOneWidget);
      expect(find.text('База знаний'), findsOneWidget);
      expect(find.text('Инструкции'), findsOneWidget);
      expect(
        find.text('Cove'),
        findsOneWidget,
        reason: 'CLI is the default mode',
      );
      expect(find.text('5 мин'), findsWidgets);
      expect(
        find.text('ПОДПИСКА'),
        findsOneWidget,
        reason: 'CLI shows subscription, not \$',
      );
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start Conversation'),
      );
      expect(start.onPressed, isNotNull);
      await tester.ensureVisible(find.text('Start Conversation'));
      await tester.pump();
      await tester.tap(find.text('Start Conversation'));
      await tester.pump();
      expect(find.textContaining('Укажите адрес backend'), findsOneWidget);
      // Settings fold away and come back with an animation.
      await tester.ensureVisible(find.byTooltip('Подключение'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Подключение'));
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        find.text('DEV_CLIENT_TOKEN'),
        findsOneWidget,
        reason: 'still animating out',
      );
      await tester.pumpAndSettle();
      expect(find.text('DEV_CLIENT_TOKEN'), findsNothing);
      await tester.tap(find.byTooltip('Подключение'));
      await tester.pumpAndSettle();
      expect(find.text('DEV_CLIENT_TOKEN'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
