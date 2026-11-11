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

void main() {
  setUpAll(loadAppFonts);
  test('only actual TUN query events produce rows', () {
    final row = DnsQueryObservation.parse(
      '[2026-11-11 05:00:00] [INFO] DNS query received: example.com (AAAA)',
    );
    expect(row?.domain, 'example.com');
    expect(row?.type, 'AAAA');
    expect(
      DnsQueryObservation.parse(
        '[2026-11-11 05:00:00] [INFO] TCP example.com:443',
      ),
      isNull,
    );
    expect(
      DnsQueryObservation.parse(
        '[2026-11-11 05:00:00] [INFO] DNS A query: example.com -> 198.18.0.2 (Fake-IP allocated)',
      ),
      isNull,
    );
  });
  testWidgets('query snapshots are bounded and polling stops when hidden', (
    tester,
  ) async {
    var reads = 0;
    final controller = DnsActivityController(
      reader: () async {
        reads++;
        return (
          logs: List.generate(
            100,
            (i) =>
                '[2026-11-11 05:00:00] [INFO] DNS query received: n$i.example (A)',
          ),
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
    controller.dispose();
  });
  testWidgets('late snapshots cannot update a hidden panel', (tester) async {
    final pending = Completer<DnsActivitySnapshot?>();
    final controller = DnsActivityController(reader: () => pending.future);
    controller.setVisible(true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.setVisible(false);
    pending.complete((logs: <String>[], status: _status));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.status, isNull);
    controller.dispose();
  });
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
                    logs: [
                      '[2026-11-11 05:00:00] [INFO] DNS query received: very.long.example.com (AAAA)',
                    ],
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
