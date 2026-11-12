import 'package:arcadiaplus/src/services/exit_ip_service.dart';

import 'dart:io';

import 'support/test_fonts.dart';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/widgets/adaptive_scaffold.dart';

import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/widgets/expressive_action.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:arcadiaplus/src/widgets/status_card.dart';
import 'package:arcadiaplus/src/widgets/routing_mode_selector.dart';
import 'package:arcadiaplus/src/widgets/traffic_chart.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_UI');
  setUpAll(() async {
    await loadAppFonts();
  });

  Widget app(
    Widget child, {
    bool reduced = false,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) => MaterialApp(
    theme: AppTheme.createTheme(AppTheme.defaultTheme, brightness),
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduced,
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );

  for (final (size, platform) in [
    (const Size(390, 844), TargetPlatform.android),
    (const Size(800, 1280), TargetPlatform.android),
    (const Size(1280, 800), TargetPlatform.android),
    (const Size(1440, 960), TargetPlatform.windows),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('expressive shell $size $brightness', (tester) async {
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
              locale: const Locale('zh', 'CN'),
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
              '.dart_tool/ui-previews/expressive-shell-${size.width.toInt()}-${brightness.name}.png',
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

  for (final width in [320.0, 480.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'traffic totals remain visible without horizontal clipping at $width / $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            app(
              TrafficChart(
                trafficStats: TrafficStats(
                  upload: BigInt.from(4096),
                  download: BigInt.from(8192),
                  uploadSpeed: BigInt.zero,
                  downloadSpeed: BigInt.zero,
                  directUpload: BigInt.from(1024),
                  directDownload: BigInt.from(2048),
                  proxyUpload: BigInt.from(3072),
                  proxyDownload: BigInt.from(6144),
                ),
                uploadSpeed: BigInt.zero,
                downloadSpeed: BigInt.zero,
                isProxyRunning: false,
              ),
              scale: scale,
            ),
          );
          await tester.pump();
          final labels = [
            'Download',
            'Upload',
            'Direct traffic',
            'Proxy traffic',
          ];
          for (final label in labels) {
            final finder = find.descendant(
              of: find.byKey(const ValueKey('traffic-totals-row')),
              matching: find.text(label),
            );
            expect(finder, findsOneWidget);
            final bounds = tester.getRect(finder);
            expect(bounds.left, greaterThanOrEqualTo(16));
            expect(bounds.right, lessThanOrEqualTo(width - 16));
          }
          expect(find.text('3.0 KB'), findsOneWidget);
          expect(find.text('9.0 KB'), findsOneWidget);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('status announces stopping and disables duplicate actions', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      app(
        StatusCard(
          isRunning: false,
          isLoading: false,
          onStartStop: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('service-toggle')));
    expect(taps, 1);
    await tester.pumpWidget(
      app(
        StatusCard(isRunning: true, isLoading: true, onStartStop: () => taps++),
        reduced: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stopping...'), findsNWidgets(2));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('service-toggle')))
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('running state settles without a permanent animation ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(StatusCard(isRunning: true, isLoading: false, onStartStop: () {})),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('service control supports keyboard activation', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      app(
        StatusCard(
          isRunning: false,
          isLoading: false,
          onStartStop: () => taps++,
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets(
    'all three routing modes are reachable and pending selection is disabled',
    (tester) async {
      var mode = ProxyMode.rule;
      await tester.pumpWidget(
        app(
          StatefulBuilder(
            builder: (context, setState) => RoutingModeSelector(
              mode: mode,
              onChanged: (next) => setState(() => mode = next),
            ),
          ),
        ),
      );
      for (final (label, value) in [
        ('Direct Mode', ProxyMode.direct),
        ('Global Proxy', ProxyMode.global),
        ('Rule Mode', ProxyMode.rule),
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(mode, value);
      }
      await tester.pumpWidget(app(RoutingModeSelector(mode: mode)));
      expect(
        tester
            .widgetList<ExpressiveAction>(find.byType(ExpressiveAction))
            .every((button) => button.onPressed == null),
        isTrue,
      );
    },
  );

  for (final width in [320.0, 430.0, 800.0, 1200.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('dashboard layout $width ${brightness.name}', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = _DashboardState();
        final network = _NetworkState();
        final settings = GeneralSettingsProvider();
        final boundary = GlobalKey();
        final scale = width == 320 ? 2.0 : 1.0;
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
            child: MaterialApp(
              theme: AppTheme.createTheme(AppTheme.defaultTheme, brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1000),
                  textScaler: TextScaler.linear(scale),
                ),
                child: RepaintBoundary(
                  key: boundary,
                  child: const HomeScreen(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '.dart_tool/ui-previews/dashboard-${width.toInt()}-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        state.dispose();
        network.dispose();
        settings.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('Chinese controls preserve readable layout at scale $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StatusCard(
                      isRunning: true,
                      isLoading: false,
                      onStartStop: () {},
                    ),
                    const SizedBox(height: 24),
                    RoutingModeSelector(
                      mode: ProxyMode.rule,
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('primary control meets touch target and contrast guidelines', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        app(StatusCard(isRunning: false, isLoading: false, onStartStop: () {})),
      );
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('leaving traffic page cancels deferred refresh safely', (
    tester,
  ) async {
    Widget chart(bool running) => app(
      TrafficChart(
        trafficStats: TrafficStats(
          directUpload: BigInt.zero,
          directDownload: BigInt.zero,
          proxyUpload: BigInt.zero,
          proxyDownload: BigInt.zero,
          upload: BigInt.zero,
          download: BigInt.zero,
          uploadSpeed: BigInt.zero,
          downloadSpeed: BigInt.zero,
        ),
        downloadSpeed: BigInt.zero,
        uploadSpeed: BigInt.zero,
        isProxyRunning: running,
      ),
    );
    await tester.pumpWidget(chart(false));
    await tester.pump();
    await tester.pumpWidget(chart(true));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
