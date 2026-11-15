import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'models/task.dart';
import 'services/backend_api.dart';
import 'services/live_service.dart';
import 'services/task_events_service.dart';

class VoiceController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceController(
    this.api, {
    LiveService? liveService,
    TaskEventsService? eventService,
  }) : live = liveService ?? LiveService(api),
       events = eventService ?? TaskEventsService(api) {
    live.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    handled.addAll(api.preferences.getStringList('handled_tasks') ?? []);
    _subscription = events.events.listen(_event);
  }
  final BackendApi api;
  final LiveService live;
  final TaskEventsService events;
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
    if (!_disposed) notifyListeners();
  }

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
    } catch (exception) {
      if (!_disposed) error = exception.toString();
    } finally {
      syncing = false;
      _changed();
    }
  }

  void _offerIncoming() {
    if (!active || incoming != null || _disposed) return;
    final ready = tasks.where((t) => t.completed && !handled.contains(t.id));
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
    }
    _offerIncoming();
    _changed();
  }

  Future<void> _saveHandled() => api.preferences
      .setStringList('handled_tasks', handled.toList())
      .then((_) {});
  Future<void> answer(BackgroundTask task) async {
    incoming = null;
    handled.add(task.id);
    await _saveHandled();
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
      await live.start(taskId: ready.id);
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
    live.removeListener(_changed);
    unawaited(events.dispose());
    // Let close-session HTTP finish before closing the shared HTTP client.
    unawaited(live.end().whenComplete(api.dispose));
    live.dispose();
    super.dispose();
  }
}
