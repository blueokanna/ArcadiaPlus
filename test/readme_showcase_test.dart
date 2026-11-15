import 'package:arcadiaplus/src/services/exit_ip_service.dart';

import 'dart:io';

import 'support/test_fonts.dart';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/widgets/adaptive_scaffold.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/providers/network_settings_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/screens/home_screen.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';

// UI fixtures do not initialize a core, change OS proxy settings or use profiles.
class _DashboardState extends ChangeNotifier implements AppStateProvider {
  @override
  String? get serviceError => null;
  @override
  bool get isServiceRunning => false;
  @override
  bool get isLoading => false;
  @override
  ProxyMode get proxyMode => ProxyMode.rule;
  @override
  ProxyStatus? get proxyStatus => null;
  @override
  SystemInfo? get systemInfo => null;
  @override
  TrafficStats? get trafficStats => null;
  @override
  BigInt get currentDownloadSpeed => BigInt.zero;
  @override
  BigInt get currentUploadSpeed => BigInt.zero;
  @override
  Future<void> refreshStatus() async {}
  @override
  void retainLiveStats() {}
  @override
  void releaseLiveStats() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NetworkState extends ChangeNotifier implements NetworkSettingsProvider {
  @override
  bool get tunEnabled => false;
  @override
  bool get systemProxy => false;
  @override
  Future<void> refresh() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Render current production widgets with an idle, offline state. These images
// document layout; they do not certify native networking or OS integration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_UI');
  const language = String.fromEnvironment(
    'SHOWCASE_LOCALE',
    defaultValue: 'en',
  );
  setUpAll(loadAppFonts);
  for (final (label, size, platform) in [
    ('android', const Size(412, 915), TargetPlatform.android),
    ('ios', const Size(390, 844), TargetPlatform.iOS),
    ('windows', const Size(1440, 960), TargetPlatform.windows),
    ('macos', const Size(1440, 960), TargetPlatform.macOS),
    ('linux', const Size(1440, 960), TargetPlatform.linux),
    ('tablet', const Size(1024, 1366), TargetPlatform.android),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('README $label $language ${brightness.name}', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        debugDefaultTargetPlatformOverride = platform;
        final previousShadows = debugDisableShadows;
        if (capture) debugDisableShadows = false;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        addTearDown(() => debugDisableShadows = previousShadows);
        final state = _DashboardState();
        final network = _NetworkState();
        final settings = GeneralSettingsProvider();
        final boundary = GlobalKey();
        final router = GoRouter(
          routes: [
            ShellRoute(
              builder: (_, _, child) => AdaptiveScaffold(body: child),
              routes: [
                GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
                for (final path in [
                  '/proxies',
                  '/profiles',
                  '/connections',
                  '/logs',
                  '/settings',
                ])
                  GoRoute(
                    path: path,
                    builder: (_, _) => Center(child: Text(path)),
                  ),
              ],
            ),
          ],
        );
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => ExitIpController()),
              ChangeNotifierProvider<AppStateProvider>.value(value: state),
              ChangeNotifierProvider<NetworkSettingsProvider>.value(
                value: network,
              ),
              ChangeNotifierProvider<GeneralSettingsProvider>.value(
                value: settings,
              ),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.createTheme(
                AppTheme.defaultTheme,
                brightness,
              ).copyWith(platform: platform),
              locale: Locale(language),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) =>
                  RepaintBoundary(key: boundary, child: child!),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('floating-navigation')),
          size.width < 600 ? findsOneWidget : findsNothing,
        );
        if (capture) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final file = File(
              'docs/images/$label-$language-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        state.dispose();
        network.dispose();
        settings.dispose();
        router.dispose();
        debugDefaultTargetPlatformOverride = null;
        debugDisableShadows = previousShadows;
      });
    }
  }
}
