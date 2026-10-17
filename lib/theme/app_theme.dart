import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppColors {
  const AppColors._();

  static const background = Color(0xFFF4F6FB);
  static const backgroundDark = Color(0xFF0F1222);
  static const primary = Color(0xFF4F46E5); // indigo-600
  static const primaryDark = Color(0xFF4338CA);
  static const dotInactive = Color(0xFFE5E7EB);
  static const surfaceDark = Color(0xFF171B31);

  // Raw palette. Referenced from theme definitions, and used directly by the
  // screens written before dark mode existed. Those screens hard-code a light
  // palette; migrating them to the *For resolvers below is a separate pass.
  static const ink = Color(0xFF111827);
  static const subtext = Color(0xFF6B7280);
  static const inkOnDark = Color(0xFFF3F4F6);
  static const subtextOnDark = Color(0xFF9CA3AF);

  /// Surface colour for cards and sheets, resolved for the current theme.
  ///
  /// The previous `AppColors.card` was a constant white, which rendered as a
  /// white slab on a dark background. Prefer the theme's cardTheme; this
  /// exists for places that need the colour rather than a Card.
  static Color cardFor(BuildContext context) => Theme.of(context).cardColor;

  /// Body text colour that contrasts with the current theme.
  static Color inkFor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? inkOnDark : ink;

  /// Muted text colour that contrasts with the current theme.
  static Color subtextFor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? subtextOnDark : subtext;
}

/// Global theme mode controller.
///
/// Supports three states, not two. [ThemeMode.system] is the sensible default
/// because it follows the phone's own setting, which a light/dark toggle
/// cannot express.
///
/// The previous implementation hard-coded light and never persisted, so a
/// user who chose dark got light again on every launch. [load] reads the
/// stored preference once at startup; [set] writes through on change.
class AppThemeMode {
  AppThemeMode._();

static final ValueNotifier<ThemeMode> notifier =
      ValueNotifier(ThemeMode.system);

  /// Set once the stored preference has been read, so the first frame does not
  /// flash the wrong theme before loading finishes.
  static bool _loaded = false;
  static ThemeMode _pending = ThemeMode.system;

  static ThemeMode get current => notifier.value;

  static bool get isLoaded => _loaded;

  /// Theme to use for the very first frame, before storage has been read.
  static ThemeMode get initial =>
      _loaded ? notifier.value : _pending;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key);
      _pending = decodeMode(stored);
    } catch (_) {
      // Storage unavailable (a test without a binding, or a corrupted store).
      // Falling back to following the system is always safe.
      _pending = ThemeMode.system;
    }
    notifier.value = _pending;
    _loaded = true;
  }

  static Future<void> set(ThemeMode mode) async {
    notifier.value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode.name);
    } catch (_) {
      // A failure to persist must not break the UI: the mode is already
      // applied in memory, so this only costs persistence until next launch.
    }
  }

  /// Flips between light and dark for the quick toggle in the app bar.
  ///
  /// [currentlyDark] must be the brightness actually being rendered, taken from
  /// `Theme.of(context).brightness`, not from [notifier].value.
  ///
  /// This was previously a three-state cycle (light -> dark -> system). That
  /// required two taps from the default, because the default is
  /// [ThemeMode.system]: on a light-mode phone system already *looks* light, so
  /// the first tap moved system to light and changed nothing on screen. The
  /// full three-way choice lives in the Appearance settings screen, which is
  /// where selecting "system" belongs; a one-button toggle should just flip
  /// what is currently visible.
  static Future<void> toggle({required bool currentlyDark}) {
    return set(currentlyDark ? ThemeMode.light : ThemeMode.dark);
  }

/// Inverse of [ThemeMode.name], as stored by [set].
///
/// Unknown or missing values fall back to [ThemeMode.system] rather than
/// throwing, so a corrupted preference cannot stop the app from starting.
@visibleForTesting
static ThemeMode decodeMode(String? stored) {
  for (final mode in ThemeMode.values) {
    if (mode.name == stored) return mode;
  }
  return ThemeMode.system;
}

  static const _key = 'meridian.theme_mode';
}

class AppTheme {
  const AppTheme._();

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(primary: AppColors.primary);

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: scheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: EdgeInsets.zero,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.subtext,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.subtext,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.subtext,
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
    ).copyWith(primary: AppColors.primary);

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.backgroundDark,
      colorScheme: scheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.backgroundDark,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      // Mirrors light() rather than relying on defaults. The dark theme used
      // to omit cardTheme, textButtonTheme and switchTheme entirely, so those
      // controls kept light-mode colours against a dark background.
      cardTheme: CardThemeData(
        color: AppColors.surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: EdgeInsets.zero,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.subtextOnDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.subtextOnDark,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.subtextOnDark,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: AppColors.surfaceDark,
      ),
    );
  }
}
