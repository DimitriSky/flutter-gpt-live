import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/task.dart';
import '../services/backend_api.dart';
import '../services/call_recorder.dart';
import '../services/live_service.dart';
import '../voice_controller.dart';
import 'context_sheets.dart';

typedef _T = ConsoleTheme;

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.api, this.controller});
  final BackendApi api;
  final VoiceController? controller;
  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  late final VoiceController controller;
  late final TextEditingController url, token;
  final description = TextEditingController();
  bool settingsOpen = false;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? VoiceController(widget.api);
    url = TextEditingController(text: widget.api.baseUrl);
    token = TextEditingController(text: widget.api.token);
    settingsOpen = !widget.api.configured;
    controller.addListener(_changed);
    unawaited(controller.initialize());
  }

  String? _announcedRecording;

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // A recording was just saved (and revealed in Finder): confirm it.
    final saved = controller.live.lastRecording;
    if (saved != null && saved != _announcedRecording) {
      _announcedRecording = saved;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: _T.deck,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              content: Text(
                'Запись сохранена и показана в Finder: ${saved.split('/').last}',
                style: const TextStyle(color: _T.deckText, height: 1.4),
              ),
              action: SnackBarAction(
                label: 'Слушать',
                textColor: _T.signal,
                onPressed: () => controller.live.recorder.open(saved),
              ),
            ),
          );
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    url.dispose();
    token.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> _configure() async {
    try {
      await controller.configure(url.text, token.text);
      if (mounted) setState(() => settingsOpen = false);
    } catch (error) {
      controller.error = error.toString();
      _changed();
    }
  }

  static double _norm(double level) => (level * 4).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Stack(
        children: [
          ExcludeFocus(
            excluding: controller.incoming != null,
            child: ExcludeSemantics(
              excluding: controller.incoming != null,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 860;
                  return RefreshIndicator(
                    onRefresh: controller.sync,
                    child: ListView(
                      padding: EdgeInsets.symmetric(
                        horizontal: wide ? 40 : 18,
                        vertical: wide ? 26 : 16,
                      ),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1120),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _header(wide),
                                const SizedBox(height: 16),
                                _toolbar(),
                                const SizedBox(height: 22),
                                _settingsReveal(),
                                if (wide)
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(flex: 6, child: _conversation()),
                                      const SizedBox(width: 26),
                                      Expanded(
                                        flex: 5,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _workspace(),
                                            if (CallRecorder.supported) ...[
                                              const SizedBox(height: 28),
                                              _recordings(),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                else ...[
                                  _conversation(),
                                  const SizedBox(height: 28),
                                  _workspace(),
                                  if (CallRecorder.supported) ...[
                                    const SizedBox(height: 28),
                                    _recordings(),
                                  ],
                                ],
                                const SizedBox(height: 30),
                                _footer(),
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          if (controller.incoming != null) _incoming(controller.incoming!),
        ],
      ),
    ),
  );

  // ───────────────────────────── chrome ─────────────────────────────

  Widget _header(bool wide) => Row(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _T.deck,
          borderRadius: BorderRadius.circular(13),
        ),
        padding: const EdgeInsets.all(9),
        child: CustomPaint(
          painter: _GrillePainter(
            level: .55,
            color: _T.signal,
            idle: _T.deckLine,
            spacing: 4.4,
            dot: 1.4,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'GPT Live',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -.8,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                // #DEV-FLAVOR: the Debug app is "GPT Live Dev" on port 8799.
                if (kDebugMode) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xffffcb2f),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'DEV',
                      style: _T.label.copyWith(fontSize: 8, color: _T.ink),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    'ГОЛОС · ФОНОВЫЕ ЗАДАЧИ',
                    overflow: TextOverflow.ellipsis,
                    style: _T.label.copyWith(fontSize: 9),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      _squareKey(
        tooltip: 'Подключение',
        icon: settingsOpen ? Icons.close_rounded : Icons.tune_rounded,
        active: settingsOpen,
        onPressed: controller.live.busy
            ? null
            : () => setState(() => settingsOpen = !settingsOpen),
      ),
    ],
  );

  /// Settings slide down from under the header and fold back up on close.
  Widget _settingsReveal() => AnimatedSwitcher(
    duration: const Duration(milliseconds: 360),
    reverseDuration: const Duration(milliseconds: 260),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(.25, 1),
        ),
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -.06),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
    ),
    layoutBuilder: (current, previous) => Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.topCenter,
      children: [...previous, ?current],
    ),
    child: settingsOpen
        ? Padding(
            key: const ValueKey('settings-open'),
            padding: const EdgeInsets.only(bottom: 22),
            child: _settings(),
          )
        : const SizedBox(
            key: ValueKey('settings-closed'),
            width: double.infinity,
          ),
  );

  Widget _toolbar() {
    final enabled = widget.api.configured;
    Widget key(IconData icon, String label, String hint, VoidCallback onTap) =>
        Expanded(
          child: Material(
            color: _T.panel,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: enabled ? onTap : null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _T.line),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: enabled ? _T.deck : _T.line,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 17, color: _T.panel),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: enabled ? _T.ink : _T.muted,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _T.label.copyWith(
                              fontSize: 8.5,
                              letterSpacing: .8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    return Row(
      children: [
        key(
          Icons.dataset_outlined,
          'База знаний',
          controller.live.status == LiveStatus.connected
              ? 'ПРАВКА В ЭФИРЕ'
              : 'ПРОСМОТР · ПРАВКА',
          _showKnowledge,
        ),
        const SizedBox(width: 10),
        key(
          Icons.edit_document,
          'Инструкции',
          controller.live.status == LiveStatus.connected
              ? 'ПРАВКА В ЭФИРЕ'
              : 'ПРОСМОТР · ПРАВКА',
          _showRules,
        ),
      ],
    );
  }

  Future<T?> _sheet<T>(Widget child, {double height = .86}) =>
      showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 760),
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * height,
            child: child,
          ),
        ),
      );

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: _T.deck,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          content: Text(
            message,
            style: const TextStyle(color: _T.deckText, height: 1.4),
          ),
        ),
      );
  }

  Future<void> _showKnowledge() =>
      _editFile(TextFileKind.knowledge, controller.saveData);

  Future<void> _showRules() =>
      _editFile(TextFileKind.rules, controller.saveRules);

  Future<void> _editFile(
    TextFileKind kind,
    Future<Map<String, dynamic>> Function(String) save,
  ) async {
    final message = await _sheet<String>(
      TextFileSheet(
        kind: kind,
        load: controller.knowledge,
        save: save,
        live: controller.live.status == LiveStatus.connected,
      ),
      height: .9,
    );
    if (message != null && mounted) _toast(message);
  }

  /// Mode that the voice chip and display describe: the running session's
  /// mode during a call, otherwise the selected switch position.
  String get _mode =>
      controller.live.busy ? controller.live.mode : widget.api.mode;

  Future<void> _pickVoice() async {
    final live = controller.live.status == LiveStatus.connected;
    final current = widget.api.voiceFor(_mode);
    final voice = await _sheet<String>(
      VoiceSheet(
        current: current,
        live: live,
        groups: _mode == 'cli' ? cliVoiceGroups : voiceGroups,
      ),
      height: .7,
    );
    if (voice == null || !mounted || voice == current) return;
    if (live) {
      _toast('Переключаю на ${voiceLabel(voice)} — разговор продолжится.');
    }
    await controller.setVoice(voice);
  }

  static String _usd(double value) => value < 0.995
      ? '\$${value.toStringAsFixed(value < 0.1 ? 3 : 2)}'
      : '\$${value.toStringAsFixed(2)}';

  Widget _squareKey({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool active = false,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      fixedSize: const Size(44, 44),
      backgroundColor: active ? _T.ink : _T.panel,
      foregroundColor: active ? _T.panel : _T.ink,
      disabledBackgroundColor: _T.panel.withValues(alpha: .5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      side: const BorderSide(color: _T.line),
    ),
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, animation) => RotationTransition(
        turns: Tween(begin: .75, end: 1.0).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: Icon(icon, key: ValueKey(icon), size: 19),
    ),
  );

  // ───────────────────── microphone & recording (macOS) ─────────────────────

  static String _clock(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _recPill() {
    final started = controller.live.recordingStarted;
    final elapsed = started == null
        ? Duration.zero
        : DateTime.now().difference(started);
    return Semantics(
      label: 'Идёт запись ${_clock(elapsed)}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _T.alert.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _led(_T.alert, size: 6, glow: true),
              const SizedBox(width: 6),
              Text(
                'REC',
                style: _T.mono.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _T.alert,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toggleKey({
    required IconData icon,
    required String label,
    required String value,
    required bool active,
    required Color activeColor,
    required String tooltip,
    required VoidCallback? onTap,
  }) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      toggled: active,
      label: '$label: $value',
      child: Material(
        color: active
            ? activeColor.withValues(alpha: .14)
            : _T.body.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: onTap == null
                      ? _T.line
                      : active
                      ? activeColor
                      : _T.muted,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: _T.label.copyWith(fontSize: 8)),
                      const SizedBox(height: 1),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: onTap == null
                              ? _T.muted
                              : active
                              ? activeColor
                              : _T.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _callControls(LiveService live) {
    final connected = live.status == LiveStatus.connected;
    final started = live.recordingStarted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _toggleKey(
                icon: live.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: 'МИКРОФОН',
                value: live.micMuted ? 'Выключен' : 'Включён',
                active: live.micMuted,
                activeColor: _T.alert,
                tooltip: live.micMuted
                    ? 'Включить микрофон'
                    : 'Выключить микрофон: ассистент вас не слышит, но разговор продолжается',
                onTap: connected
                    ? () => live.setMicMuted(!live.micMuted)
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _toggleKey(
                icon: live.recording
                    ? Icons.stop_rounded
                    : Icons.fiber_manual_record_rounded,
                label: 'ЗАПИСЬ',
                value: live.recordingBusy
                    ? 'Сохраняю…'
                    : live.recording && started != null
                    ? 'Идёт · ${_clock(DateTime.now().difference(started))}'
                    : 'Записать',
                active: live.recording,
                activeColor: _T.alert,
                tooltip: live.recording
                    ? 'Остановить и сохранить запись'
                    : 'Записать разговор: вы — левый канал, ассистент — правый',
                onTap: live.recordingBusy
                    ? null
                    : live.recording || connected
                    ? live.toggleRecording
                    : null,
              ),
            ),
          ],
        ),
        if (live.recordingError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              live.recordingError!,
              style: const TextStyle(fontSize: 11, color: _T.alert),
            ),
          ),
      ],
    );
  }

  Future<List<Recording>>? _recordingsFuture;
  String? _recordingsKey;

  Widget _recordings() {
    final recorder = controller.live.recorder;
    final key = controller.live.lastRecording ?? '';
    if (_recordingsFuture == null || key != _recordingsKey) {
      _recordingsKey = key;
      _recordingsFuture = recorder.list().catchError(
        (Object _) => <Recording>[],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          '03',
          'ЗАПИСИ',
          trailing: SizedBox(
            height: 26,
            child: TextButton.icon(
              onPressed: () async {
                final dir = await recorder.directory();
                if (dir != null) await recorder.reveal(dir);
              },
              icon: const Icon(Icons.folder_open_rounded, size: 15),
              label: const Text('Папка'),
            ),
          ),
        ),
        _panel(
          padding: EdgeInsets.zero,
          child: FutureBuilder<List<Recording>>(
            future: _recordingsFuture,
            builder: (context, snapshot) {
              final items = snapshot.data ?? const <Recording>[];
              if (items.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 18),
                  child: Text(
                    'Записей пока нет. Во время разговора нажмите «Записать»: сохранится стерео WAV (вы — слева, ассистент — справа) и текст.',
                    style: TextStyle(
                      fontSize: 12,
                      color: _T.muted,
                      height: 1.5,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (final (i, item) in items.take(8).indexed) ...[
                    if (i > 0)
                      const Divider(
                        height: 1,
                        indent: 20,
                        endIndent: 20,
                        color: _T.line,
                      ),
                    _recordingRow(item, recorder),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _recordingRow(Recording item, CallRecorder recorder) {
    final m = item.modified;
    String two(int v) => v.toString().padLeft(2, '0');
    final transcript = item.transcriptPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _T.deck,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              size: 17,
              color: _T.signal,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${two(m.day)}.${two(m.month)} · ${two(m.hour)}:${two(m.minute)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_clock(item.duration)} · ${(item.bytes / 1e6).toStringAsFixed(1)} MB${transcript == null ? '' : ' · ТЕКСТ'}',
                  style: _T.label.copyWith(fontSize: 9),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Слушать',
            onPressed: () => recorder.open(item.path),
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
          ),
          if (transcript != null)
            IconButton(
              tooltip: 'Открыть текст',
              onPressed: () => recorder.open(transcript),
              icon: const Icon(Icons.subject_rounded, size: 19),
            ),
          IconButton(
            tooltip: 'Показать в Finder',
            onPressed: () => recorder.reveal(item.path),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _footer() => Container(
    padding: const EdgeInsets.only(top: 14),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _T.line)),
    ),
    child: Row(
      children: [
        Text(
          'GPT LIVE / ЛИЧНАЯ КОНСОЛЬ',
          style: _T.label.copyWith(fontSize: 9),
        ),
        const Spacer(),
        for (final c in [_T.signal, _T.go, _T.ink])
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(left: 5),
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
      ],
    ),
  );

  Widget _section(String number, String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 12, left: 4, right: 2),
    child: SizedBox(
      height: 26,
      child: Row(
        children: [
          Text(number, style: _T.label.copyWith(color: _T.signal)),
          Text(' / ', style: _T.label.copyWith(color: _T.line)),
          Text(title, style: _T.label.copyWith(color: _T.ink)),
          const Spacer(),
          ?trailing,
        ],
      ),
    ),
  );

  Widget _panel({
    required Widget child,
    Color color = _T.panel,
    EdgeInsetsGeometry padding = const EdgeInsets.all(20),
    double radius = 24,
    bool shadow = true,
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Colors.white.withValues(alpha: .7)),
      boxShadow: shadow ? _T.raised : null,
    ),
    child: child,
  );

  Widget _led(Color color, {double size = 7, bool glow = false}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: glow
          ? [BoxShadow(color: color.withValues(alpha: .6), blurRadius: 6)]
          : null,
    ),
  );

  /// Hardware-style two-position switch: API (GPT-Live, API key) | CLI
  /// (Codex app-server, ChatGPT subscription). Locked during a call.
  Widget _modeSwitch(bool locked) {
    final mode = _mode;
    Widget side(String value, String title, String hint) {
      final selected = mode == value;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: 'Режим $title',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: locked || selected ? null : () => controller.setMode(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
              decoration: BoxDecoration(
                color: selected
                    ? (value == 'cli' ? _T.go : _T.signal)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Column(
                children: [
                  Text(
                    title,
                    style: _T.mono.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: selected ? Colors.white : _T.deckMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _T.label.copyWith(
                      fontSize: 7.5,
                      letterSpacing: .6,
                      color: selected
                          ? Colors.white.withValues(alpha: .85)
                          : _T.deckMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: locked
          ? 'Режим меняется между разговорами'
          : 'API — GPT-Live по ключу API. CLI — Codex по подписке ChatGPT на компьютере с сервером.',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: locked ? .55 : 1,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _T.deck,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            children: [
              side('api', 'API', 'GPT-LIVE · \$/МИН'),
              const SizedBox(width: 4),
              side('cli', 'CLI', 'CODEX · ПОДПИСКА'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required String value,
    required String tooltip,
    required VoidCallback? onTap,
    IconData? trailing,
  }) => Tooltip(
    message: tooltip,
    child: Material(
      color: _T.body.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
          child: Row(
            children: [
              Icon(icon, size: 17, color: _T.muted),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: _T.label.copyWith(fontSize: 8)),
                    const SizedBox(height: 1),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null)
                Icon(
                  trailing,
                  size: 16,
                  color: onTap == null ? _T.line : _T.muted,
                ),
            ],
          ),
        ),
      ),
    ),
  );

  // ─────────────────────────── conversation ───────────────────────────

  Widget _conversation() {
    final live = controller.live;
    final connected = live.status == LiveStatus.connected;
    final connecting = live.status == LiveStatus.connecting;
    final status = live.closing
        ? 'Завершение…'
        : live.switching
        ? 'Смена голоса…'
        : switch (live.status) {
            LiveStatus.disconnected => 'Disconnected',
            LiveStatus.connecting => 'Connecting',
            LiveStatus.connected => 'Connected',
            LiveStatus.error => 'Error',
          };
    final statusColor = live.status == LiveStatus.error
        ? _T.alert
        : connected
        ? _T.go
        : connecting || live.closing
        ? _T.signal
        : _T.deckMuted;
    final input = _norm(live.inputLevel), output = _norm(live.outputLevel);
    final speaking = live.outputLevel > .015;
    final title = live.closing
        ? 'До новой мысли.'
        : live.switching
        ? 'Меняю голос…'
        : connecting
        ? 'Одну секунду…'
        : connected
        ? (speaking ? 'Есть что сказать.' : 'Я вас слушаю.')
        : 'Мысли вслух.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('01', 'РАЗГОВОР'),
        _panel(
          padding: const EdgeInsets.all(14),
          radius: 30,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _display(
                status: status,
                statusColor: statusColor,
                connected: connected,
                elapsed: live.elapsedSeconds,
                input: input,
                output: output,
                cost: live.costUsd,
                cli: _mode == 'cli',
                rateLimits: live.rateLimits,
                limit: live.busy
                    ? live.limitSeconds
                    : widget.api.sessionMinutes * 60,
              ),
              const SizedBox(height: 22),
              Center(
                child: Semantics(
                  label: connected
                      ? 'Голосовая сессия активна'
                      : 'Голосовая сессия не активна',
                  child: SizedBox(
                    width: 210,
                    height: 210,
                    child: CustomPaint(
                      painter: _GrillePainter(
                        level: connected
                            ? math.max(.12, math.max(input, output))
                            : 0,
                        color: input > output ? _T.go : _T.signal,
                        idle: _T.dotOff,
                        ring: connected ? _T.signal : _T.line,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: _T.headline.copyWith(fontSize: 32),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  connected
                      ? 'Говорите свободно. Можно перебивать, уточнять и думать вместе.'
                      : 'Начните с идеи, вопроса или просто с того, что сейчас на уме.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: _T.muted,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _modeSwitch(live.busy),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: _chip(
                        icon: Icons.record_voice_over_outlined,
                        label: 'ГОЛОС',
                        value: voiceLabel(widget.api.voiceFor(_mode)),
                        tooltip: 'Выбрать голос',
                        onTap:
                            live.closing ||
                                live.switching ||
                                live.status == LiveStatus.connecting
                            ? null
                            : _pickVoice,
                        trailing: Icons.expand_more_rounded,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _chip(
                        icon: Icons.timer_outlined,
                        label: 'ЛИМИТ',
                        value: '${widget.api.sessionMinutes} мин',
                        tooltip: 'Изменить лимит в настройках',
                        onTap: live.busy
                            ? null
                            : () => setState(() => settingsOpen = true),
                        trailing: Icons.tune_rounded,
                      ),
                    ),
                  ],
                ),
              ),
              if (CallRecorder.supported) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _callControls(live),
                ),
              ],
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: live.busy ? null : controller.start,
                      icon: const Icon(Icons.mic_rounded, size: 20),
                      label: const Text('Start Conversation'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: live.busy && !live.closing
                          ? () => live.end()
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _T.alert,
                        side: BorderSide(
                          color: live.busy && !live.closing
                              ? _T.alert.withValues(alpha: .45)
                              : _T.line,
                          width: 1.5,
                        ),
                      ),
                      icon: const Icon(Icons.call_end_rounded, size: 18),
                      label: const Text('End Conversation'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                live.finalized
                    ? 'СЕССИЯ ЗАКРЫТА · МОЖНО ВЕРНУТЬСЯ'
                    : _mode == 'cli'
                    ? 'CODEX · ПО ПОДПИСКЕ CHATGPT, В РАМКАХ ЕЁ ЛИМИТОВ'
                    : 'ГОЛОС ОПЛАЧИВАЕТСЯ ВСЁ ВРЕМЯ ПОДКЛЮЧЕНИЯ',
                textAlign: TextAlign.center,
                style: _T.label.copyWith(
                  fontSize: 8.5,
                  letterSpacing: 1,
                  color: live.finalized ? _T.go : _T.muted,
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
        if (live.notice != null &&
            !live.busy &&
            controller.error == null &&
            live.error == null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _T.signalWash,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _T.signal.withValues(alpha: .25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.timer_off_outlined,
                  size: 18,
                  color: _T.signal,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    live.notice!,
                    style: const TextStyle(
                      color: _T.ink,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (controller.error != null || live.error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _T.alertWash,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _T.alert.withValues(alpha: .2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: _led(_T.alert, glow: true),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    controller.error ?? live.error!,
                    style: const TextStyle(
                      color: _T.alert,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (live.userTranscript.isNotEmpty ||
            live.assistantTranscript.isNotEmpty) ...[
          const SizedBox(height: 12),
          _panel(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            radius: 20,
            shadow: false,
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(Icons.subject_rounded, size: 18),
              title: Text(
                'ТЕКСТ РАЗГОВОРА',
                style: _T.label.copyWith(color: _T.ink),
              ),
              children: [
                if (live.userTranscript.isNotEmpty)
                  _transcript('ВЫ', live.userTranscript, _T.go),
                if (live.assistantTranscript.isNotEmpty)
                  _transcript('АССИСТЕНТ', live.assistantTranscript, _T.signal),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _display({
    required String status,
    required Color statusColor,
    required bool connected,
    required int elapsed,
    required double input,
    required double output,
    required double cost,
    required bool cli,
    required Map<String, dynamic>? rateLimits,
    required int limit,
  }) {
    final primary = rateLimits?['primary'];
    final secondary = rateLimits?['secondary'];
    String? percent(Object? window) =>
        window is Map && window['usedPercent'] is num
        ? '${(window['usedPercent'] as num).round()}%'
        : null;
    final fiveHour = percent(primary), weekly = percent(secondary);
    final meterText = cli
        ? (fiveHour == null ? 'ПОДПИСКА' : '5Ч $fiveHour')
        : '≈${_usd(cost)}';
    final meterTip = cli
        ? 'Режим CLI: голос и Codex по подписке ChatGPT. Лимиты Codex: 5 часов — ${fiveHour ?? '—'}, неделя — ${weekly ?? '—'}.'
        : 'Оценка: голос \$0.05/мин + токены backend, о которых сообщил сервер';
    String clock(int s) =>
        '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    final time = clock(elapsed);
    final remaining = math.max(0, limit - elapsed);
    final ending = connected && remaining <= 30;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: _T.deck,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _led(statusColor, glow: connected),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _T.mono.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: connected ? _T.deckText : _T.deckMuted,
                  ),
                ),
              ),
              if (controller.live.recording) ...[
                const SizedBox(width: 8),
                _recPill(),
              ],
              const SizedBox(width: 10),
              Tooltip(
                message: meterTip,
                child: Semantics(
                  label: cli ? meterTip : 'Потрачено примерно ${_usd(cost)}',
                  child: ExcludeSemantics(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _T.deckRaised,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        meterText,
                        style: _T.mono.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cli
                              ? _T.go
                              : connected || cost > 0
                              ? _T.deckText
                              : _T.deckMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                time,
                style: _T.mono.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1,
                  color: ending
                      ? _T.alert
                      : connected
                      ? _T.signal
                      : _T.deckMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          controller.live.micMuted
              ? _meter(
                  'OFF',
                  'Микрофон выключен',
                  0,
                  _T.alert,
                  codeColor: _T.alert,
                )
              : _meter('IN ', 'Ваш голос', input, _T.go),
          const SizedBox(height: 7),
          _meter('OUT', 'Ассистент', output, _T.signal),
          const SizedBox(height: 11),
          Semantics(
            label:
                'Лимит разговора ${clock(limit)}, осталось ${clock(remaining)}',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      'LIM',
                      style: _T.mono.copyWith(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: ending ? _T.alert : _T.deckMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: limit == 0
                            ? 0
                            : (elapsed / limit).clamp(0.0, 1.0),
                        minHeight: 3,
                        color: ending ? _T.alert : _T.deckMuted,
                        backgroundColor: _T.deckRaised,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    connected ? '−${clock(remaining)}' : clock(limit),
                    style: _T.mono.copyWith(
                      fontSize: 10,
                      color: ending ? _T.alert : _T.deckMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _meter(
    String code,
    String semantics,
    double value,
    Color color, {
    Color? codeColor,
  }) {
    const segments = 18;
    final lit = (value * segments).round();
    return Semantics(
      label: '$semantics: ${(value * 100).round()}%',
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                code,
                style: _T.mono.copyWith(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: codeColor ?? (value > .06 ? color : _T.deckMuted),
                ),
              ),
            ),
            for (var i = 0; i < segments; i++)
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 1.2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1.5),
                    color: i < lit
                        ? (i >= segments - 3 ? _T.alert : color)
                        : _T.deckRaised,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _transcript(String name, String text, Color color) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _T.body.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _led(color, size: 6),
            const SizedBox(width: 7),
            Text(name, style: _T.label.copyWith(fontSize: 9)),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.6)),
      ],
    ),
  );

  // ──────────────────────────── workspace ────────────────────────────

  /// The journal shows only the newest tasks (newest first).
  static const _journalLimit = 10;

  Widget _workspace() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _section(
        '02',
        'ФОНОВЫЕ ЗАДАЧИ',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _led(
              controller.eventsConnected ? _T.go : _T.signal,
              size: 6,
              glow: controller.eventsConnected,
            ),
            const SizedBox(width: 6),
            Text(
              controller.eventsConnected ? 'НА СВЯЗИ' : 'НЕТ СВЯЗИ',
              style: _T.label.copyWith(fontSize: 9),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 28,
              height: 26,
              child: IconButton(
                tooltip: 'Обновить задачи',
                padding: EdgeInsets.zero,
                onPressed: controller.syncing ? null : controller.sync,
                icon: const Icon(Icons.refresh_rounded, size: 16),
              ),
            ),
          ],
        ),
      ),
      _panel(
        color: _T.deck,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'А пока —\nпоручите рутину.',
                    style: _T.headline.copyWith(
                      fontSize: 26,
                      color: _T.deckText,
                    ),
                  ),
                ),
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: _T.signal,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.north_east_rounded,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Попросите подготовить отчёт и позвать по готовности. После подтверждения можно завершить разговор.',
              style: TextStyle(fontSize: 12, color: _T.deckMuted, height: 1.6),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.call_rounded, size: 13, color: _T.go),
                const SizedBox(width: 7),
                Text(
                  'ВЕРНЁМСЯ К ВАМ С РЕЗУЛЬТАТОМ',
                  style: _T.label.copyWith(fontSize: 9, color: _T.go),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _panel(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Text('ЖУРНАЛ', style: _T.label.copyWith(fontSize: 9)),
                  const Spacer(),
                  Text(
                    // Only the latest entries are listed; the count shows them all.
                    controller.tasks.length > _journalLimit
                        ? '$_journalLimit ИЗ ${controller.tasks.length}'
                        : controller.tasks.length.toString().padLeft(2, '0'),
                    style: _T.label.copyWith(fontSize: 9, color: _T.ink),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _T.line),
            if (controller.tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _T.body,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.inbox_outlined,
                        color: _T.muted,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Пока пусто',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Задачи появятся здесь',
                            style: TextStyle(fontSize: 12, color: _T.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            for (final (i, task)
                in controller.tasks.take(_journalLimit).indexed) ...[
              if (i > 0)
                const Divider(
                  height: 1,
                  indent: 20,
                  endIndent: 20,
                  color: _T.line,
                ),
              _task(task),
            ],
            const Divider(height: 1, color: _T.line),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 6),
                leading: const Icon(
                  Icons.edit_note_rounded,
                  size: 21,
                  color: _T.signal,
                ),
                title: const Text(
                  'Передать текстовое задание',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(6, 0, 6, 16),
                children: [
                  TextField(
                    controller: description,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: 12000,
                    decoration: const InputDecoration(
                      hintText:
                          'Например: составь структурированный отчёт по моей базе знаний.',
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: controller.submitting || !widget.api.configured
                          ? null
                          : () async {
                              if (await controller.submit(description.text)) {
                                description.clear();
                              }
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: _T.ink,
                        minimumSize: const Size(0, 48),
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                      label: Text(
                        controller.submitting
                            ? 'Отправка…'
                            : 'Запустить в фоне',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Входящий вызов появится внутри открытого приложения. В фоне и при блокировке сигнал не гарантируется.',
          style: TextStyle(fontSize: 11, color: _T.muted, height: 1.55),
        ),
      ),
    ],
  );

  Widget _task(BackgroundTask task) {
    final failed = task.status == 'Failed';
    final color = task.completed
        ? _T.go
        : failed
        ? _T.alert
        : _T.signal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _led(color, size: 7, glow: !task.terminal),
              const SizedBox(width: 8),
              Text(
                task.status.toUpperCase(),
                style: _T.label.copyWith(fontSize: 9, color: color),
              ),
              if (task.mode == 'cli') ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _T.deck,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    'CODEX',
                    style: _T.label.copyWith(fontSize: 8, color: _T.deckText),
                  ),
                ),
              ],
              if (!task.terminal) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              task.title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ),
          if (task.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4, right: 6),
              child: Text(
                task.error!,
                style: const TextStyle(
                  fontSize: 12,
                  color: _T.muted,
                  height: 1.5,
                ),
              ),
            ),
          if (task.completed) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                FilledButton.icon(
                  onPressed: () => controller.answer(task),
                  style: FilledButton.styleFrom(
                    backgroundColor: _T.go,
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  icon: const Icon(Icons.call_rounded, size: 15),
                  label: const Text('Обсудить'),
                ),
                OutlinedButton(
                  onPressed: () => _result(task),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Читать результат'),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  // ───────────────────────────── settings ─────────────────────────────

  Widget _settings() => _panel(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            children: [
              Text('00', style: _T.label.copyWith(color: _T.signal)),
              Text(' / ', style: _T.label.copyWith(color: _T.line)),
              Text('ПОДКЛЮЧЕНИЕ', style: _T.label.copyWith(color: _T.ink)),
              const Spacer(),
              _led(widget.api.configured ? _T.go : _T.signal, size: 6),
            ],
          ),
        ),
        TextField(
          controller: url,
          keyboardType: TextInputType.url,
          style: _T.mono.copyWith(fontSize: 13),
          decoration: const InputDecoration(
            labelText: 'Адрес сервера',
            hintText: 'http://192.168.1.10:8789',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: token,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          style: _T.mono.copyWith(fontSize: 13),
          decoration: const InputDecoration(labelText: 'DEV_CLIENT_TOKEN'),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _configure,
          style: FilledButton.styleFrom(backgroundColor: _T.ink),
          icon: const Icon(Icons.power_settings_new_rounded, size: 18),
          label: const Text('Подключиться'),
        ),
        const SizedBox(height: 12),
        const Text(
          'На компьютере — localhost. На телефоне — LAN IP сервера; в Android-эмуляторе — 10.0.2.2.',
          style: TextStyle(fontSize: 11, color: _T.muted, height: 1.55),
        ),
        const SizedBox(height: 18),
        const Divider(height: 1, color: _T.line),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Лимит разговора',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Сессия завершится сама, если забыть её выключить.',
                    style: TextStyle(
                      fontSize: 11,
                      color: _T.muted,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _stepper(),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _T.deck,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Text(
                'ПОТРАЧЕНО ВСЕГО',
                style: _T.label.copyWith(fontSize: 9, color: _T.deckMuted),
              ),
              const Spacer(),
              Text(
                controller.totalUsd == null
                    ? '—'
                    : '≈${_usd(controller.totalUsd!)}',
                style: _T.mono.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _T.deckText,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Оценка по тарифам для режима API: голос + backend + фоновые задачи. Режим CLI идёт по подписке ChatGPT. Точная сумма — в биллинге OpenAI.',
          style: TextStyle(fontSize: 10, color: _T.muted, height: 1.5),
        ),
      ],
    ),
  );

  Widget _stepper() {
    final minutes = widget.api.sessionMinutes;
    // 1-minute steps up to 10 min, then 5-minute steps up to the 60-min cap.
    final down = minutes > 10 ? 5 : 1, up = minutes >= 10 ? 5 : 1;
    Widget step(IconData icon, int delta, String tip) => IconButton(
      tooltip: tip,
      onPressed:
          (minutes + delta) < BackendApi.minSessionMinutes ||
              (minutes + delta) > BackendApi.maxSessionMinutes
          ? null
          : () => controller.setSessionMinutes(minutes + delta),
      style: IconButton.styleFrom(
        fixedSize: const Size(38, 38),
        backgroundColor: _T.body,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
      icon: Icon(icon, size: 18),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        step(Icons.remove_rounded, -down, 'Меньше на $down мин'),
        SizedBox(
          width: 62,
          child: Text(
            '$minutes мин',
            textAlign: TextAlign.center,
            style: _T.mono.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        step(Icons.add_rounded, up, 'Больше на $up мин'),
      ],
    );
  }

  // ────────────────────────────── result ──────────────────────────────

  Future<void> _result(BackgroundTask task) async {
    try {
      final result = await widget.api.task(task.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 720),
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .72,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 26, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _led(_T.go, size: 7, glow: true),
                      const SizedBox(width: 8),
                      Text('ГОТОВЫЙ РЕЗУЛЬТАТ', style: _T.label),
                      const Spacer(),
                      _squareKey(
                        tooltip: 'Закрыть результат',
                        icon: Icons.close_rounded,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.title,
                            style: _T.headline.copyWith(fontSize: 28),
                          ),
                          const SizedBox(height: 18),
                          Container(height: 3, width: 36, color: _T.signal),
                          const SizedBox(height: 18),
                          SelectableText(
                            result.result ?? 'Результат отсутствует',
                            style: const TextStyle(fontSize: 14, height: 1.75),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (error) {
      controller.error = error.toString();
      _changed();
    }
  }

  // ───────────────────────────── incoming ─────────────────────────────

  Widget _incoming(BackgroundTask task) => Positioned.fill(
    child: ColoredBox(
      color: _T.deck.withValues(alpha: .62),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
              decoration: BoxDecoration(
                color: _T.deck,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: _T.deckLine),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 40,
                    offset: Offset(0, 20),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _led(_T.signal, glow: true),
                      const SizedBox(width: 9),
                      Text(
                        'ВХОДЯЩИЙ ЗВОНОК',
                        style: _T.label.copyWith(color: _T.deckText),
                      ),
                      const Spacer(),
                      Text(
                        'GPT LIVE',
                        style: _T.label.copyWith(color: _T.deckMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Center(
                    child: SizedBox(
                      width: 150,
                      height: 150,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Positioned.fill(
                            child: CustomPaint(
                              painter: _GrillePainter(
                                level: .78,
                                color: _T.go,
                                idle: _T.deckRaised,
                                ring: _T.go,
                                spacing: 10,
                                dot: 3,
                              ),
                            ),
                          ),
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: _T.deck,
                              shape: BoxShape.circle,
                              border: Border.all(color: _T.go, width: 2),
                            ),
                            child: const Icon(
                              Icons.task_alt_rounded,
                              size: 26,
                              color: _T.go,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Результат готов',
                    textAlign: TextAlign.center,
                    style: _T.headline.copyWith(
                      fontSize: 32,
                      color: _T.deckText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    task.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: _T.deckMuted,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 26),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: controller.later,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _T.deckText,
                            side: const BorderSide(
                              color: _T.deckLine,
                              width: 1.5,
                            ),
                            minimumSize: const Size(0, 54),
                          ),
                          child: const Text('Позже'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => controller.answer(task),
                          style: FilledButton.styleFrom(backgroundColor: _T.go),
                          icon: const Icon(Icons.call_rounded, size: 18),
                          label: const Text('Ответить'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '«ОТВЕТИТЬ» НАЧНЁТ НОВЫЙ ГОЛОСОВОЙ РАЗГОВОР',
                    textAlign: TextAlign.center,
                    style: _T.label.copyWith(
                      fontSize: 8.5,
                      letterSpacing: .8,
                      color: _T.deckMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Speaker-grille visualiser: a circular field of dots that light up from
/// the centre outward in proportion to [level] (0..1).
class _GrillePainter extends CustomPainter {
  const _GrillePainter({
    required this.level,
    required this.color,
    required this.idle,
    this.ring,
    this.spacing = 12,
    this.dot = 3.4,
  });

  final double level;
  final Color color, idle;
  final Color? ring;
  final double spacing, dot;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    if (ring != null) {
      canvas.drawCircle(
        center,
        radius - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ring!.withValues(alpha: .35),
      );
    }
    final field = radius - (ring != null ? spacing * .9 : 0);
    final reach = field * level.clamp(0.0, 1.0);
    final paint = Paint();
    final steps = (field / spacing).floor();
    for (var y = -steps; y <= steps; y++) {
      for (var x = -steps; x <= steps; x++) {
        final offset = Offset(x * spacing, y * spacing);
        final d = offset.distance;
        if (d > field - dot) continue;
        final t = reach <= 0
            ? 0.0
            : ((reach - d) / spacing + 1).clamp(0.0, 1.0);
        paint.color = Color.lerp(idle, color, t)!;
        canvas.drawCircle(center + offset, dot * (1 + .25 * t), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GrillePainter old) =>
      old.level != level ||
      old.color != color ||
      old.idle != idle ||
      old.ring != ring;
}
