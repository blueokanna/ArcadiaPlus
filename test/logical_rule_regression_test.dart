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

  for (final rule in [
    'DOMAIN,DIRECT',
    'DOMAIN,,DIRECT',
    'MATCH,ignored,DIRECT',
    'DOMAIN,video.test,DIRECT,unknown-option',
    'GEOIP,CN,DIRECT,src',
    'AND,((DOMAIN,video.test),(NETWORK,tcp)),DIRECT,no-resolve',
    'AND,((DOMAIN,video.test,unknown-option),(NETWORK,tcp)),DIRECT',
    'AND,((MATCH,ignored),(NETWORK,tcp)),DIRECT',
  ]) {
    test('runtime refuses changed routing semantics: $rule', () {
      expect(() => convert(rule), throwsException);
    });
  }

  test('source CIDR modifier changes the match dimension at every depth', () {
    final top = convert('IP-CIDR,192.0.2.0/24,DIRECT,src');
    expect(top['rules'][0]['rule_type'], 'src_ip_cidr');
    final nested = convert(
      'AND,((IP-CIDR,192.0.2.0/24,src),(NETWORK,tcp)),DIRECT',
    );
    expect(nested['rules'][0]['rules'][0]['type'], 'src_ip_cidr');
    expect(nested['rules'][0]['rules'][0]['payload'], '192.0.2.0/24');
  });

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
