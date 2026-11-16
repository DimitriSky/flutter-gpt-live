import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'backend_api.dart';

enum LiveStatus { disconnected, connecting, connected, error }

class LiveService extends ChangeNotifier {
  LiveService(this.api);
  final BackendApi api;
  LiveStatus status = LiveStatus.disconnected;
  String? error, sessionId;
  String? _opening;
  String userTranscript = '', assistantTranscript = '';
  double inputLevel = 0, outputLevel = 0;
  // elapsedSeconds spans the whole conversation, including voice switches;
  // sessionSeconds covers only the current OpenAI session.
  int elapsedSeconds = 0, sessionSeconds = 0;
  // Cost estimate: voice billed per second + backend tokens reported by server.
  double pricePerMinute = 0.05, backendUsd = 0;
  int serverSeconds = 0, limitSeconds = 300;
  String? notice;

  /// 'api' (GPT-Live via API key) or 'cli' (Codex realtime via subscription).
  String mode = 'api';
  Map<String, dynamic>? rateLimits;
  bool get isCli => mode == 'cli';
  bool switching = false;
  int _carrySeconds = 0;
  double _carryUsd = 0;
  double get costUsd =>
      _carryUsd +
      math.max(sessionSeconds, serverSeconds) / 60 * pricePerMinute +
      backendUsd;
  int get remainingSeconds => math.max(0, limitSeconds - elapsedSeconds);
  bool closing = false, finalized = false;
  DateTime? _started;
  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  MediaStream? _microphone;
  final Set<MediaStream> _remoteStreams = {};
  Timer? _timer, _heartbeat;
  Completer<void>? _ready, _connecting;
  int _generation = 0;
  bool _disposed = false, _sampling = false;
  Future<void>? _endOperation;
  /// Desktop windows lose focus or get covered all the time; a call there
  /// must survive switching apps. Phones end the call when backgrounded.
  static bool get desktop => const {
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  }.contains(defaultTargetPlatform);
  bool get busy =>
      closing ||
      status == LiveStatus.connecting ||
      status == LiveStatus.connected;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({String? taskId, String? mode}) async {
    if (busy || _disposed) return;
    this.mode = mode ?? api.mode;
    _carrySeconds = 0;
    _carryUsd = 0;
    limitSeconds = api.sessionMinutes * 60;
    userTranscript = '';
    assistantTranscript = '';
    await _connect(taskId: taskId);
  }

  /// GPT-Live fixes the voice per session, so a mid-call switch replaces the
  /// session: the backend closes the old one and seeds the new one with the
  /// conversation history. Timer, cost and the time limit carry over.
  Future<void> switchVoice() async {
    if (status != LiveStatus.connected || closing || switching || _disposed) {
      return;
    }
    final old = sessionId;
    _carrySeconds = elapsedSeconds;
    _carryUsd = costUsd;
    switching = true;
    ++_generation;
    _heartbeat?.cancel();
    _timer?.cancel();
    sessionId = null;
    status = LiveStatus.connecting;
    _notify();
    await _release();
    if (closing || _disposed) {
      // The user ended the call mid-switch; nothing replaced the old session.
      switching = false;
      if (old != null) unawaited(_closeQuietly(old));
      return;
    }
    await _connect(replaces: old);
    switching = false;
    if (status == LiveStatus.error && old != null) {
      unawaited(_closeQuietly(old));
    }
    _notify();
  }

  Future<void> _closeQuietly(String id) async {
    try {
      await api.closeSession(id);
    } catch (_) {
      // The backend lease closes it anyway once heartbeats stop.
    }
  }

  Future<void> _connect({String? taskId, String? replaces}) async {
    final generation = ++_generation;
    _connecting = Completer<void>();
    status = LiveStatus.connecting;
    error = null;
    finalized = false;
    elapsedSeconds = _carrySeconds;
    sessionSeconds = 0;
    serverSeconds = 0;
    backendUsd = 0;
    notice = null;
    _notify();
    try {
      // On macOS getUserMedia requests native AVCaptureDevice permission.
      // permission_handler has no macOS implementation.
      if (defaultTargetPlatform != TargetPlatform.macOS) {
        final permission = await Permission.microphone.request();
        if (!permission.isGranted) {
          throw BackendException(
            'Разрешите доступ к микрофону в настройках системы.',
          );
        }
      }
      if (generation != _generation) return;
      _microphone = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      if (generation != _generation) return;
      final peer = await createPeerConnection({
        'iceServers': [],
        'sdpSemantics': 'unified-plan',
      });
      _peer = peer;
      _ready = Completer<void>();
      unawaited(_ready!.future.catchError((Object _) {}));
      peer.onTrack = (event) {
        _remoteStreams.addAll(event.streams);
      };
      peer.onConnectionState = (state) {
        if (generation != _generation || closing) return;
        // Codex realtime v3 does not promise GPT-Live's session.started on the
        // data channel; for CLI the media connection itself marks readiness.
        if (isCli &&
            state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _markStarted();
          _notify();
          return;
        }
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          unawaited(
            fail('Прервалось голосовое соединение. Начните новый разговор.'),
          );
        }
      };
      for (final track in _microphone!.getAudioTracks()) {
        await peer.addTrack(track, _microphone!);
      }
      _channel = await peer.createDataChannel(
        'oai-events',
        RTCDataChannelInit()..ordered = true,
      );
      _channel!.onMessage = (message) {
        if (generation != _generation || message.isBinary) return;
        try {
          _event(jsonDecode(message.text) as Map<String, dynamic>);
        } catch (_) {
          if (!isCli) unawaited(fail('Некорректное событие голосовой сессии.'));
        }
      };
      _channel!.onDataChannelState = (state) {
        if (generation == _generation &&
            !closing &&
            !finalized &&
            !isCli &&
            state == RTCDataChannelState.RTCDataChannelClosed) {
          unawaited(fail('Голосовой канал закрыт.'));
        }
      };
      final iceComplete = Completer<void>();
      peer.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !iceComplete.isCompleted) {
          iceComplete.complete();
        }
      };
      await peer.setLocalDescription(
        await peer.createOffer({'offerToReceiveAudio': true}),
      );
      if (peer.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await iceComplete.future.timeout(const Duration(seconds: 12));
      }
      if (generation != _generation) return;
      final local = await peer.getLocalDescription();
      final answer = await api.createSession(
        local!.sdp!,
        taskId: taskId,
        replaces: replaces,
        maxSeconds: math.max(30, limitSeconds - _carrySeconds),
        mode: mode,
      );
      sessionId = (answer['session'] as Map)['id'] as String;
      mode = (answer['session'] as Map)['mode'] == 'cli' ? 'cli' : 'api';
      if (isCli) {
        pricePerMinute = 0;
        final limits = answer['rate_limits'];
        rateLimits = limits is Map<String, dynamic> ? limits : rateLimits;
      }
      _opening = answer['opening'] as String?;
      final pricing = answer['pricing'];
      if (pricing is Map && pricing['live_per_minute'] is num) {
        pricePerMinute = (pricing['live_per_minute'] as num).toDouble();
      }
      final granted = (answer['session'] as Map)['max_seconds'];
      if (granted is int && granted < limitSeconds) limitSeconds = granted;
      if (generation != _generation) return;
      await peer.setRemoteDescription(
        RTCSessionDescription(
          (answer['transport'] as Map)['sdp'] as String,
          'answer',
        ),
      );
      // POST starts Live. No session.start on the data channel.
      await _ready!.future.timeout(const Duration(seconds: 20));
      if (generation != _generation) return;
      _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
        final id = sessionId;
        if (id != null && !closing) {
          unawaited(
            api.heartbeat(id).then(_cost).catchError((Object _) {
              if (generation == _generation && sessionId == id && !closing) {
                unawaited(
                  fail('Backend недоступен. Голосовой разговор завершается.'),
                );
              }
            }),
          );
        }
      });
    } catch (exception) {
      if (generation == _generation) {
        error = exception is BackendException
            ? exception.message
            : 'Не удалось начать GPT-Live. Проверьте сеть и разрешение микрофона.';
        status = LiveStatus.error;
      }
    } finally {
      if (!_connecting!.isCompleted) _connecting!.complete();
      if (generation != _generation || status == LiveStatus.error) {
        if (!closing) await end(keepError: status == LiveStatus.error);
      }
      _notify();
    }
  }

  void _event(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'session.started':
        _markStarted();
      case 'session.input_transcript.delta':
        addTranscript('user', event['delta'] as String? ?? '');
      case 'session.output_transcript.delta':
        addTranscript('assistant', event['delta'] as String? ?? '');
      case 'session.closed':
        finalized = true;
        if (_ready?.isCompleted == false) {
          _ready!.completeError(
            BackendException('Сессия завершилась при подключении.'),
          );
        }
        if (!closing) unawaited(end());
      case 'error':
        // In CLI mode the backend relays authoritative Codex errors instead.
        if (isCli) break;
        if (_ready?.isCompleted == false) {
          _ready!.completeError(
            BackendException('GPT-Live отклонил конфигурацию.'),
          );
        }
        unawaited(
          fail(
            'Ошибка GPT-Live. Проверьте доступ к моделям и настройки backend.',
          ),
        );
    }
    _notify();
  }

  /// Appends caption text (from the data channel or relayed by the backend).
  void addTranscript(String role, String delta) {
    if (delta.isEmpty) return;
    if (role == 'user') {
      userTranscript = _tail(userTranscript + delta);
    } else {
      assistantTranscript = _tail(assistantTranscript + delta);
    }
    _notify();
  }

  void _markStarted() {
    if (closing || status == LiveStatus.connected) return;
    status = LiveStatus.connected;
    if (_opening != null) {
      unawaited(
        _channel!
            .send(
              RTCDataChannelMessage(
                jsonEncode({
                  'type': 'session.commentary.append',
                  'event_id':
                      'callback_${DateTime.now().microsecondsSinceEpoch}',
                  'delegation_id': null,
                  'content': _opening,
                }),
              ),
            )
            .catchError((Object _) {
              unawaited(fail('Не удалось передать начало разговора.'));
            }),
      );
      _opening = null;
    }
    _started = DateTime.now();
    if (_ready?.isCompleted == false) _ready!.complete();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      sessionSeconds = DateTime.now().difference(_started!).inSeconds;
      elapsedSeconds = _carrySeconds + sessionSeconds;
      if (elapsedSeconds >= limitSeconds && !closing) {
        notice =
            'Разговор завершён автоматически: лимит ${_minutes(limitSeconds)}. Изменить можно в настройках подключения.';
        unawaited(end());
        return;
      }
      unawaited(_sampleLevels());
      _notify();
    });
  }

  static String _minutes(int seconds) => seconds % 60 == 0
      ? '${seconds ~/ 60} мин'
      : '${seconds ~/ 60} мин ${seconds % 60} с';

  void _cost(Map<String, dynamic> response) {
    if (response['mode'] == 'cli') {
      final limits = response['rate_limits'];
      if (limits is Map<String, dynamic>) rateLimits = limits;
      _notify();
      return;
    }
    final cost = response['cost'];
    if (cost is! Map) return;
    if (cost['backend_usd'] is num) {
      backendUsd = (cost['backend_usd'] as num).toDouble();
    }
    if (cost['seconds'] is num) {
      serverSeconds = (cost['seconds'] as num).toInt();
    }
    _notify();
  }

  String _tail(String value) =>
      value.length > 3000 ? value.substring(value.length - 3000) : value;
  // Derive speech indicators from media levels, independently of captions.
  Future<void> _sampleLevels() async {
    final peer = _peer;
    if (peer == null || _sampling || closing) return;
    _sampling = true;
    try {
      final stats = await peer.getStats();
      double input = 0, output = 0;
      for (final report in stats) {
        final values = report.values;
        if (values['kind'] != 'audio' && values['mediaType'] != 'audio') {
          continue;
        }
        final level = double.tryParse('${values['audioLevel'] ?? 0}') ?? 0;
        if (report.type == 'media-source') input = math.max(input, level);
        if (report.type == 'inbound-rtp' || report.type == 'track') {
          output = math.max(output, level);
        }
      }
      if (!closing && peer == _peer) {
        inputLevel = input;
        outputLevel = output;
      }
    } catch (_) {
    } finally {
      _sampling = false;
    }
  }

  Future<void> fail(String message) async {
    if (closing || _disposed) return;
    error = message;
    await end(keepError: true);
  }

  Future<void> end({bool keepError = false}) {
    if (_endOperation != null) return _endOperation!;
    final operation = _end(keepError);
    _endOperation = operation;
    return operation.whenComplete(() => _endOperation = null);
  }

  Future<void> _end(bool keepError) async {
    closing = true;
    ++_generation;
    _heartbeat?.cancel();
    for (final track in _microphone?.getTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = false;
    }
    if (_ready?.isCompleted == false) {
      _ready!.completeError(BackendException('Подключение отменено.'));
    }
    _notify();
    try {
      await _connecting?.future;
      final id = sessionId;
      if (id != null) {
        final result = await api.closeSession(id);
        final usage = result['usage'];
        if (usage is Map && usage['seconds'] is num) {
          serverSeconds = (usage['seconds'] as num).toInt();
        }
        finalized = finalized || result['finalization_confirmed'] == true;
        if (!finalized) {
          error =
              'Микрофон отключён. Финальное закрытие сессии OpenAI не подтверждено сервером.';
        }
      }
    } catch (_) {
      if (!finalized && sessionId != null) {
        error =
            'Микрофон отключён. Backend проверит закрытие по таймауту связи; итог API пока не подтверждён.';
      }
    } finally {
      await _release();
      sessionId = null;
      closing = false;
      status = (keepError || error != null)
          ? LiveStatus.error
          : LiveStatus.disconnected;
      _notify();
    }
  }

  Future<void> _release() async {
    _timer?.cancel();
    _heartbeat?.cancel();
    inputLevel = 0;
    outputLevel = 0;
    final channel = _channel;
    _channel = null;
    final peer = _peer;
    _peer = null;
    final microphone = _microphone;
    _microphone = null;
    try {
      await channel?.close();
    } catch (_) {}
    try {
      await peer?.close();
      await peer?.dispose();
    } catch (_) {}
    for (final stream in [?microphone, ..._remoteStreams]) {
      try {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      } catch (_) {}
    }
    _remoteStreams.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(end());
    super.dispose();
  }
}
