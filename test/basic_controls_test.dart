import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/screens/basic_config_screen.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/capture_ui.dart';
import 'support/test_fonts.dart';

class _State extends ChangeNotifier implements AppStateProvider {
  @override
  ProxyMode get proxyMode => ProxyMode.rule;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadAppFonts);
  for (final scale in [1.0, 2.0]) {
    testWidgets('Chinese mode and log pickers stay compact at scale $scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(363, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _State();
      final settings = GeneralSettingsProvider();
      addTearDown(state.dispose);
      addTearDown(settings.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppStateProvider>.value(value: state),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundary,
              child: const BasicConfigScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(DropdownMenu<String>).first,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final field = find.descendant(
        of: find.byType(DropdownMenu<String>).first,
        matching: find.byType(TextField),
      );
      expect(tester.getSize(field).width, 120);
      if (scale == 1) {
        expect(tester.getSize(field).height, lessThanOrEqualTo(56));
      }
      await captureTestUi(tester, boundary, 'basic-controls-$scale');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
