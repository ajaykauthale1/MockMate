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
  background:    Color(0xFFF8FAFC), // Slate 50
  panel:         Color(0xFFF1F5F9), // Slate 100
  panelDark:     Color(0xFFE2E8F0), // Slate 200
  textPrimary:   Color(0xFF0F172A), // Slate 900
  textSecondary: Color(0xFF64748B), // Slate 500
  accent:        Color(0xFF2563EB), // Blue 600
  accentDim:     Color(0xFF3B82F6), // Blue 500
  userBubble:    Color(0xFFE2E8F0), // Slate 200
  aiBubble:      Color(0xFFFFFFFF), // White
  mic:           Color(0xFFF43F5E), // Rose 500
  borderLight:   Color(0xFFE2E8F0), // Slate 200
  borderMedium:  Color(0xFFCBD5E1), // Slate 300
  shadow:        Color(0x0F000000), // 6% black
);

const darkColors = AppColors(
  background:    Color(0xFF0F172A), // Slate 900
  panel:         Color(0xFF1E293B), // Slate 800
  panelDark:     Color(0xFF0F172A), // Slate 900
  textPrimary:   Color(0xFFF8FAFC), // Slate 50
  textSecondary: Color(0xFF94A3B8), // Slate 400
  accent:        Color(0xFF3B82F6), // Blue 500
  accentDim:     Color(0xFF60A5FA), // Blue 400
  userBubble:    Color(0xFF334155), // Slate 700
  aiBubble:      Color(0xFF1E293B), // Slate 800
  mic:           Color(0xFFFB7185), // Rose 400
  borderLight:   Color(0xFF334155), // Slate 700
  borderMedium:  Color(0xFF475569), // Slate 600
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
  static const background    = Color(0xFFF8FAFC);
  static const panel         = Color(0xFFF1F5F9);
  static const panelDark     = Color(0xFFE2E8F0);
  static const textPrimary   = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);
  static const accent        = Color(0xFF2563EB);
  static const accentDim     = Color(0xFF3B82F6);
  static const userBubble    = Color(0xFFE2E8F0);
  static const aiBubble      = Color(0xFFFFFFFF);
  static const mic           = Color(0xFFF43F5E);
  static const borderLight   = Color(0xFFE2E8F0);
  static const borderMedium  = Color(0xFFCBD5E1);
  static const shadowDark    = borderLight;
  static const shadowLight   = borderMedium;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable AppBar theme toggle button
// ─────────────────────────────────────────────────────────────────────────────

class ThemeToggleButton extends ConsumerWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.appColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      icon: Icon(
        isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
        color: c.textSecondary,
      ),
      tooltip: isDark ? 'Light mode' : 'Dark mode',
      onPressed: () {
        ref.read(themeModeProvider.notifier).state =
            isDark ? ThemeMode.light : ThemeMode.dark;
      },
    );
  }
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
