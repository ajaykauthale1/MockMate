import 'package:flutter/material.dart';

abstract final class SkeColors {
  static const background = Color(0xFF1C1B2E);
  static const panel = Color(0xFF252440);
  static const panelDark = Color(0xFF18172A);
  static const shadowLight = Color(0xFF3A3860);
  static const shadowDark = Color(0xFF08071A);
  static const accent = Color(0xFFD4A017);
  static const accentDim = Color(0xFF8A6A10);
  static const textPrimary = Color(0xFFEDE8D8);
  static const textSecondary = Color(0xFF9A96A8);
  static const userBubble = Color(0xFF2B3A60);
  static const aiBubble = Color(0xFF1E2840);
  static const mic = Color(0xFFBE3A3A);
}

BoxDecoration skeRaised({double radius = 12, Color? color}) => BoxDecoration(
      color: color ?? SkeColors.panel,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(
            color: SkeColors.shadowDark, offset: Offset(3, 3), blurRadius: 8),
        BoxShadow(
            color: SkeColors.shadowLight, offset: Offset(-2, -2), blurRadius: 5),
      ],
    );

BoxDecoration skeSunken({double radius = 12, Color? color}) => BoxDecoration(
      color: color ?? SkeColors.panelDark,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(
            color: SkeColors.shadowLight, offset: Offset(2, 2), blurRadius: 5),
        BoxShadow(
            color: SkeColors.shadowDark, offset: Offset(-2, -2), blurRadius: 5),
      ],
    );

ThemeData skeuomorphicTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: SkeColors.background,
      colorScheme: const ColorScheme.dark(
        surface: SkeColors.panel,
        primary: SkeColors.accent,
        onPrimary: SkeColors.panelDark,
        primaryContainer: SkeColors.userBubble,
        onPrimaryContainer: SkeColors.textPrimary,
        surfaceContainerHigh: SkeColors.aiBubble,
        onSurface: SkeColors.textPrimary,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: SkeColors.textPrimary, fontSize: 14),
        bodySmall: TextStyle(color: SkeColors.textSecondary, fontSize: 12),
        headlineMedium: TextStyle(
            color: SkeColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: SkeColors.accent, fontSize: 13),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: SkeColors.panelDark,
        foregroundColor: SkeColors.textPrimary,
        elevation: 4,
        shadowColor: SkeColors.shadowDark,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? SkeColors.accent
              : SkeColors.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? SkeColors.accentDim
              : SkeColors.shadowDark,
        ),
      ),
      useMaterial3: true,
    );
