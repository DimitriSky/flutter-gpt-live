import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_theme.dart';

typedef _T = ConsoleTheme;

/// Built-in GPT-Live voices. Language notes follow the official voice guide;
/// voices without a note are general-purpose.
const voiceGroups = <(String, List<String>)>[
  (
    'Основные',
    [
      'marin',
      'cedar',
      'alloy',
      'ash',
      'ballad',
      'coral',
      'echo',
      'halo',
      'pearl',
      'sage',
      'shimmer',
      'verse',
    ],
  ),
  (
    'Английские',
    [
      'beacon',
      'cinder',
      'delta',
      'gleam',
      'meridian',
      'quartz',
      'ripple',
      'stone',
      'vesper',
      'willow',
    ],
  ),
  ('Другие', ['calandria', 'compas', 'destello', 'hornero', 'luciernaga']),
  ('Немецкий', ['flitz', 'juni', 'nuri']),
  ('Французский', ['brise', 'sillage']),
  ('Португальский', ['bossa', 'tempo']),
  ('Японский', ['harema', 'shida']),
  ('Корейский', ['noeul']),
  ('Хинди', ['nira']),
];

/// Voices accepted by Codex realtime v3 (CLI mode, `thread/realtime/listVoices`).
const cliVoiceGroups = <(String, List<String>)>[
  (
    'Голоса Codex · realtime v3',
    [
      'cove',
      'juniper',
      'maple',
      'spruce',
      'ember',
      'vale',
      'breeze',
      'arbor',
      'sol',
      'aube',
      'bubbie',
      'haetsal',
      'hanul',
      'himari',
      'leher',
      'miko',
      'neer',
      'porto',
      'rindo',
      'rio',
      'rivage',
      'selva',
      'sonna',
      'tinta',
      'viola',
    ],
  ),
];

String voiceLabel(String voice) =>
    voice.isEmpty ? voice : voice[0].toUpperCase() + voice.substring(1);

Widget _sheetHeader(BuildContext context, String label, {Widget? trailing}) =>
    Row(
      children: [
        Text(label, style: _T.label),
        const Spacer(),
        ?trailing,
        IconButton(
          tooltip: 'Закрыть',
          onPressed: () => Navigator.pop(context),
          style: IconButton.styleFrom(
            fixedSize: const Size(40, 40),
            backgroundColor: _T.body,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    );

// ─────────────────────────────── voice ───────────────────────────────

class VoiceSheet extends StatelessWidget {
  const VoiceSheet({
    super.key,
    required this.current,
    required this.live,
    this.groups = voiceGroups,
  });
  final String current;
  final bool live;
  final List<(String, List<String>)> groups;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sheetHeader(context, 'ГОЛОС АССИСТЕНТА'),
        const SizedBox(height: 6),
        Text(
          live
              ? 'Голос сменится прямо сейчас: разговор переподключится за пару секунд и продолжится с того же места. Таймер, лимит и расходы сохраняются.'
              : 'Голос задаётся при старте разговора. Языковые голоса настроены под свой язык — для русского лучше проверить на слух.',
          style: const TextStyle(fontSize: 12, color: _T.muted, height: 1.5),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            children: [
              for (final (group, voices) in groups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
                  child: Text(
                    group.toUpperCase(),
                    style: _T.label.copyWith(fontSize: 9),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final voice in voices)
                      _VoiceKey(
                        voice: voice,
                        selected: voice == current,
                        onTap: () => Navigator.pop(context, voice),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _VoiceKey extends StatelessWidget {
  const _VoiceKey({
    required this.voice,
    required this.selected,
    required this.onTap,
  });
  final String voice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? _T.ink : _T.body.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? _T.signal : _T.dotOff,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                voiceLabel(voice),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? _T.panel : _T.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SheetError extends StatelessWidget {
  const _SheetError(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _T.alertWash,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        message,
        style: const TextStyle(color: _T.alert, fontSize: 12, height: 1.5),
      ),
    ),
  );
}

// ─────────────────────── knowledge base & instructions ───────────────────────

/// What a [TextFileSheet] edits: the knowledge base or the instructions.
class TextFileKind {
  const TextFileKind({
    required this.field,
    required this.title,
    required this.liveHint,
    required this.idleHint,
    required this.note,
    required this.savedLive,
    required this.savedLivePartial,
    required this.savedLater,
    this.allowEmpty = false,
  });
  final String field, title, liveHint, idleHint, note;
  final String savedLive, savedLivePartial, savedLater;
  final bool allowEmpty;

  static const knowledge = TextFileKind(
    field: 'data',
    title: 'БАЗА ЗНАНИЙ · DATA.TXT',
    liveHint:
        'Разговор идёт. После сохранения ассистент сразу будет отвечать по новой базе.',
    idleHint:
        'Сохранённая база применится к следующему разговору и новым задачам.',
    note:
        'Ассистент и фоновые задачи получают этот текст целиком, как данные, а не как инструкции. Лимит — 48 KB.',
    savedLive:
        'База знаний сохранена и передана в текущий разговор — ассистент уже отвечает по ней.',
    savedLivePartial:
        'База знаний сохранена. В текущий разговор передана не полностью — целиком применится в следующем.',
    savedLater:
        'База знаний сохранена. Применится в следующем разговоре и новых задачах.',
    allowEmpty: true,
  );

  static const rules = TextFileKind(
    field: 'rules',
    title: 'ИНСТРУКЦИИ · RULES.MD',
    liveHint:
        'Разговор идёт. После сохранения ассистент сразу переключится на новые правила.',
    idleHint:
        'Сохранённые правила применятся к следующему разговору и новым задачам.',
    note:
        'Разделы с заголовками про знания, задачи, анализ или поиск получает backend; остальные — голос.',
    savedLive:
        'Инструкции сохранены и переданы в текущий разговор — ассистент уже следует им.',
    savedLivePartial:
        'Инструкции сохранены. Backend уже работает по ним; голосу передана только часть — полностью применятся в следующем разговоре.',
    savedLater: 'Инструкции сохранены. Применятся в следующем разговоре.',
  );
}

/// Editor for a backend text file (data.txt or rules.md). Returns a status
/// message after a successful save; a running call is updated immediately.
class TextFileSheet extends StatefulWidget {
  const TextFileSheet({
    super.key,
    required this.kind,
    required this.load,
    required this.save,
    required this.live,
  });
  final TextFileKind kind;
  final Future<Map<String, dynamic>> Function() load;
  final Future<Map<String, dynamic>> Function(String text) save;
  final bool live;

  @override
  State<TextFileSheet> createState() => _TextFileSheetState();
}

class _TextFileSheetState extends State<TextFileSheet> {
  final text = TextEditingController();
  String? original, error;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() {}));
    widget
        .load()
        .then((value) {
          if (!mounted) return;
          setState(() {
            original = value[widget.kind.field] as String? ?? '';
            text.text = original!;
          });
        })
        .catchError((Object e) {
          if (mounted) setState(() => error = e.toString());
        });
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  bool get dirty => original != null && text.text != original;

  Future<void> _save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await widget.save(text.text);
      if (!mounted) return;
      final applied = (result['applied_sessions'] as num?)?.toInt() ?? 0;
      final partial = result['partial'] == true;
      final codexThreads = (result['codex_threads'] as num?)?.toInt() ?? 0;
      final kind = widget.kind;
      Navigator.pop(
        context,
        applied > 0 || (kind.field == 'data' && codexThreads > 0 && widget.live)
            ? (partial ? kind.savedLivePartial : kind.savedLive)
            : kind.savedLater,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chars = text.text.length;
    final kb = utf8.encode(text.text).length / 1000;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        22,
        0,
        22,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sheetHeader(
            context,
            widget.kind.title,
            trailing: dirty
                ? Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      'ИЗМЕНЕНО',
                      style: _T.label.copyWith(fontSize: 9, color: _T.signal),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: widget.live ? _T.goWash : _T.body.withValues(alpha: .7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.live ? _T.go : _T.muted,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.live ? widget.kind.liveHint : widget.kind.idleHint,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: widget.live ? _T.go : _T.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.kind.note,
            style: const TextStyle(fontSize: 11, color: _T.muted, height: 1.45),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: original == null && error == null
                ? const Center(child: CircularProgressIndicator())
                : original == null
                ? _SheetError(error!)
                : TextField(
                    controller: text,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    style: _T.mono.copyWith(fontSize: 13, height: 1.55),
                    decoration: InputDecoration(
                      fillColor: _T.panel,
                      contentPadding: const EdgeInsets.all(16),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: _T.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: _T.signal,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
          ),
          if (error != null && original != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: const TextStyle(color: _T.alert, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Text(
            '$chars СИМВ. · ${kb.toStringAsFixed(1)} / 48 KB',
            style: _T.label.copyWith(
              fontSize: 9,
              color: kb > 48 ? _T.alert : _T.muted,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (dirty)
                TextButton(
                  onPressed: saving ? null : () => text.text = original!,
                  child: const Text('Отменить правки'),
                ),
              const SizedBox(width: 8),
              Flexible(
                child: FilledButton.icon(
                  onPressed:
                      dirty &&
                          !saving &&
                          utf8.encode(text.text).length <= 48000 &&
                          (widget.kind.allowEmpty ||
                              text.text.trim().isNotEmpty)
                      ? _save
                      : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    backgroundColor: widget.live ? _T.go : _T.signal,
                  ),
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          widget.live
                              ? Icons.bolt_rounded
                              : Icons.check_rounded,
                          size: 18,
                        ),
                  label: Text(
                    widget.live ? 'Применить' : 'Сохранить',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
