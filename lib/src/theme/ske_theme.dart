import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Theme mode provider — persists across the app via Riverpod
// ─────────────────────────────────────────────────────────────────────────────

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.light);

// ─────────────────────────────────────────────────────────────────────────────
// AppColors — one instance per theme variant
// ─────────────────────────────────────────────────────────────────────────────

class AppColors {
  final Color background;
  final Color panel;
  final Color panelDark;
  final Color textPrimary;
  final Color textSecondary;
  final Color accent;
  final Color accentDim;
  final Color userBubble;
  final Color aiBubble;
  final Color mic;
  final Color borderLight;
  final Color borderMedium;
  final Color _shadow;

  // Legacy aliases — used in a few widget files
  Color get shadowDark  => borderLight;
  Color get shadowLight => borderMedium;

  const AppColors({
    required this.background,
    required this.panel,
    required this.panelDark,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.accentDim,
    required this.userBubble,
    required this.aiBubble,
    required this.mic,
    required this.borderLight,
    required this.borderMedium,
    required Color shadow,
  }) : _shadow = shadow;

  BoxDecoration raised({double radius = 8, Color? color}) => BoxDecoration(
        color: color ?? panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderLight, width: 1),
        boxShadow: [
          BoxShadow(
              color: _shadow, offset: const Offset(0, 2), blurRadius: 8),
        ],
      );

  BoxDecoration sunken({double radius = 8, Color? color}) => BoxDecoration(
        color: color ?? panelDark,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderLight, width: 1),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Palette instances
// ─────────────────────────────────────────────────────────────────────────────

const lightColors = AppColors(
  background:    Color(0xFFF2F1ED), // warm cream
  panel:         Color(0xFFE6E5E0), // surface-400
  panelDark:     Color(0xFFEBEAE5), // surface-300
  textPrimary:   Color(0xFF26251E), // warm near-black
  textSecondary: Color(0x8C26251E), // 55% warm brown
  accent:        Color(0xFFF54E00), // cursor orange
  accentDim:     Color(0xFFC08532),
  userBubble:    Color(0xFFEBEAE5),
  aiBubble:      Color(0xFFF7F7F4), // surface-100
  mic:           Color(0xFFCF2D56),
  borderLight:   Color(0x1A26251E), // 10% warm brown
  borderMedium:  Color(0x3326251E), // 20% warm brown
  shadow:        Color(0x0F000000), // 6% black
);

const darkColors = AppColors(
  background:    Color(0xFF1C1B2E),
  panel:         Color(0xFF252440),
  panelDark:     Color(0xFF18172A),
  textPrimary:   Color(0xFFEDE8D8),
  textSecondary: Color(0x8CEDE8D8), // 55% warm light
  accent:        Color(0xFFF54E00), // same orange
  accentDim:     Color(0xFFC08532),
  userBubble:    Color(0xFF2B3A60),
  aiBubble:      Color(0xFF1E2840),
  mic:           Color(0xFFCF2D56),
  borderLight:   Color(0x14FFFFFF), //  8% white
  borderMedium:  Color(0x26FFFFFF), // 15% white
  shadow:        Color(0x1A000000), // 10% black
);

// ─────────────────────────────────────────────────────────────────────────────
// Context extension — use this everywhere in build()
// ─────────────────────────────────────────────────────────────────────────────

extension AppColorsX on BuildContext {
  AppColors get appColors =>
      Theme.of(this).brightness == Brightness.dark ? darkColors : lightColors;
}

// ─────────────────────────────────────────────────────────────────────────────
// Backward-compat statics (light values) — used in ThemeData and any const
// context that hasn't been migrated yet
// ─────────────────────────────────────────────────────────────────────────────

abstract final class SkeColors {
  static const background    = Color(0xFFF2F1ED);
  static const panel         = Color(0xFFE6E5E0);
  static const panelDark     = Color(0xFFEBEAE5);
  static const textPrimary   = Color(0xFF26251E);
  static const textSecondary = Color(0x8C26251E);
  static const accent        = Color(0xFFF54E00);
  static const accentDim     = Color(0xFFC08532);
  static const userBubble    = Color(0xFFEBEAE5);
  static const aiBubble      = Color(0xFFF7F7F4);
  static const mic           = Color(0xFFCF2D56);
  static const borderLight   = Color(0x1A26251E);
  static const borderMedium  = Color(0x3326251E);
  static const shadowDark    = borderLight;
  static const shadowLight   = borderMedium;
}

// ─────────────────────────────────────────────────────────────────────────────
// Free-function shims — kept only for any call sites not yet migrated.
// Prefer context.appColors.raised() / .sunken() in new code.
// ─────────────────────────────────────────────────────────────────────────────

BoxDecoration skeRaised({double radius = 8, Color? color}) =>
    lightColors.raised(radius: radius, color: color);

BoxDecoration skeSunken({double radius = 8, Color? color}) =>
    lightColors.sunken(radius: radius, color: color);

// ─────────────────────────────────────────────────────────────────────────────
// ThemeData factories
// ─────────────────────────────────────────────────────────────────────────────

ThemeData skeuomorphicTheme() => _buildTheme(lightColors, Brightness.light);
ThemeData skeuomorphicDarkTheme() => _buildTheme(darkColors, Brightness.dark);

ThemeData _buildTheme(AppColors c, Brightness brightness) => ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: c.background,
      colorScheme: ColorScheme(
        brightness: brightness,
        surface: c.panel,
        primary: c.accent,
        onPrimary: brightness == Brightness.dark ? c.panelDark : Colors.white,
        primaryContainer: c.userBubble,
        onPrimaryContainer: c.textPrimary,
        surfaceContainerHigh: c.aiBubble,
        onSurface: c.textPrimary,
        error: c.mic,
        onError: Colors.white,
        secondary: c.accentDim,
        onSecondary: c.textPrimary,
      ),
      textTheme: TextTheme(
        bodyMedium: TextStyle(color: c.textPrimary, fontSize: 14),
        bodySmall:  TextStyle(color: c.textSecondary, fontSize: 12),
        headlineMedium: TextStyle(
            color: c.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: c.accent, fontSize: 13),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.panelDark,
        foregroundColor: c.textPrimary,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: c.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        shape: Border(bottom: BorderSide(color: c.borderLight, width: 1)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? c.accent.withValues(alpha: 0.3)
              : c.borderMedium,
        ),
      ),
      dividerTheme: DividerThemeData(
          color: c.borderLight, thickness: 1, space: 1),
      useMaterial3: true,
    );
