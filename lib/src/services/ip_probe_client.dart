import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

typedef IpProbeClientFactory = Dio Function(bool useProxy, int proxyPort);

/// One-shot clients are owned and closed by the requesting screen.
Dio createIpProbeClient(bool useProxy, int proxyPort) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'User-Agent': 'ArcadiaPlus/1.0', 'Connection': 'close'},
    ),
  );
  if (useProxy) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
        return client;
      },
    );
  }
  return dio;
}
