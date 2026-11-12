import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/dns_activity_service.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/widgets/dns_activity_panel.dart';

import 'support/capture_ui.dart';
import 'support/test_fonts.dart';

import 'package:arcadiaplus/src/theme/app_theme.dart';

RecursiveDnsStatus get _status => RecursiveDnsStatus(
  running: true,
  listen: '127.0.0.1:5353',
  queries: BigInt.from(99),
  cacheHits: BigInt.from(40),
  upstreamQueries: BigInt.from(80),
  failures: BigInt.one,
);

DnsQueryEvent event(
  String domain,
  int id, {
  bool cached = false,
  String outcome = 'NOERROR',
}) => DnsQueryEvent(
  id: BigInt.from(id),
  completedAtMs: BigInt.from(1794373200000),
  domain: domain,
  queryType: 'AAAA',
  path: 'recursive',
  answers: outcome == 'NOERROR' ? ['2001:db8::42'] : [],
  outcome: outcome,
  fromCache: cached,
  stale: false,
  elapsedUs: BigInt.from(12500),
  truncated: false,
);
DnsQuerySnapshot snapshot(List<DnsQueryEvent> events) => DnsQuerySnapshot(
  events: events,
  total: BigInt.from(events.length),
  dropped: BigInt.zero,
);

void main() {
  setUpAll(loadAppFonts);
  testWidgets('query snapshots are bounded and polling stops when hidden', (
    tester,
  ) async {
    var reads = 0;
    final controller = DnsActivityController(
      reader: () async {
        reads++;
        return (
          queries: snapshot(List.generate(100, (i) => event('n$i.example', i))),
          status: _status,
        );
      },
    );
    controller.setVisible(true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.records.length, 80);
    expect(controller.records.first.domain, 'n99.example');
    expect(controller.status?.queries, BigInt.from(99));
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 10));
    expect(reads, 1);
    expect(controller.records, isEmpty);
    expect(controller.status, isNull);
    controller.setVisible(true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(reads, 2);
    expect(controller.records.length, 80);
    controller.dispose();
  });
  testWidgets('late snapshots cannot update a hidden panel', (tester) async {
    final pending = Completer<DnsActivitySnapshot?>();
    final controller = DnsActivityController(reader: () => pending.future);
    controller.setVisible(true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.setVisible(false);
    pending.complete((queries: snapshot([]), status: _status));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.status, isNull);
    controller.dispose();
  });
  testWidgets('clearing history invalidates an in-flight snapshot', (
    tester,
  ) async {
    final pending = Completer<DnsActivitySnapshot?>();
    var clears = 0;
    final controller = DnsActivityController(
      reader: () => pending.future,
      clearer: () async {
        clears++;
      },
    );
    controller.setVisible(true);
    await tester.pump(const Duration(milliseconds: 1));
    await controller.clear();
    pending.complete((
      queries: snapshot([event('old.example', 1)]),
      status: _status,
    ));
    await tester.pump(const Duration(milliseconds: 1));
    expect(clears, 1);
    expect(controller.records, isEmpty);
    expect(controller.total, BigInt.zero);
    controller.dispose();
  });
  testWidgets(
    'real result fields support cache and error filters and details',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DnsActivityPanel(
                reader: () async => (
                  queries: snapshot([
                    event('cached.example', 1, cached: true),
                    event('failed.example', 2, outcome: 'Timeout'),
                    event('absent.example', 3, outcome: 'NXDOMAIN'),
                  ]),
                  status: _status,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2001:db8::42'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Failed'));
      await tester.pumpAndSettle();
      expect(find.text('failed.example'), findsOneWidget);
      expect(find.text('cached.example'), findsNothing);
      expect(find.text('absent.example'), findsNothing);
      await tester.tap(find.text('failed.example'));
      await tester.pumpAndSettle();
      expect(find.text('DNS query details'), findsOneWidget);
      expect(find.textContaining('13 ms'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final (width, scale) in [(320.0, 2.0), (1000.0, 2.0), (1000.0, 1.0)]) {
    testWidgets('DNS event table wraps at $width / $scale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark),
          builder: (context, child) =>
              RepaintBoundary(key: boundary, child: child!),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: DnsActivityPanel(
                  reader: () async => (
                    queries: snapshot([event('very.long.example.com', 1)]),
                    status: _status,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureTestUi(tester, boundary, 'dns-observation-$width-$scale');
      expect(find.text('very.long.example.com'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
