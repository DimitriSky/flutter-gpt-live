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

  bool? _shownMuted;

  /// Actions from the notification: "End" and "Mute/Unmute".
  void setHandlers({VoidCallback? onEnd, VoidCallback? onToggleMute}) {
    _channel.setMethodCallHandler(
      onEnd == null && onToggleMute == null
          ? null
          : (call) async {
              if (call.method == 'endCall') onEnd?.call();
              if (call.method == 'toggleMute') onToggleMute?.call();
            },
    );
  }

  /// Keeps the notification's mute button in sync with the app (#ANDROID-MUTE).
  Future<void> setMuted(bool muted) async {
    if (!supported || !running || _shownMuted == muted) return;
    _shownMuted = muted;
    try {
      await _channel.invokeMethod('update', {'muted': muted});
    } catch (_) {}
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
      _shownMuted = false;
    } catch (_) {
      running = false;
    }
  }

  Future<void> stop() async {
    if (!supported || !running) return;
    running = false;
    _shownMuted = null;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
