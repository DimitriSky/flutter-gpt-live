import 'package:flutter/material.dart';

/// "Console" — a hardware-inspired style: warm aluminium body, dark LCD
/// display, a speaker-grille visualiser, one signal-orange accent and
/// monospaced engraved labels.
abstract final class ConsoleTheme {
  // Body
  static const body = Color(0xffe6e4df);
  static const panel = Color(0xfff5f4f0);
  static const ink = Color(0xff1d1d1b);
  static const muted = Color(0xff77746c);
  static const line = Color(0xffd3d0c8);
  static const dotOff = Color(0xffcfccc4);

  // Display / dark deck
  static const deck = Color(0xff1d1d1b);
  static const deckRaised = Color(0xff2a2a27);
  static const deckText = Color(0xffece9e2);
  static const deckMuted = Color(0xff8b887f);
  static const deckLine = Color(0xff3a3935);

  // Signals
  static const signal = Color(0xffee5a1f);
  static const signalWash = Color(0xfffbe6dc);
  static const go = Color(0xff2f8f5b);
  static const goWash = Color(0xffdfeee4);
  static const alert = Color(0xffc8372d);
  static const alertWash = Color(0xfff6e0dd);

  static const mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Roboto Mono', 'SF Mono', 'monospace', 'Courier'],
    fontFeatures: [FontFeature.tabularFigures()],
    color: ink,
  );

  /// Small engraved label, e.g. "01 / РАЗГОВОР".
  static final label = mono.copyWith(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4,
    color: muted,
  );

  static const headline = TextStyle(
    fontWeight: FontWeight.w700,
    letterSpacing: -1.1,
    height: 1.05,
    color: ink,
  );

  static List<BoxShadow> get raised => const [
    BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0d000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: signal,
          brightness: Brightness.light,
          surface: panel,
        ).copyWith(
          primary: signal,
          onPrimary: Colors.white,
          secondary: go,
          onSurface: ink,
          onSurfaceVariant: muted,
          outline: line,
          error: alert,
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final key = base.textTheme.labelLarge!.copyWith(
      fontWeight: FontWeight.w700,
    );
    final keyShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return base.copyWith(
      scaffoldBackgroundColor: body,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      dividerColor: line,
      iconTheme: const IconThemeData(color: ink, size: 20),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: signal,
          foregroundColor: Colors.white,
          disabledBackgroundColor: line,
          disabledForegroundColor: muted,
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          shape: keyShape,
          elevation: 0,
          textStyle: key.copyWith(fontSize: 14, letterSpacing: .2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          disabledForegroundColor: muted.withValues(alpha: .6),
          minimumSize: const Size(0, 50),
          side: const BorderSide(color: line, width: 1.5),
          shape: keyShape,
          textStyle: key.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: key.copyWith(fontSize: 12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: body.withValues(alpha: .55),
        labelStyle: label.copyWith(fontSize: 11, letterSpacing: .6),
        floatingLabelStyle: label.copyWith(
          fontSize: 11,
          letterSpacing: .6,
          color: signal,
        ),
        hintStyle: const TextStyle(color: muted, fontSize: 13, height: 1.5),
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: signal, width: 1.5),
        ),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        shape: Border(),
        collapsedShape: Border(),
        iconColor: muted,
        collapsedIconColor: muted,
        childrenPadding: EdgeInsets.only(bottom: 16),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: line,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: signal),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    );
  }
}
