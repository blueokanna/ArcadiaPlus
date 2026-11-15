import 'dart:convert';

import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map convert(String rule) => jsonDecode(
    ConfigConverter.convertClashYamlToJson(
      'rules:\n  - $rule\n  - MATCH,DIRECT',
      requireCompleteRules: true,
    ),
  ) as Map;

  test('logical no-resolve is metadata, not part of the CIDR', () {
    final config = convert(
      'AND,((IP-CIDR,203.0.113.0/24,no-resolve),(NETWORK,tcp)),REJECT',
    );
    final child = config['rules'][0]['rules'][0] as Map;
    expect(child['payload'], '203.0.113.0/24');
    expect(child['no_resolve'], true);
    expect(child['outbound'], 'REJECT');
  });

  test('logical port lists retain all ports', () {
    final config = convert('AND,((DST-PORT,80,443),(NETWORK,tcp)),REJECT');
    expect(config['rules'][0]['rules'][0]['payload'], '80,443');
  });

  test('nested NOT must have exactly one operand', () {
    expect(
      () => convert(
        'AND,((NOT,((DOMAIN,a.test),(DOMAIN,b.test))),(NETWORK,tcp)),REJECT',
      ),
      throwsException,
    );
  });

  test('empty logical operands cannot silently disappear', () {
    expect(
      () => convert('AND,((DOMAIN,a.test),,(NETWORK,tcp)),REJECT'),
      throwsException,
    );
  });
}
