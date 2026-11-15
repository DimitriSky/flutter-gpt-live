import 'dart:async';
import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/task.dart';
import '../services/backend_api.dart';
import '../services/live_service.dart';
import '../voice_controller.dart';

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

  void _changed() {
    if (mounted) setState(() {});
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
                        horizontal: wide ? 40 : 22,
                        vertical: wide ? 24 : 18,
                      ),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1120),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _header(wide),
                                const SizedBox(height: 26),
                                if (settingsOpen) ...[
                                  _settings(),
                                  const SizedBox(height: 24),
                                ],
                                if (wide)
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(flex: 6, child: _conversation()),
                                      const SizedBox(width: 28),
                                      Expanded(flex: 5, child: _workspace()),
                                    ],
                                  )
                                else ...[
                                  _conversation(),
                                  const SizedBox(height: 30),
                                  _workspace(),
                                ],
                                const SizedBox(height: 28),
                                const Divider(height: 1),
                                const SizedBox(height: 15),
                                const Row(
                                  children: [
                                    Text(
                                      'GPT LIVE / ЛИЧНОЕ ПРОСТРАНСТВО',
                                      style: StudioTheme.label,
                                    ),
                                    Spacer(),
                                    Icon(
                                      Icons.north_east,
                                      size: 14,
                                      color: StudioTheme.muted,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
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

  Widget _header(bool wide) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: StudioTheme.orange,
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(
          Icons.graphic_eq_rounded,
          color: StudioTheme.surface,
          size: 24,
        ),
      ),
      const SizedBox(width: 12),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'GPT Live',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w600,
                letterSpacing: -.6,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Голос и работа в фоне',
              style: TextStyle(fontSize: 11, color: StudioTheme.muted),
            ),
          ],
        ),
      ),
      if (wide) ...[
        const Text('МЕНЬШЕ ШУМА. БОЛЬШЕ МЫСЛИ.', style: StudioTheme.label),
        const SizedBox(width: 24),
      ],
      IconButton.outlined(
        tooltip: 'Подключение',
        onPressed: controller.live.busy
            ? null
            : () => setState(() => settingsOpen = !settingsOpen),
        style: IconButton.styleFrom(
          side: const BorderSide(color: StudioTheme.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: const Icon(Icons.tune_rounded, size: 19),
      ),
    ],
  );

  Widget _section(String number, String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: SizedBox(
      height: 24,
      child: Row(
        children: [
          Text(
            number,
            style: StudioTheme.label.copyWith(color: StudioTheme.orange),
          ),
          const SizedBox(width: 9),
          Text(title, style: StudioTheme.label),
          const Spacer(),
          ?trailing,
        ],
      ),
    ),
  );

  Widget _conversation() {
    final live = controller.live;
    final connected = live.status == LiveStatus.connected;
    final connecting = live.status == LiveStatus.connecting;
    final status = live.closing
        ? 'Завершение…'
        : switch (live.status) {
            LiveStatus.disconnected => 'Disconnected',
            LiveStatus.connecting => 'Connecting',
            LiveStatus.connected => 'Connected',
            LiveStatus.error => 'Error',
          };
    final statusColor = live.status == LiveStatus.error
        ? StudioTheme.red
        : connected
        ? StudioTheme.green
        : StudioTheme.muted;
    final title = live.closing
        ? 'До новой\nмысли.'
        : connecting
        ? 'Одну\nсекунду…'
        : connected
        ? (live.outputLevel > .015 ? 'Есть\nчто сказать.' : 'Я вас\nслушаю.')
        : 'Мысли\nвслух.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('01', 'РАЗГОВОР'),
        _card(
          padding: const EdgeInsets.all(26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _badge(
                    status,
                    statusColor,
                    connected ? StudioTheme.greenWash : StudioTheme.paper,
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: StudioTheme.muted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${(live.elapsedSeconds ~/ 60).toString().padLeft(2, '0')}:${(live.elapsedSeconds % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: StudioTheme.muted,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: StudioTheme.editorial.copyWith(fontSize: 43),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _voiceMark(connected: connected, level: live.outputLevel),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                connected
                    ? 'Говорите свободно. Можно перебивать, уточнять и думать вместе.'
                    : 'Начните с идеи, вопроса или просто\nс того, что сейчас на уме.',
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.65,
                  color: StudioTheme.muted,
                ),
              ),
              const SizedBox(height: 26),
              const Divider(height: 1),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _level(
                      'ВАШ ГОЛОС',
                      live.inputLevel,
                      StudioTheme.orange,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: _level(
                      'АССИСТЕНТ',
                      live.outputLevel,
                      StudioTheme.green,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: live.busy ? null : controller.start,
                icon: const Icon(Icons.mic_none_rounded, size: 19),
                label: const Text('Start Conversation'),
              ),
              const SizedBox(height: 9),
              OutlinedButton.icon(
                onPressed: live.busy && !live.closing ? () => live.end() : null,
                icon: const Icon(Icons.call_end_outlined, size: 17),
                label: const Text('End Conversation'),
              ),
              const SizedBox(height: 15),
              Text(
                live.finalized
                    ? 'Сессия закрыта. Можно вернуться в любой момент.'
                    : 'Голос оплачивается всё время подключения',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.5,
                  color: live.finalized ? StudioTheme.green : StudioTheme.muted,
                ),
              ),
            ],
          ),
        ),
        if (controller.error != null || live.error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xfff5e5df),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 18,
                  color: StudioTheme.red,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    controller.error ?? live.error!,
                    style: const TextStyle(
                      color: StudioTheme.red,
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
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: const Icon(Icons.notes_rounded, size: 18),
            title: const Text(
              'Текст разговора',
              style: TextStyle(fontSize: 13),
            ),
            children: [
              if (live.userTranscript.isNotEmpty)
                _transcript('ВЫ', live.userTranscript),
              if (live.assistantTranscript.isNotEmpty)
                _transcript('АССИСТЕНТ', live.assistantTranscript),
            ],
          ),
        ],
      ],
    );
  }

  Widget _workspace() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _section(
        '02',
        'ФОНОВЫЕ ЗАДАЧИ',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: controller.eventsConnected
                    ? StudioTheme.green
                    : StudioTheme.orange,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              controller.eventsConnected ? 'На связи' : 'Нет связи',
              style: const TextStyle(fontSize: 10, color: StudioTheme.muted),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 26,
              height: 24,
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
      _card(
        color: const Color(0xffe9e8dd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'А пока —\nпоручите рутину.',
                    style: StudioTheme.editorial.copyWith(fontSize: 29),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(
                    Icons.north_east_rounded,
                    size: 24,
                    color: StudioTheme.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            const Text(
              'Попросите подготовить отчёт и позвать по готовности. После подтверждения можно завершить разговор.',
              style: TextStyle(
                fontSize: 12,
                color: StudioTheme.muted,
                height: 1.65,
              ),
            ),
            const SizedBox(height: 19),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: StudioTheme.surface.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call_outlined, size: 13, color: StudioTheme.green),
                  SizedBox(width: 7),
                  Text(
                    'Вернёмся к вам с результатом',
                    style: TextStyle(fontSize: 10, color: StudioTheme.green),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (controller.tasks.isEmpty)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
          decoration: BoxDecoration(
            border: Border.all(color: StudioTheme.line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            children: [
              Icon(Icons.inbox_outlined, color: StudioTheme.muted, size: 25),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Пока чистый лист',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Задачи появятся здесь',
                      style: TextStyle(fontSize: 11, color: StudioTheme.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      for (final task in controller.tasks)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: _task(task)),
      const SizedBox(height: 12),
      ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 2),
        leading: const Icon(
          Icons.edit_note_rounded,
          size: 21,
          color: StudioTheme.orange,
        ),
        title: const Text(
          'Передать текстовое задание',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
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
              icon: const Icon(Icons.arrow_upward_rounded, size: 17),
              label: Text(
                controller.submitting ? 'Отправка…' : 'Запустить в фоне',
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      const Text(
        'Входящий вызов появится внутри открытого приложения. В фоне и при блокировке сигнал не гарантируется.',
        style: TextStyle(fontSize: 10, color: StudioTheme.muted, height: 1.6),
      ),
    ],
  );

  Widget _settings() => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('↗', 'ПОДКЛЮЧЕНИЕ'),
        TextField(
          controller: url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Адрес сервера',
            hintText: 'http://192.168.1.10:8789',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: token,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'DEV_CLIENT_TOKEN'),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _configure,
            child: const Text('Подключиться'),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'На компьютере — localhost. На телефоне — LAN IP сервера; в Android-эмуляторе — 10.0.2.2.',
          style: TextStyle(fontSize: 11, color: StudioTheme.muted, height: 1.6),
        ),
      ],
    ),
  );

  Widget _card({
    required Widget child,
    Color color = StudioTheme.surface,
    EdgeInsetsGeometry padding = const EdgeInsets.all(22),
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: StudioTheme.line.withValues(alpha: .75)),
    ),
    child: child,
  );

  Widget _badge(String text, Color color, Color background) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    ),
  );

  Widget _voiceMark({required bool connected, required double level}) =>
      Semantics(
        label: connected
            ? 'Голосовая сессия активна'
            : 'Голосовая сессия не активна',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: StudioTheme.orangeWash,
            shape: BoxShape.circle,
            border: Border.all(
              color: StudioTheme.orange.withValues(alpha: connected ? .5 : .12),
              width: 1 + level.clamp(0, 1) * 4,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final height in [16.0, 32.0, 44.0, 25.0, 13.0])
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 5,
                  height: height + (connected ? level.clamp(0, 1) * 25 : 0),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: StudioTheme.orange,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _level(String label, double value, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            label,
            style: StudioTheme.label.copyWith(
              fontSize: 8,
              letterSpacing: 1.3,
              color: value > .015 ? color : StudioTheme.muted,
            ),
          ),
          const Spacer(),
          Icon(
            Icons.graphic_eq_rounded,
            size: 12,
            color: value > .015 ? color : StudioTheme.line,
          ),
        ],
      ),
      const SizedBox(height: 9),
      LinearProgressIndicator(
        value: (value * 4).clamp(0, 1),
        minHeight: 3,
        borderRadius: BorderRadius.circular(3),
        color: color,
        backgroundColor: StudioTheme.line,
      ),
    ],
  );

  Widget _transcript(String name, String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: StudioTheme.surface,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: StudioTheme.label.copyWith(fontSize: 9)),
        const SizedBox(height: 8),
        SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.6)),
      ],
    ),
  );

  Widget _task(BackgroundTask task) {
    final color = task.completed
        ? StudioTheme.green
        : task.status == 'Failed'
        ? StudioTheme.red
        : StudioTheme.orange;
    return _card(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                task.completed
                    ? Icons.check_circle_outline_rounded
                    : task.status == 'Failed'
                    ? Icons.error_outline
                    : Icons.hourglass_top_rounded,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 7),
              Text(
                task.status,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            task.title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.5,
            ),
          ),
          if (task.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                task.error!,
                style: const TextStyle(
                  fontSize: 12,
                  color: StudioTheme.muted,
                  height: 1.5,
                ),
              ),
            ),
          if (task.completed) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => controller.answer(task),
                  icon: const Icon(Icons.call_outlined, size: 14),
                  label: const Text('Обсудить'),
                ),
                TextButton(
                  onPressed: () => _result(task),
                  child: const Text('Читать результат'),
                ),
              ],
            ),
          ] else
            const SizedBox(height: 8),
        ],
      ),
    );
  }

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
              padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('ГОТОВЫЙ РЕЗУЛЬТАТ', style: StudioTheme.label),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Закрыть результат',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, size: 18),
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
                            style: StudioTheme.editorial.copyWith(fontSize: 29),
                          ),
                          const SizedBox(height: 22),
                          const Divider(height: 1),
                          const SizedBox(height: 22),
                          SelectableText(
                            result.result ?? 'Результат отсутствует',
                            style: const TextStyle(fontSize: 14, height: 1.8),
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

  Widget _incoming(BackgroundTask task) => Positioned.fill(
    child: ColoredBox(
      color: StudioTheme.ink.withValues(alpha: .45),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _card(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.call_received_rounded,
                        size: 15,
                        color: StudioTheme.orange,
                      ),
                      SizedBox(width: 8),
                      Text('ВХОДЯЩИЙ ЗВОНОК', style: StudioTheme.label),
                    ],
                  ),
                  const SizedBox(height: 30),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: StudioTheme.greenWash,
                      ),
                      child: const Icon(
                        Icons.task_alt_rounded,
                        size: 30,
                        color: StudioTheme.green,
                      ),
                    ),
                  ),
                  const SizedBox(height: 25),
                  Text(
                    'Результат готов',
                    style: StudioTheme.editorial.copyWith(fontSize: 36),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    task.title,
                    style: const TextStyle(
                      fontSize: 14,
                      color: StudioTheme.muted,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 26),
                  const Divider(height: 1),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: () => controller.answer(task),
                    icon: const Icon(Icons.call_outlined, size: 18),
                    label: const Text('Ответить'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: controller.later,
                    child: const Text('Позже'),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    '«Ответить» начнёт новый голосовой разговор',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: StudioTheme.muted,
                      height: 1.6,
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
