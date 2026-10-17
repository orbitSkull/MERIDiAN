import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/theme/app_theme.dart';

/// The app-bar theme button must flip what is on screen in one tap.
///
/// It previously cycled light -> dark -> system. The default is
/// ThemeMode.system, so on a light-mode phone the first tap moved system to
/// light, which already looked the same, and the user had to tap twice before
/// anything visibly changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The one-tap guarantee, checked from every starting mode against both
  /// possible platform brightnesses.
  group('one tap always flips what is displayed', () {
    final scenarios = <String, ({ThemeMode mode, Brightness platform})>{
      'system + light phone': (mode: ThemeMode.system, platform: Brightness.light),
      'system + dark phone': (mode: ThemeMode.system, platform: Brightness.dark),
      'light + light phone': (mode: ThemeMode.light, platform: Brightness.light),
      'light + dark phone': (mode: ThemeMode.light, platform: Brightness.dark),
      'dark + light phone': (mode: ThemeMode.dark, platform: Brightness.light),
      'dark + dark phone': (mode: ThemeMode.dark, platform: Brightness.dark),
    };

    scenarios.forEach((label, scenario) {
      testWidgets('$label flips after one tap', (tester) async {
        AppThemeMode.notifier.value = scenario.mode;

        await tester.pumpWidget(
          _Host(mode: scenario.mode, platform: scenario.platform),
        );
        final before = _brightnessOf(tester);

        await tester.tap(find.byIcon(Icons.brightness_6_outlined));
        await tester.pumpAndSettle();
        final after = _brightnessOf(tester);

        expect(
          after,
          isNot(before),
          reason: 'tapping from $label left the screen unchanged',
        );
      });
    });
  });

  group('toggle lands on an explicit mode', () {
    testWidgets('from system it picks the opposite of what is shown', (
      tester,
    ) async {
      // A light phone showing system: tapping should select dark, not light.
      AppThemeMode.notifier.value = ThemeMode.system;
      await tester.pumpWidget(
        const _Host(mode: ThemeMode.system, platform: Brightness.light),
      );
      expect(_brightnessOf(tester), Brightness.light);

      await tester.tap(find.byIcon(Icons.brightness_6_outlined));
      await tester.pumpAndSettle();

      expect(AppThemeMode.notifier.value, ThemeMode.dark);
    });

    testWidgets('from system on a dark phone it picks light', (tester) async {
      AppThemeMode.notifier.value = ThemeMode.system;
      await tester.pumpWidget(
        const _Host(mode: ThemeMode.system, platform: Brightness.dark),
      );
      expect(_brightnessOf(tester), Brightness.dark);

      await tester.tap(find.byIcon(Icons.brightness_6_outlined));
      await tester.pumpAndSettle();

      expect(AppThemeMode.notifier.value, ThemeMode.light);
    });

    testWidgets('the toggle never produces ThemeMode.system', (tester) async {
      for (final start in ThemeMode.values) {
        AppThemeMode.notifier.value = start;
        await tester.pumpWidget(
          _Host(mode: start, platform: Brightness.light),
        );
        await tester.tap(find.byIcon(Icons.brightness_6_outlined));
        await tester.pumpAndSettle();
        expect(
          AppThemeMode.notifier.value,
          isNot(ThemeMode.system),
          reason: 'starting from $start produced system again',
        );
      }
    });
  });

  group('mode decoding', () {
    test('unknown stored values fall back to system', () {
      expect(AppThemeMode.decodeMode('nonsense'), ThemeMode.system);
      expect(AppThemeMode.decodeMode(null), ThemeMode.system);
    });

    test('every mode round trips', () {
      for (final mode in ThemeMode.values) {
        expect(AppThemeMode.decodeMode(mode.name), mode);
      }
    });
  });
}

Brightness _brightnessOf(WidgetTester tester) {
  final context = tester.element(find.byIcon(Icons.brightness_6_outlined));
  return Theme.of(context).brightness;
}

/// Mirrors main.dart: a ValueListenableBuilder on AppThemeMode.notifier wraps
/// MaterialApp, so the rendered theme follows the notifier. Using a plain field
/// here instead would mean the toggle could never affect the output, and every
/// test below would fail for the wrong reason.
class _Host extends StatelessWidget {
  const _Host({required this.mode, required this.platform});

  final ThemeMode mode;
  final Brightness platform;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppThemeMode.notifier,
      builder: (context, current, _) {
        // The override must sit ABOVE MaterialApp. MaterialApp resolves
        // ThemeMode.system by reading MediaQuery.platformBrightness before its
        // own builder runs, so patching MediaQuery from inside that builder is
        // too late and system always resolves to light here.
        return MediaQuery(
          data: MediaQueryData(platformBrightness: platform),
          child: MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: current,
            home: Builder(
              builder: (context) => Scaffold(
                body: IconButton(
                  onPressed: () => AppThemeMode.toggle(
                    currentlyDark:
                        Theme.of(context).brightness == Brightness.dark,
                  ),
                  icon: const Icon(Icons.brightness_6_outlined),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}