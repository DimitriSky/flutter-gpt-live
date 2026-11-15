import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'backend_api.dart';

class TaskEventsService {
  TaskEventsService(this.api);
  final BackendApi api;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;
  WebSocket? _socket;
  Timer? _retry;
  bool _enabled = false;
  int _generation = 0, _attempt = 0;
  void start() {
    if (_enabled || !api.configured) return;
    _enabled = true;
    unawaited(_connect(++_generation));
  }

  Future<void> _connect(int generation) async {
    try {
      final socket = await WebSocket.connect(
        api.eventsUri.toString(),
        headers: api.headers,
      ).timeout(const Duration(seconds: 10));
      if (!_enabled || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 10);
      _attempt = 0;
      _events.add({'type': 'socket.connected'});
      socket.listen(
        (data) {
          if (generation != _generation) return;
          try {
            _events.add(jsonDecode(data as String) as Map<String, dynamic>);
          } catch (_) {}
        },
        onError: (_) => _lost(generation),
        onDone: () => _lost(generation),
        cancelOnError: true,
      );
    } catch (_) {
      _lost(generation);
    }
  }

  void _lost(int generation) {
    if (!_enabled || generation != _generation || _retry?.isActive == true) {
      return;
    }
    _socket?.close();
    _socket = null;
    _events.add({'type': 'socket.disconnected'});
    final seconds = (1 << _attempt.clamp(0, 4)).clamp(1, 15);
    _attempt++;
    _retry = Timer(Duration(seconds: seconds), () {
      _retry = null;
      unawaited(_connect(++_generation));
    });
  }

  void stop() {
    _enabled = false;
    _generation++;
    _retry?.cancel();
    _retry = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    stop();
    await _events.close();
  }
}
