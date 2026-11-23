import 'dart:io';

import 'package:arcadiaplus/src/services/domain_ruleset_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SRS v1 serializes duplicate exact keys and a suffix marker', () async {
    final dir = await Directory.systemTemp.createTemp('arcadia-srs-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/domains');
    final packed = File('${dir.path}/domains.srs');
    await source.writeAsString('full:A\n+.ab\nfull:a\n');
    await encodeDomainRules(source, packed, 3);
    final bytes = await packed.readAsBytes();
    expect(bytes.take(4), [83, 82, 83, 1]);
    // In breadth-first order the five nodes are root, a, b, ba, ba\n.
    // Terminals are 1 and 4. Each node ends its list of edges with a set bit.
    expect(zlib.decode(bytes.sublist(4)), [
      1,
      0,
      2,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0x12,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      0xac,
      4,
      97,
      98,
      97,
      10,
      255,
      0,
    ]);
  });
}
