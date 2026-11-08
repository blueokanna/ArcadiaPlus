import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/providers/proxies_provider.dart';
import 'package:arcadiaplus/src/providers/theme_provider.dart';
import 'package:arcadiaplus/src/screens/logs_screen.dart';
import 'package:arcadiaplus/src/screens/proxies_screen.dart';
import 'package:arcadiaplus/src/services/log_source.dart';
import 'package:arcadiaplus/src/widgets/proxy_node_tile.dart';
import 'package:arcadiaplus/src/widgets/theme_picker.dart';
import 'package:arcadiaplus/src/widgets/connection_destination.dart';
import 'package:arcadiaplus/src/widgets/dns_status_card.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';

import 'support/proxy_engine_fake.dart';

class MemoryLogs implements LogSource {
  List<String> lines = ['[INFO] first', '[WARN] second'];
  Completer<List<String>>? pending;
  bool failClear = false;
  int reads = 0;
  int clears = 0;
  @override
  Future<List<String>> read() async {
    reads++;
    return pending?.future ?? List<String>.of(lines);
  }

  @override
  Future<void> clear() async {
    clears++;
    if (failClear) throw StateError('clear failed');
    lines = [];
  }
}

class LayoutProxies extends ProxiesProvider {
  LayoutProxies(FakeEngine engine) : super(engine: engine);
  @override
  Future<void> loadFromActiveProfile() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reported domain appears above the actual destination IP', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionDestination(
            host: 'api.bilibili.com',
            ip: '203.0.113.7',
            port: 443,
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('api.bilibili.com')).dy,
      lessThan(tester.getTopLeft(find.text('203.0.113.7:443')).dy),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionDestination(host: '2001:db8::7', port: 443),
        ),
      ),
    );
    expect(find.text('[2001:db8::7]:443'), findsOneWidget);
    expect(find.text('api.bilibili.com'), findsNothing);
  });

  testWidgets('DNS statistics use core values and polling stops on disposal', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DnsStatusCard(
            readStatus: () async {
              reads++;
              return RecursiveDnsStatus(
                running: true,
                listen: '127.0.0.1:5353',
                queries: BigInt.from(42),
                cacheHits: BigInt.from(31),
                upstreamQueries: BigInt.from(18),
                failures: BigInt.one,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Queries 42'), findsOneWidget);
    expect(find.text('Cache hits 31'), findsOneWidget);
    expect(find.text('Upstream queries 18'), findsOneWidget);
    expect(find.text('Failures 1'), findsOneWidget);
    expect(
      find.textContaining('does not validate an anchored DNSSEC chain'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    expect(reads, 2);
  });

  testWidgets(
    'late theme load cannot overwrite a selection or notify after disposal',
    (tester) async {
      final provider = ThemeProvider();
      final selected = provider.availableThemes.last;
      provider.setTheme(selected);
      await tester.pump();
      expect(provider.selectedTheme, selected);
      provider.dispose();
      ThemeProvider().dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clear removes the source and filtered cache; polling cannot resurrect it',
    (tester) async {
      final source = MemoryLogs();
      await tester.pumpWidget(MaterialApp(home: LogsScreen(source: source)));
      await tester.pumpAndSettle();
      expect(find.text('[INFO] first'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(source.clears, 1);
      expect(find.text('[INFO] first'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('[INFO] first'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late refresh cannot repopulate cleared logs', (tester) async {
    final source = MemoryLogs()..pending = Completer<List<String>>();
    await tester.pumpWidget(MaterialApp(home: LogsScreen(source: source)));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    source.pending!.complete(['stale snapshot']);
    await tester.pumpAndSettle();
    expect(find.text('stale snapshot'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'manual refresh and pause are observable; clear errors preserve logs',
    (tester) async {
      final source = MemoryLogs();
      await tester.pumpWidget(MaterialApp(home: LogsScreen(source: source)));
      await tester.pumpAndSettle();
      source.lines.add('[INFO] fresh');
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.text('[INFO] fresh'), findsOneWidget);
      expect(find.text('Logs refreshed'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pump();
      final reads = source.reads;
      await tester.pump(const Duration(seconds: 4));
      expect(source.reads, reads);
      source.failClear = true;
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('[INFO] fresh'), findsOneWidget);
      expect(find.textContaining('clear failed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('empty initial log source finishes loading', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LogsScreen(source: MemoryLogs()..lines = [])),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('manual refresh during polling queues a fresh source read', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    final source = MemoryLogs()..pending = pending;
    await tester.pumpWidget(MaterialApp(home: LogsScreen(source: source)));
    await tester.tap(find.byIcon(Icons.refresh));
    source.pending = null;
    source.lines = ['new snapshot'];
    pending.complete(['old snapshot']);
    await tester.pumpAndSettle();
    expect(source.reads, 2);
    expect(find.text('new snapshot'), findsOneWidget);
    expect(find.text('Logs refreshed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'phone supports persistent two-column node layout at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(380, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final engine = FakeEngine();
        final provider = LayoutProxies(engine)..loadFromYaml(config(4));
        final boundary = GlobalKey();
        Widget screen(Key key) => ChangeNotifierProvider<ProxiesProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark),
            key: key,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: RepaintBoundary(key: boundary, child: const ProxiesScreen()),
          ),
        );
        await tester.pumpWidget(screen(const ValueKey(1)));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Node layout'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Two columns'));
        await tester.pumpAndSettle();
        final tiles = find.byType(ProxyNodeTile);
        expect(
          tester.getTopLeft(tiles.at(0)).dy,
          tester.getTopLeft(tiles.at(1)).dy,
        );
        expect(
          tester.getTopLeft(tiles.at(0)).dx,
          lessThan(tester.getTopLeft(tiles.at(1)).dx),
        );
        expect(
          (await SharedPreferences.getInstance()).getInt('proxy_node_columns'),
          2,
        );
        await tester.pumpWidget(screen(const ValueKey(2)));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(tiles.at(0)).dy,
          tester.getTopLeft(tiles.at(1)).dy,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, boundary, 'two-columns-$scale');
        await tester.pumpWidget(const SizedBox.shrink());
        provider.dispose();
        engine.dispose();
      },
    );

    testWidgets('theme previews fit narrow screens at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = ThemeProvider();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(body: ThemePicker(provider: provider)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Forest Green'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, boundary, 'theme-picker-$scale');
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
    });
  }
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.dart_tool/ui-previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
