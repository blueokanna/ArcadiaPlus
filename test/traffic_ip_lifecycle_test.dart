import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/services/proxy_selection_events.dart';
import 'package:arcadiaplus/src/widgets/traffic_chart.dart';

class PendingResponse implements HttpClientAdapter {
  final response = Completer<ResponseBody>();
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => response.future;
  @override
  void close({bool force = false}) {
    closed = true;
  }

  void complete(String ip) {
    response.complete(
      ResponseBody.fromString(
        jsonEncode({'ip': ip}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
  }
}

void main() {
  testWidgets('route changes discard old IP replies and close their clients', (
    tester,
  ) async {
    final requests = <PendingResponse>[];
    final ports = <int>[];
    Dio factory(bool proxy, int port) {
      ports.add(port);
      final adapter = PendingResponse();
      requests.add(adapter);
      return Dio()..httpClientAdapter = adapter;
    }

    Widget chart(int port) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TrafficChart(
            trafficStats: TrafficStats(
              upload: BigInt.zero,
              download: BigInt.zero,
              uploadSpeed: BigInt.zero,
              downloadSpeed: BigInt.zero,
            ),
            downloadSpeed: BigInt.zero,
            uploadSpeed: BigInt.zero,
            isProxyRunning: true,
            proxyPort: port,
            ipClientFactory: factory,
          ),
        ),
      ),
    );
    ProxySelectionEvents.applied('initial');
    await tester.pumpWidget(chart(7890));
    await tester.pump();
    expect(requests.length, 2);
    ProxySelectionEvents.applied('new-route');
    await tester.pump();
    expect(requests.take(2).every((r) => r.closed), isTrue);
    await tester.pump(const Duration(milliseconds: 850));
    await tester.pump();
    expect(requests.length, 4);
    requests[2].complete('203.0.113.2');
    requests[3].complete('2001:db8::2');
    await tester.pumpAndSettle();
    requests[0].complete('198.51.100.1');
    requests[1].complete('2001:db8::1');
    await tester.pumpAndSettle();
    expect(find.text('203.0.113.2'), findsOneWidget);
    expect(find.text('198.51.100.1'), findsNothing);
    expect(find.text('2001:db8::1'), findsNothing);
    // A port edit changes the path even if the running flag stays true.
    await tester.pumpWidget(chart(7891));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(ports.skip(4), [7891, 7891]);
    await tester.pumpWidget(const SizedBox());
    requests[4].complete('203.0.113.3');
    requests[5].complete('2001:db8::3');
    await tester.pumpAndSettle();
    expect(requests.every((r) => r.closed), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selection revision invalidates cache while dashboard is absent',
    (tester) async {
      final requests = <PendingResponse>[];
      Dio factory(bool _, int _) {
        final adapter = PendingResponse();
        requests.add(adapter);
        return Dio()..httpClientAdapter = adapter;
      }

      Widget chart() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TrafficChart(
              trafficStats: TrafficStats(
                upload: BigInt.zero,
                download: BigInt.zero,
                uploadSpeed: BigInt.zero,
                downloadSpeed: BigInt.zero,
              ),
              downloadSpeed: BigInt.zero,
              uploadSpeed: BigInt.zero,
              ipClientFactory: factory,
            ),
          ),
        ),
      );
      ProxySelectionEvents.applied('seed');
      await tester.pumpWidget(chart());
      await tester.pump();
      requests[0].complete('198.51.100.10');
      requests[1].complete('2001:db8::10');
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      ProxySelectionEvents.applied('route-changed-offscreen');
      await tester.pumpWidget(chart());
      await tester.pump();
      expect(requests.length, 4);
      expect(find.text('198.51.100.10'), findsNothing);
      requests[2].complete('203.0.113.20');
      requests[3].complete('2001:db8::20');
      await tester.pumpAndSettle();
      expect(find.text('203.0.113.20'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
