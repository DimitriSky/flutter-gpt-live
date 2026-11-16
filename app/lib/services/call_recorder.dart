import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A finished recording on disk (stereo WAV: left = you, right = assistant).
class Recording {
  const Recording(this.path, this.modified, this.bytes);
  final String path;
  final DateTime modified;
  final int bytes;
  String get name => path.split('/').last.replaceAll('.wav', '');
  String? get transcriptPath {
    final txt = path.replaceAll(RegExp(r'\.wav$'), '.txt');
    return File(txt).existsSync() ? txt : null;
  }

  /// 48 kHz, 16-bit, 2 channels after a 44-byte header.
  Duration get duration =>
      Duration(milliseconds: ((bytes - 44).clamp(0, 1 << 62) / 192).round());
}

/// Native call recorder (#REC). macOS only for now: the Runner taps the
/// WebRTC microphone and assistant tracks and writes a stereo WAV.
class CallRecorder {
  CallRecorder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('gpt_live/recorder');
  final MethodChannel _channel;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<String?> directory() => _channel.invokeMethod<String>('directory');

  Future<Map<String, dynamic>> start({
    required String path,
    required String? localTrackId,
    required String? remoteTrackId,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMethod<Map>('start', {
          'path': path,
          'localTrackId': localTrackId,
          'remoteTrackId': remoteTrackId,
        }) ??
        {},
  );

  Future<void> attach({String? localTrackId, String? remoteTrackId}) =>
      _channel.invokeMethod('attach', {
        'localTrackId': localTrackId,
        'remoteTrackId': remoteTrackId,
      });

  Future<void> setMuted(bool muted) =>
      _channel.invokeMethod('mute', {'muted': muted});

  Future<Map<String, dynamic>?> stop() async {
    final result = await _channel.invokeMethod<Map>('stop');
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<void> reveal(String path) =>
      _channel.invokeMethod('reveal', {'path': path});
  Future<void> open(String path) =>
      _channel.invokeMethod('open', {'path': path});

  Future<List<Recording>> list() async {
    final dir = await directory();
    if (dir == null) return [];
    final folder = Directory(dir);
    if (!folder.existsSync()) return [];
    final items = <Recording>[];
    for (final entity in folder.listSync()) {
      if (entity is File && entity.path.endsWith('.wav')) {
        final stat = entity.statSync();
        items.add(Recording(entity.path, stat.modified, stat.size));
      }
    }
    items.sort((a, b) => b.modified.compareTo(a.modified));
    return items;
  }
}
