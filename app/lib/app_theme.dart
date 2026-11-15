import 'package:flutter/material.dart';

abstract final class StudioTheme {
  static const paper = Color(0xfff3f0e8);
  static const surface = Color(0xfffffdf8);
  static const ink = Color(0xff292a24);
  static const muted = Color(0xff76766b);
  static const line = Color(0xffdddcd1);
  static const orange = Color(0xffb84a27);
  static const orangeWash = Color(0xfff7e9de);
  static const green = Color(0xff476451);
  static const greenWash = Color(0xffe8eee5);
  static const red = Color(0xffa33732);

  static const editorial = TextStyle(
    fontFamily: 'Georgia',
    fontFamilyFallback: ['Noto Serif', 'serif'],
    fontWeight: FontWeight.w400,
    letterSpacing: -1.2,
    height: 1.12,
    color: ink,
  );
  static const label = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.7,
    color: muted,
  );

  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: orange,
          brightness: Brightness.light,
          surface: surface,
        ).copyWith(
          primary: orange,
          onPrimary: Colors.white,
          secondary: green,
          onSurface: ink,
          onSurfaceVariant: muted,
          outline: line,
          error: red,
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: paper,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      dividerColor: line,
      iconTheme: const IconThemeData(color: ink, size: 20),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: surface,
          disabledBackgroundColor: line,
          disabledForegroundColor: muted,
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(0, 48),
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: orange,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        labelStyle: const TextStyle(color: muted, fontSize: 13),
        hintStyle: const TextStyle(color: muted, fontSize: 13, height: 1.5),
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: orange, width: 1.5),
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
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    );
  }
}
