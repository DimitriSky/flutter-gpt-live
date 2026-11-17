import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'models/task.dart';
import 'services/backend_api.dart';
import 'services/call_keepalive.dart';
import 'services/live_service.dart';
import 'services/task_events_service.dart';

class VoiceController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceController(
    this.api, {
    LiveService? liveService,
    TaskEventsService? eventService,
    CallKeepAlive? keepAlive,
  }) : live = liveService ?? LiveService(api),
       events = eventService ?? TaskEventsService(api),
       keepAlive = keepAlive ?? CallKeepAlive() {
    if (CallKeepAlive.supported) {
      this.keepAlive.onEndRequested = () {
        if (live.busy) unawaited(live.end());
      };
    }
    live.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    handled.addAll(api.preferences.getStringList('handled_tasks') ?? []);
    _subscription = events.events.listen(_event);
  }
  final BackendApi api;
  final LiveService live;
  final TaskEventsService events;
  final CallKeepAlive keepAlive;
  final Map<String, BackgroundTask> _tasks = {};
  final Set<String> handled = {};
  List<BackgroundTask> get tasks => _tasks.values.toList().reversed.toList();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _poll;
  bool eventsConnected = false,
      active = true,
      syncing = false,
      submitting = false;
  bool _disposed = false;
  String? error;
  BackgroundTask? incoming;
  double? totalUsd;
  bool _wasBusy = false;
  String? _submissionText, _submissionKey;

  Future<void> initialize() async {
    await api.saveIdentity();
    if (_disposed) return;
    events.start();
    if (api.configured) await sync();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (active && api.configured) unawaited(sync());
    });
  }

  void _changed() {
    if (_disposed) return;
    // Refresh the spending total once a voice session has finished closing.
    if (_wasBusy && !live.busy) unawaited(refreshUsage());
    _syncKeepAlive();
    _wasBusy = live.busy;
    notifyListeners();
  }

  /// #ANDROID-BG: run the foreground service while a call is connected (the
  /// microphone permission is granted by then); stop it when the call ends.
  void _syncKeepAlive() {
    if (!CallKeepAlive.supported) return;
    if (live.status == LiveStatus.connected && !keepAlive.running) {
      unawaited(
        keepAlive.start(
          title: 'Идёт разговор',
          text: live.isCli
              ? 'GPT Live · Codex · голос ${api.voiceFor('cli')}'
              : 'GPT Live · GPT-Live · голос ${api.voiceFor('api')}',
        ),
      );
    } else if (!live.busy && keepAlive.running) {
      unawaited(keepAlive.stop());
      // The call ended while hidden (e.g. "End" in the notification).
      if (!active) {
        events.stop();
        eventsConnected = false;
      }
    }
  }

  Future<void> refreshUsage() async {
    if (!api.configured || _disposed) return;
    try {
      final usage = await api.usage();
      final total = usage['total_usd'];
      if (total is num && !_disposed) {
        totalUsd = total.toDouble();
        notifyListeners();
      }
    } catch (_) {
      // Spending is informational; never block the main flow.
    }
  }

  /// Saves the voice; during a call the session is swapped to apply it now.
  Future<void> setVoice(String voice) async {
    // During a call the voice belongs to the running session's mode.
    final mode = live.busy ? live.mode : api.mode;
    final changed = voice != api.voiceFor(mode);
    await api.setVoiceFor(mode, voice);
    _changed();
    if (changed && live.status == LiveStatus.connected) {
      await live.switchVoice();
    }
  }

  /// Switches between GPT-Live over the API key and Codex over the subscription.
  Future<void> setMode(String mode) async {
    if (live.busy) return;
    await api.setMode(mode);
    _changed();
  }

  Future<void> setSessionMinutes(int minutes) async {
    await api.setSessionMinutes(minutes);
    _changed();
  }

  Future<Map<String, dynamic>> knowledge() => api.knowledge();

  /// Saves rules.md on the backend; a running voice session is updated live.
  Future<Map<String, dynamic>> saveRules(String rules) => api.saveRules(rules);

  /// Saves data.txt on the backend; running calls and Codex threads get it now.
  Future<Map<String, dynamic>> saveData(String data) => api.saveData(data);

  void _event(Map<String, dynamic> event) {
    if (_disposed) return;
    if (event['type'] == 'socket.connected') {
      eventsConnected = true;
      unawaited(sync());
    }
    if (event['type'] == 'socket.disconnected') eventsConnected = false;
    if (event['type'] == 'live.error' &&
        event['session_id'] == live.sessionId) {
      unawaited(live.fail(event['message'] as String));
    }
    if (event['type'] == 'live.closed' &&
        event['session_id'] == live.sessionId &&
        !live.closing) {
      unawaited(live.end());
    }
    if (event['type'] == 'live.transcript' &&
        event['session_id'] == live.sessionId) {
      live.addTranscript(
        event['role'] as String? ?? 'assistant',
        event['delta'] as String? ?? '',
      );
    }
    if (event['task'] is Map<String, dynamic>) {
      _merge(BackgroundTask.fromJson(event['task'] as Map<String, dynamic>));
      _offerIncoming();
    }
    _changed();
  }

  void _merge(BackgroundTask task) {
    final old = _tasks[task.id];
    const rank = {'Queued': 0, 'Running': 1, 'Completed': 2, 'Failed': 2};
    if (old != null && (rank[old.status] ?? 0) > (rank[task.status] ?? 0)) {
      return;
    }
    _tasks[task.id] = task;
    // Answered or postponed on another device: stop ringing here too.
    if (task.acknowledged && incoming?.id == task.id) incoming = null;
  }

  Future<void> sync() async {
    if (syncing || _disposed) return;
    syncing = true;
    try {
      final list = await api.tasks();
      if (_disposed) return;
      for (final task in list) {
        _merge(task);
      }
      error = null;
      _offerIncoming();
      unawaited(refreshUsage());
    } catch (exception) {
      if (!_disposed) error = exception.toString();
    } finally {
      syncing = false;
      _changed();
    }
  }

  void _offerIncoming() {
    if (!active || incoming != null || _disposed) return;
    final ready = tasks.where(
      (t) =>
          t.completed &&
          !t.delivered &&
          !t.acknowledged &&
          !handled.contains(t.id),
    );
    if (ready.isEmpty) return;
    incoming = ready.first;
    unawaited(
      SystemSound.play(SystemSoundType.alert).catchError((Object _) {}),
    );
    unawaited(HapticFeedback.vibrate().catchError((Object _) {}));
  }

  Future<void> later() async {
    final task = incoming;
    incoming = null;
    if (task != null) {
      handled.add(task.id);
      await _saveHandled();
      unawaited(_ack(task.id));
    }
    _offerIncoming();
    _changed();
  }

  Future<void> _ack(String id) async {
    try {
      await api.ackTask(id);
    } catch (_) {
      // Older servers have no shared "seen" mark; the local one still applies.
    }
  }

  Future<void> _saveHandled() => api.preferences
      .setStringList('handled_tasks', handled.toList())
      .then((_) {});
  Future<void> answer(BackgroundTask task) async {
    incoming = null;
    handled.add(task.id);
    await _saveHandled();
    unawaited(_ack(task.id));
    _changed();
    try {
      // Fetch authoritative result before requesting the microphone or a new paid session.
      final ready = await api.task(task.id);
      if (!ready.completed) {
        throw BackendException('Результат задачи ещё не готов.');
      }
      _merge(ready);
      if (live.busy) await live.end();
      api.conversationId = ready.conversationId;
      await api.saveIdentity();
      await live.start(taskId: ready.id, mode: ready.mode);
    } catch (exception) {
      error = exception.toString();
    }
    _offerIncoming();
    _changed();
  }

  Future<void> start() async {
    error = null;
    if (!api.configured) {
      error = 'Укажите адрес backend и DEV_CLIENT_TOKEN в подключении.';
      _changed();
      return;
    }
    await live.start();
    _changed();
  }

  Future<void> configure(String url, String token) async {
    if (live.busy) await live.end();
    events.stop();
    eventsConnected = false;
    await api.configure(url, token);
    error = null;
    _tasks.clear();
    incoming = null;
    events.start();
    await sync();
  }

  Future<bool> submit(String description) async {
    if (submitting) return false;
    final text = description.trim();
    if (text.isEmpty) return false;
    if (_submissionText != text) {
      _submissionText = text;
      _submissionKey = const Uuid().v4();
    }
    submitting = true;
    error = null;
    _changed();
    try {
      final task = await api.createTask(text, _submissionKey!);
      _merge(task);
      _submissionKey = null;
      _submissionText = null;
      return true;
    } catch (exception) {
      error = exception.toString();
      return false;
    } finally {
      submitting = false;
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      active = true;
      events.start();
      if (api.configured) unawaited(sync());
      _offerIncoming();
    } else if (LiveService.desktop) {
      // macOS reports `hidden`/`inactive` as soon as another app takes focus
      // or covers the window. Keep the call, the task events and incoming
      // callbacks alive; only quitting the app ends the call.
      if (state == AppLifecycleState.detached && live.busy) {
        unawaited(live.end());
      }
    } else if (CallKeepAlive.supported &&
        live.busy &&
        state != AppLifecycleState.detached) {
      // #ANDROID-BG: the foreground service keeps the call and its events
      // running in the background; incoming-call overlays wait for resume.
      active = false;
    } else if ([
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ].contains(state)) {
      active = false;
      events.stop();
      eventsConnected = false;
      if (live.busy) unawaited(live.end());
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    keepAlive.onEndRequested = null;
    unawaited(keepAlive.stop());
    live.removeListener(_changed);
    unawaited(events.dispose());
    // Let close-session HTTP finish before closing the shared HTTP client.
    unawaited(live.end().whenComplete(api.dispose));
    live.dispose();
    super.dispose();
  }
}
