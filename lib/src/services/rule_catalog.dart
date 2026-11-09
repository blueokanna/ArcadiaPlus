/// File providers for the supported GEOSITE categories. The subscription's
/// own provider always wins, and rule order/targets are never rewritten.
abstract final class RuleCatalog {
  static const categories = {
    'cn': 'direct',
    'geolocation-!cn': 'proxy',
    'category-ads-all': 'reject',
    'private': 'private',
  };
  static final _references = RegExp(
    r'(?:^|[,(])\s*(RULE-SET|GEOSITE)\s*,\s*([^,()]+)',
    caseSensitive: false,
  );

  static Iterable<({String kind, String name})> references(Map document) sync* {
    for (final rule in (document['rules'] as List? ?? const [])) {
      if (rule is! String) continue;
      for (final match in _references.allMatches(rule)) {
        yield (kind: match[1]!.toUpperCase(), name: match[2]!.trim());
      }
    }
  }

  static Map<String, dynamic> expand(Map document) {
    final raw = document['rule-providers'] ?? document['rule_providers'];
    if (raw != null && raw is! Map) {
      throw const FormatException('rule-providers must be a mapping');
    }
    final providers = <String, dynamic>{
      if (raw is Map)
        for (final entry in raw.entries) entry.key.toString(): entry.value,
    };
    for (final ref in references(document)) {
      final file = categories[ref.name.toLowerCase()];
      if (ref.kind != 'GEOSITE' ||
          file == null ||
          providers.containsKey(ref.name)) {
        continue;
      }
      providers[ref.name] = {
        'type': 'http',
        'behavior': 'domain',
        'url':
            'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/$file.txt',
        'path': './ruleset/arcadia-$file.yaml',
        'interval': 86400,
      };
    }
    return {
      ...Map<String, dynamic>.from(document),
      'rule-providers': providers,
    };
  }

  static void requireAvailable(Map document, Set<String> available) {
    final missing = references(document)
        .where((ref) => !available.contains(ref.name))
        .map((ref) => '${ref.kind},${ref.name}')
        .toSet();
    if (missing.isNotEmpty) {
      throw FormatException(
        'Required routing data unavailable: ${missing.join('; ')}. '
        'Download the rule sets or supply a supported YAML/text provider; refusing to change routing by skipping rules.',
      );
    }
  }
}
