import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/exit_ip_service.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';

class _Adapter implements HttpClientAdapter {
  final response = Completer<ResponseBody>();
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) => response.future;
  @override
  void close({bool force = false}) {
    closed = true;
  }

  void complete(String ip) => response.complete(
    ResponseBody.fromString(
      jsonEncode({'ip': ip}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    ),
  );
}

void main() {
  test(
    'classification requires complete boolean evidence, never ISP name guesses',
    () {
      ExitIpReport parse(Map<String, dynamic> fields) =>
          ExitIpReport.parse({'ip': '203.0.113.7', ...fields}, source: 'test');
      expect(
        parse({'organization': 'Residential ISP'}).network,
        IpNetworkKind.unknown,
      );
      expect(
        parse({
          'risk': {'is_datacenter': false},
        }).network,
        IpNetworkKind.unknown,
      );
      expect(
        parse({
          'risk': {'is_datacenter': 'false'},
        }).network,
        IpNetworkKind.unknown,
      );
      final report = parse({
        'risk': {
          'is_datacenter': false,
          'is_mobile': false,
          'is_vpn': false,
          'is_proxy': false,
          'is_tor': false,
          'risk_score': 0,
        },
      });
      expect(report.network, IpNetworkKind.residentialCandidate);
      expect(report.riskScore, 0);
      expect(
        parse({
          'risk': {'is_datacenter': true},
        }).network,
        IpNetworkKind.hosting,
      );
      expect(
        parse({
          'risk': {'is_vpn': true},
        }).network,
        IpNetworkKind.proxy,
      );
      expect(
        parse({
          'risk': {'risk_score': 101},
        }).riskScore,
        isNull,
      );
      expect(
        parse({
          'risk': {'risk_score': '0'},
        }).riskScore,
        isNull,
      );
      expect(
        () => ExitIpReport.parse({'ip': '<html>error</html>'}, source: 'test'),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'route changes cancel sockets and reject late IP classifications',
    (tester) async {
      final requests = <_Adapter>[];
      final paths = <(bool, int)>[];
      final controller = ExitIpController(
        clientFactory: (proxy, port) {
          paths.add((proxy, port));
          final adapter = _Adapter();
          requests.add(adapter);
          return Dio()..httpClientAdapter = adapter;
        },
      );
      controller.configure(useProxy: true, port: 7890, active: true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(requests, hasLength(1));
      controller.configure(useProxy: true, port: 7891, active: true);
      expect(requests.first.closed, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      requests.last.complete('203.0.113.2');
      await tester.pump(const Duration(milliseconds: 1));
      requests.first.complete('203.0.113.1');
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.report?.ip, '203.0.113.2');
      expect(paths, [(true, 7890), (true, 7891)]);
      controller.dispose();
      expect(requests.every((r) => r.closed), isTrue);
    },
  );

  testWidgets('backgrounding cancels and resume starts a fresh lookup', (
    tester,
  ) async {
    final requests = <_Adapter>[];
    final controller = ExitIpController(
      clientFactory: (_, _) {
        final adapter = _Adapter();
        requests.add(adapter);
        return Dio()..httpClientAdapter = adapter;
      },
    );
    controller.configure(useProxy: false, port: 7890, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    AppLifecycle.instance.active.value = false;
    expect(requests.first.closed, isTrue);
    requests.first.complete('203.0.113.1');
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.report, isNull);
    AppLifecycle.instance.active.value = true;
    await tester.pump(const Duration(milliseconds: 1));
    requests.last.complete('203.0.113.2');
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.report?.ip, '203.0.113.2');
    controller.dispose();
  });
}
