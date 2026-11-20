import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

typedef IpProbeClientFactory = Dio Function(bool useProxy, int proxyPort);

typedef ProbeListener = ({
  String host,
  int port,
  String? user,
  String? password,
});

/// One-shot clients are owned and closed by the requesting screen.
Dio createIpProbeClient(
  bool useProxy,
  int proxyPort, {
  ProbeListener? listener,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'User-Agent': 'ArcadiaPlus/1.0', 'Connection': 'close'},
    ),
  );
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      final host = switch (listener?.host) {
        '::' => '::1',
        null || '*' || '0.0.0.0' => '127.0.0.1',
        final host => host,
      };
      final port = listener?.port ?? proxyPort;
      final authority = Uri(host: host, port: port).authority;
      client.findProxy = (_) => useProxy ? 'PROXY $authority' : 'DIRECT';
      if (useProxy && listener?.user != null) {
        client.addProxyCredentials(
          host,
          port,
          '',
          HttpClientBasicCredentials(listener!.user!, listener.password ?? ''),
        );
      }
      return client;
    },
  );
  return dio;
}
