import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gpt_live/services/backend_api.dart';
import 'package:flutter_gpt_live/services/live_service.dart';

// Real macOS check for #REC: records a live CLI call and verifies that the
// assistant channel (right) contains audio. Needs the backend running:
// flutter test integration_test/recording_test.dart -d macos \
//   --dart-define-from-file=../artifacts/macos-defines.json
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('records a real CLI call into a stereo WAV', (tester) async {
    final api = BackendApi(await SharedPreferences.getInstance());
    await api.configure(
      const String.fromEnvironment('BACKEND_URL'),
      const String.fromEnvironment('DEV_CLIENT_TOKEN'),
    );
    await api.setMode('cli');
    final live = LiveService(api);
    await live.start();
    for (var i = 0; i < 60 && live.status != LiveStatus.connected; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(live.status, LiveStatus.connected, reason: live.error ?? 'not connected');
    await live.startRecording();
    expect(live.recording, isTrue, reason: live.recordingError);
    // Re-saving the instructions pushes them to the voice, which answers aloud.
    final knowledge = await api.knowledge();
    await api.saveRules(knowledge['rules'] as String);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await live.stopRecording();
    await live.end();
    final path = live.lastRecording!;
    final bytes = File(path).readAsBytesSync();
    final pcm = ByteData.sublistView(bytes, 44);
    double left = 0, right = 0;
    final frames = pcm.lengthInBytes ~/ 4;
    for (var i = 0; i < frames; i++) {
      final l = pcm.getInt16(i * 4, Endian.little).toDouble();
      final r = pcm.getInt16(i * 4 + 2, Endian.little).toDouble();
      left += l * l;
      right += r * r;
    }
    final rmsL = math.sqrt(left / frames), rmsR = math.sqrt(right / frames);
    // ignore: avoid_print
    print('REC_RESULT path=$path seconds=${frames / 48000} rmsMic=${rmsL.toStringAsFixed(1)} rmsAssistant=${rmsR.toStringAsFixed(1)} transcript=${live.assistantTranscript.length}');
    expect(frames / 48000, greaterThan(10));
    expect(rmsR, greaterThan(30), reason: 'assistant channel should contain speech');
    expect(rmsL, greaterThan(0), reason: 'microphone channel should not be digital silence');
  });
}
