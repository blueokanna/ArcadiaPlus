import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/profiles_provider.dart';
import 'package:arcadiaplus/src/screens/profiles_screen.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/test_fonts.dart';

class _Profiles extends ChangeNotifier implements ProfilesProvider {
  @override
  final profiles = List.generate(
    3,
    (index) => ProfileConfig(
      id: '$index',
      name: '华为平板与手机共用的长名称订阅配置 $index',
      type: 'url',
      source: 'https://example.invalid/subscription',
      lastUpdated: DateTime(2026, 11, 11),
      expiresAt: DateTime(2027, 11, 11),
      usedTraffic: index * 1024,
      totalTraffic: index == 0 ? 0 : 512,
    ),
  );
  @override
  String get activeProfileId => '0';
  @override
  bool get isLoading => false;
  @override
  Future<void> loadProfiles() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadAppFonts);
  for (final size in [
    const Size(320, 800),
    const Size(1200, 800),
    const Size(740, 360),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('profile layout and import panel at $size / $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final profiles = _Profiles();
        addTearDown(profiles.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<ProfilesProvider>.value(
            value: profiles,
            child: MaterialApp(
              theme: AppTheme.createTheme(
                AppTheme.defaultTheme,
                Brightness.light,
              ),
              locale: const Locale('zh', 'CN'),
              supportedLocales: AppLocalizations.supportedLocales,
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
              home: const ProfilesScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final progress in tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )) {
          expect(progress.value, inInclusiveRange(0.0, 1.0));
        }
        final first = find.text(profiles.profiles[0].name);
        final second = find.text(profiles.profiles[1].name);
        if (size.width >= 840 && scale == 1) {
          expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
          expect(
            tester.getTopLeft(second).dx,
            greaterThan(tester.getTopLeft(first).dx),
          );
        }
        await tester.tap(find.byIcon(Icons.add).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byIcon(Icons.content_paste));
        expect(
          tester.getRect(find.byIcon(Icons.content_paste)).bottom,
          lessThan(size.height),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
