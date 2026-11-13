import 'dart:async';

import 'package:arcadiaplus/src/services/profile_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  _Client(this.response);
  final Future<http.StreamedResponse> Function() response;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => response();
  @override
  void close() => closed = true;
}

void main() {
  final uri = Uri.parse('https://example.invalid/subscription');
  test('preserves body encoding and subscription metadata', () async {
    final client = _Client(
      () async => http.StreamedResponse(
        Stream.value([0xc3, 0xa9]),
        200,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'subscription-userinfo': 'total=10',
        },
      ),
    );
    final response = await ProfileDownload.get(
      uri,
      clientFactory: () => client,
    );
    expect(response.body, 'é');
    expect(response.headers['subscription-userinfo'], 'total=10');
    expect(client.closed, isTrue);
  });
  test('rejects oversized chunked responses and closes the client', () async {
    final client = _Client(
      () async => http.StreamedResponse(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        200,
      ),
    );
    await expectLater(
      ProfileDownload.get(uri, clientFactory: () => client, byteLimit: 3),
      throwsFormatException,
    );
    expect(client.closed, isTrue);
  });
  test('rejects advertised size before subscribing to the body', () async {
    var listened = false;
    final body = StreamController<List<int>>(onListen: () => listened = true);
    final client = _Client(
      () async => http.StreamedResponse(body.stream, 200, contentLength: 10),
    );
    await expectLater(
      ProfileDownload.get(uri, clientFactory: () => client, byteLimit: 3),
      throwsFormatException,
    );
    expect(listened, isFalse);
    expect(client.closed, isTrue);
    unawaited(body.close());
  });
  test('total deadline closes a stalled request', () async {
    final pending = Completer<http.StreamedResponse>();
    final client = _Client(() => pending.future);
    await expectLater(
      ProfileDownload.get(
        uri,
        clientFactory: () => client,
        deadline: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.closed, isTrue);
    pending.completeError(http.ClientException('closed'));
  });
  test('rejects non-HTTP URLs before creating a client', () async {
    await expectLater(
      ProfileDownload.get(Uri.parse('file:///config')),
      throwsFormatException,
    );
  });
}
