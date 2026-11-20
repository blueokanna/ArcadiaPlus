/// Materialises the individual GEOSITE categories a Clash profile references.
/// Classical lists retain exact, suffix, keyword and regular-expression rules.
abstract final class RuleCatalog {
  static final _reference = RegExp(
    r'(^|\()(\s*)(RULE-SET|GEOSITE)(\s*,\s*)([^,()]+)',
    caseSensitive: false,
  );
  static final _category = RegExp(r'^[a-z0-9][a-z0-9_@!.-]*$');

  static Iterable<({String kind, String name})> references(Map document) sync* {
    for (final rule in (document['rules'] as List? ?? const [])) {
      if (rule is! String) continue;
      for (final match in _reference.allMatches(rule)) {
        yield (kind: match[3]!.toUpperCase(), name: match[5]!.trim());
      }
    }
  }

  static Map<String, dynamic> expand(Map document) {
    final raw = document['rule-providers'] ?? document['rule_providers'];
    if (raw != null && raw is! Map) {
      throw const FormatException('rule-providers must be a mapping');
    }
    final providers = <String, dynamic>{
      if (raw is Map) ...Map<String, dynamic>.from(raw),
    };
    final reserved = {
      ...providers.keys,
      for (final ref in references(document))
        if (ref.kind == 'RULE-SET') ref.name,
    };
    final names = <String, String>{};
    String supply(String category) => names.putIfAbsent(category, () {
      var key = category;
      while (!reserved.add(key)) {
        key = '_geosite_$key';
      }
      providers[key] = {
        'type': 'http',
        'behavior': 'domain',
        '_geosite': true,
        'format': 'text',
        'url':
            'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/classical/$category.list',
        'interval': 86400,
      };
      return key;
    });
    String rewrite(Match match) {
      if (match[3]!.toUpperCase() != 'GEOSITE') return match[0]!;
      final category = match[5]!.trim().toLowerCase();
      if (!_category.hasMatch(category)) return match[0]!;
      final name = supply(category);
      return '${match[1]}${match[2]}RULE-SET${match[4]}$name';
    }

    return {
      ...Map<String, dynamic>.from(document),
      '_defaultCnProvider':
          (document['rules'] as List? ?? const []).isEmpty &&
              (document['proxies'] as List? ?? const []).isNotEmpty
          ? supply('cn')
          : null,
      if (document['rules'] case final List rules)
        'rules': [
          for (final rule in rules)
            rule is String ? rule.replaceAllMapped(_reference, rewrite) : rule,
        ],
      'rule-providers': providers,
    };
  }

  static void requireAvailable(Map document, Set<String> available) {
    final missing = references(document)
        .where((ref) => ref.kind == 'GEOSITE' || !available.contains(ref.name))
        .map((ref) => '${ref.kind},${ref.name}')
        .toSet();
    if (missing.isNotEmpty) {
      throw FormatException(
        'Required routing data unavailable: ${missing.join(', ')}',
      );
    }
  }
}
