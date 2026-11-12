import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/l10n/dashboard_strings.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';
import 'package:arcadiaplus/src/theme/palette_reference.dart';
import 'package:arcadiaplus/src/providers/theme_provider.dart';
import 'package:arcadiaplus/src/widgets/theme_picker.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('theme references fit large text in $locale', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = ThemeProvider();
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.createTheme('default', Brightness.light),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 900),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(body: ThemePicker(provider: provider)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PANTONE 286 C'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
    });
  }
  double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
  }

  test('every reference seed yields readable MD3 light and dark roles', () {
    expect(PaletteReference.values.keys, unorderedEquals(AppTheme.allThemes));
    for (final id in AppTheme.allThemes) {
      for (final brightness in Brightness.values) {
        final c = AppTheme.previewScheme(id, brightness);
        for (final (fg, bg) in [
          (c.onPrimary, c.primary),
          (c.onSecondary, c.secondary),
          (c.onTertiary, c.tertiary),
          (c.onSurface, c.surface),
          (c.onSurfaceVariant, c.surfaceContainerHigh),
          (c.onPrimaryContainer, c.primaryContainer),
        ]) {
          expect(
            contrast(fg, bg),
            greaterThanOrEqualTo(4.5),
            reason: '$id $brightness',
          );
        }
      }
    }
  });
  test('dashboard and palette copy covers every supported locale', () {
    final keys = dashboardStrings['en']!.keys;
    for (final locale in AppLocalizations.supportedLocales) {
      final name = locale.toString();
      final values = dashboardStrings[name]!;
      expect(values.keys, unorderedEquals(keys));
      expect(values.values.every((v) => v.trim().isNotEmpty), isTrue);
      final copy = AppLocalizations(locale);
      expect(copy.exitRiskScore(42), contains('42'));
      for (final id in AppTheme.allThemes) {
        expect(copy.paletteName(id), isNot(contains('palette_')));
      }
    }
    expect(AppLocalizations(const Locale('zh', 'TW')).exitMobile, '行動網路');
  });
}
