import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// #ANDROID-BG: an Android foreground service (type "microphone") that keeps
/// a call running while the app is in the background, with an ongoing
/// notification and an "End" action. No-op on other platforms.
class CallKeepAlive {
  CallKeepAlive({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('gpt_live/call_service');
  final MethodChannel _channel;
  bool running = false;
  bool _askedNotifications = false;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Called when the user taps "End" in the notification.
  set onEndRequested(VoidCallback? callback) {
    _channel.setMethodCallHandler(
      callback == null
          ? null
          : (call) async {
              if (call.method == 'endCall') callback();
            },
    );
  }

  Future<void> start({required String title, required String text}) async {
    if (!supported || running) return;
    running = true;
    if (!_askedNotifications) {
      // Android 13+: without it the service still runs, the notification is hidden.
      _askedNotifications = true;
      try {
        await Permission.notification.request();
      } catch (_) {}
    }
    try {
      await _channel.invokeMethod('start', {'title': title, 'text': text});
    } catch (_) {
      running = false;
    }
  }

  Future<void> stop() async {
    if (!supported || !running) return;
    running = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
