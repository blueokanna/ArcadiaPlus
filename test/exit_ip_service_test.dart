import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/exit_ip_service.dart';
import 'package:arcadiaplus/src/services/ip_probe_client.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/services/proxy_selection_events.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter({this.ipv6Response});
  final Completer<ResponseBody>? ipv6Response;
  final response = Completer<ResponseBody>();
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) => (options.uri.host.contains('ipv6') ? ipv6Response ?? response : response)
      .future;
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

class _LocalHttp extends HttpOverrides {}

void main() {
  test(
    'probe uses the configured IPv6 listener and proxy credentials',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
      final client = createIpProbeClient(
        true,
        0,
        listener: (
          host: '::',
          port: server.port,
          user: 'probe',
          password: 'secret',
        ),
      );
      try {
        final handled = server.first.then((request) async {
          final received = (
            request.uri.host,
            request.headers.value(HttpHeaders.proxyAuthorizationHeader),
          );
          request.response.write('ok');
          await request.response.close();
          return received;
        });
        expect((await client.get<String>('http://probe.invalid/')).data, 'ok');
        expect(await handled, (
          'probe.invalid',
          'Basic ${base64.encode(utf8.encode('probe:secret'))}',
        ));
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    }, _LocalHttp()),
  );

  testWidgets('direct lookup publishes IPv4 while IPv6 is still pending', (
    tester,
  ) async {
    final v6 = Completer<ResponseBody>();
    final adapter = _Adapter(ipv6Response: v6);
    var usedProxy = true;
    final controller = ExitIpController(
      clientFactory: (proxy, _) {
        usedProxy = proxy;
        return Dio()..httpClientAdapter = adapter;
      },
    );
    controller.configure(useProxy: false, port: 0, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    adapter.complete('203.0.113.7');
    await tester.pump(const Duration(milliseconds: 1));
    expect(usedProxy, false);
    expect(controller.ipv4?.ip, '203.0.113.7');
    expect(controller.loading, true);
    v6.complete(ResponseBody.fromString('{"ip":"2001:db8::a"}', 200));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.ipv6?.ip, '2001:db8::a');
    expect(controller.loading, false);
    controller.configure(useProxy: true, port: 7890, active: true);
    expect(controller.report, isNull);
    expect(controller.ipv6, isNull);
    controller.dispose();
  });
  testWidgets('navigation reuses a single lookup and one-hour result', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 12);
    final requests = <_Adapter>[];
    final controller = ExitIpController(
      now: () => now,
      clientFactory: (_, _) {
        final adapter = _Adapter();
        requests.add(adapter);
        return Dio()..httpClientAdapter = adapter;
      },
    );
    addTearDown(controller.dispose);
    void visit() =>
        controller.configure(useProxy: true, port: 7890, active: true);
    visit();
    await tester.pump();
    visit();
    await tester.pump(const Duration(seconds: 1));
    expect(requests, hasLength(1));
    requests.single.complete('203.0.113.8');
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.loading, isFalse);
    now = now.add(const Duration(minutes: 59, seconds: 59));
    visit();
    await tester.pump(const Duration(seconds: 1));
    expect(requests, hasLength(1));
    expect(controller.report?.ip, '203.0.113.8');
    now = now.add(const Duration(seconds: 1));
    visit();
    await tester.pump(const Duration(seconds: 1));
    expect(requests, hasLength(2));
    requests.last.complete('203.0.113.9');
    await tester.pump(const Duration(milliseconds: 1));
    ProxySelectionEvents.applied('different-node');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(requests, hasLength(3));
    requests.last.complete('203.0.113.10');
    await tester.pump(const Duration(milliseconds: 1));
    final manual = controller.refresh();
    expect(requests, hasLength(4));
    requests.last.complete('203.0.113.11');
    await tester.pump(const Duration(milliseconds: 1));
    await manual;
    expect(controller.report?.ip, '203.0.113.11');
  });

  testWidgets('completed failures do not trigger requests on every return', (
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
    addTearDown(controller.dispose);
    controller.configure(useProxy: true, port: 7890, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    requests.single.complete('invalid');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(controller.failed, isTrue);
    for (var i = 0; i < 3; i++) {
      controller.configure(useProxy: true, port: 7890, active: false);
      controller.configure(useProxy: true, port: 7890, active: true);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(requests, hasLength(1));
    await tester.pump(const Duration(seconds: 30));
    expect(requests, hasLength(2));
    controller.hide();
    expect(requests.last.closed, isTrue);
  });

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
