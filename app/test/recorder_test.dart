import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/main.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';
import 'package:flutter_gpt_live/services/call_recorder.dart';
import 'package:flutter_gpt_live/services/live_service.dart';

// #MIC-MUTE / #REC (macOS only)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gpt_live/recorder');
  late Directory dir;
  final calls = <MethodCall>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gpt-live-rec-');
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'directory':
              return dir.path;
            case 'start':
              return {'micAttached': true, 'assistantAttached': true};
            case 'stop':
              final path = '${dir.path}/fake.wav';
              File(path).writeAsBytesSync(List.filled(44 + 192000, 0));
              return {'path': path, 'seconds': 1.0};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('recording is macOS only', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(CallRecorder.supported, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(CallRecorder.supported, isTrue);
  });

  test('a recording saves the WAV and a role-labelled transcript', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
    final live = LiveService(BackendApi(await SharedPreferences.getInstance()));
    live.status = LiveStatus.connected;
    await live.startRecording();
    expect(live.recording, isTrue);
    final start = calls.firstWhere((c) => c.method == 'start');
    expect(
      (start.arguments as Map)['path'],
      startsWith('${dir.path}/GPT Live '),
    );
    live.addTranscript('user', 'Привет');
    live.addTranscript('assistant', 'Здравствуй');
    live.addTranscript('assistant', '!');
    await live.stopRecording();
    expect(live.recording, isFalse);
    expect(live.lastRecording, '${dir.path}/fake.wav');
    final txt = dir.listSync().whereType<File>().firstWhere(
      (f) => f.path.endsWith('.txt'),
    );
    expect(txt.readAsStringSync(), 'Вы: Привет\n\nАссистент: Здравствуй!\n');
    final recordings = await live.recorder.list();
    expect(recordings.single.duration, const Duration(seconds: 1));
  });

  test('recording needs a connected call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
    final live = LiveService(BackendApi(await SharedPreferences.getInstance()));
    await live.startRecording();
    expect(live.recording, isFalse);
    expect(calls, isEmpty);
  });

  test('mute flag survives without tracks and resets on a new call', () async {
    SharedPreferences.setMockInitialValues({});
    final live = LiveService(BackendApi(await SharedPreferences.getInstance()));
    live.setMicMuted(true);
    expect(live.micMuted, isTrue);
    expect(live.inputLevel, 0);
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets(
      'mic and record controls are ${platform == TargetPlatform.macOS ? 'shown on macOS' : 'hidden on Android'}',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.physicalSize = const Size(450, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          VoiceApp(api: BackendApi(await SharedPreferences.getInstance())),
        );
        await tester.pump();
        final expected = platform == TargetPlatform.macOS
            ? findsOneWidget
            : findsNothing;
        expect(find.text('МИКРОФОН'), expected);
        expect(find.text('ЗАПИСЬ'), expected);
        expect(find.text('ЗАПИСИ'), expected);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
