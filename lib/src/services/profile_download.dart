import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Bounds decoded response bytes, including chunked/compressed subscriptions.
/// Closing the owned client also cancels a timed-out request or response stream.
abstract final class ProfileDownload {
  static const maxBytes = 16 * 1024 * 1024;
  static const timeout = Duration(seconds: 30);

  static Future<http.Response> get(
    Uri uri, {
    http.Client Function()? clientFactory,
    int byteLimit = maxBytes,
    Duration deadline = timeout,
  }) async {
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('Subscription URL must use HTTP or HTTPS');
    }
    if (byteLimit <= 0) throw ArgumentError.value(byteLimit, 'byteLimit');
    final client = (clientFactory ?? http.Client.new)();
    try {
      return await (() async {
        final response = await client.send(http.Request('GET', uri));
        if (response.statusCode != 200) {
          throw http.ClientException(
            'Subscription request failed (${response.statusCode})',
          );
        }
        if ((response.contentLength ?? 0) > byteLimit) {
          throw const FormatException('Subscription exceeds the size limit');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (chunk.length > byteLimit - bytes.length) {
            throw const FormatException('Subscription exceeds the size limit');
          }
          bytes.add(chunk);
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          response.statusCode,
          headers: response.headers,
        );
      })().timeout(deadline);
    } finally {
      client.close();
    }
  }
}
