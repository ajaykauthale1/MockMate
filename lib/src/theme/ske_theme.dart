import 'package:flutter/material.dart';

abstract final class SkeColors {
  // Surfaces — warm cream scale
  static const background  = Color(0xFFF2F1ED); // page bg
  static const panel       = Color(0xFFE6E5E0); // card / container
  static const panelDark   = Color(0xFFEBEAE5); // button / input bg

  // Text
  static const textPrimary   = Color(0xFF26251E); // warm near-black
  static const textSecondary = Color(0x8C26251E); // 55% warm brown

  // Accent
  static const accent    = Color(0xFFF54E00); // cursor orange
  static const accentDim = Color(0xFFC08532); // gold secondary

  // Bubbles
  static const userBubble = Color(0xFFEBEAE5); // surface 300
  static const aiBubble   = Color(0xFFF7F7F4); // surface 100

  // Semantic
  static const mic   = Color(0xFFCF2D56); // warm crimson (active / error)
  static const error = Color(0xFFCF2D56);

  // Border helpers (rgba(38,37,30,alpha) as const Color)
  static const borderLight  = Color(0x1A26251E); // 10% warm brown
  static const borderMedium = Color(0x3326251E); // 20% warm brown

  // Legacy aliases — used in widget files for borders/dividers/hints.
  static const shadowDark  = borderLight;   // thin dividers & borders
  static const shadowLight = borderMedium;  // slightly visible borders & hints
}

/// Elevated card / raised surface — flat with border + soft shadow.
BoxDecoration skeRaised({double radius = 8, Color? color}) => BoxDecoration(
      color: color ?? SkeColors.panel,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: SkeColors.borderLight, width: 1),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0F000000), // 6% black
          offset: Offset(0, 2),
          blurRadius: 8,
        ),
      ],
    );

/// Sunken / input surface — slightly lighter, border, no shadow.
BoxDecoration skeSunken({double radius = 8, Color? color}) => BoxDecoration(
      color: color ?? SkeColors.panelDark,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: SkeColors.borderLight, width: 1),
    );

ThemeData skeuomorphicTheme() => ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: SkeColors.background,
      colorScheme: const ColorScheme.light(
        surface: SkeColors.panel,
        primary: SkeColors.accent,
        onPrimary: Colors.white,
        primaryContainer: SkeColors.userBubble,
        onPrimaryContainer: SkeColors.textPrimary,
        surfaceContainerHigh: SkeColors.aiBubble,
        onSurface: SkeColors.textPrimary,
        error: SkeColors.error,
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
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: SkeColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        shape: Border(
          bottom: BorderSide(color: SkeColors.borderLight, width: 1),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? SkeColors.accent
              : SkeColors.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? const Color(0x33F54E00) // accent 20%
              : SkeColors.borderMedium,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: SkeColors.borderLight,
        thickness: 1,
        space: 1,
      ),
      useMaterial3: true,
    );
