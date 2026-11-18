/// Routing data this app supplies for the GEOSITE categories it knows, and the
/// rewriting that keeps those rules working on corduit 0.4.0.
///
/// A subscription asks for a category with `GEOSITE,cn,DIRECT`. Corduit 0.3.8
/// answered that from its rule-provider table, so a downloaded domain list
/// named `cn` matched. Corduit 0.4.0 split the two meanings apart: `GEOSITE`
/// now names a category inside a `geosite.dat` database and nothing else, while
/// a list this app downloaded is referenced with `RULE-SET`. A `GEOSITE` rule
/// with no database behind it does not fail — it silently falls through to the
/// next rule, which would turn ad blocking and domestic routing into a proxy
/// round trip with nothing in the log to explain it.
///
/// The two steps are separate because they answer different questions.
/// [expand] decides *what to download* for a category the profile names;
/// [preferRuleSets] decides *how to reference* a list this app has. Only the
/// second is about engine semantics, and it applies to previews as much as to
/// the live configuration.
abstract final class RuleCatalog {
  static const categories = {
    'cn': 'direct',
    'geolocation-!cn': 'proxy',
    'category-ads-all': 'reject',
    'private': 'private',
  };

  /// One rule reference: `GEOSITE,cn` or `RULE-SET,set`, optionally inside a
  /// logical rule, which is why the leading `,` or `(` is part of the match.
  ///
  /// Group 1 is the separator, 3 the kind, 5 the name; the whitespace groups are
  /// kept so a rewrite can preserve the spacing the profile was written with.
  static final _reference = RegExp(
    r'(^|[,(])(\s*)(RULE-SET|GEOSITE)(\s*,\s*)([^,()]+)',
    caseSensitive: false,
  );

  static Iterable<({String kind, String name})> references(Map document) sync* {
    for (final rule in (document['rules'] as List? ?? const [])) {
      if (rule is! String) continue;
      for (final match in _reference.allMatches(rule)) {
        yield (kind: match[3]!.toUpperCase(), name: match[5]!.trim());
      }
    }
  }

  /// The profile's providers with one added for every catalogued category it
  /// references. Rule text is left exactly as written; see [preferRuleSets].
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

  /// Rewrites `GEOSITE,<name>` to `RULE-SET,<name>` wherever this document
  /// supplies `<name>` as a provider.
  ///
  /// Rule order and targets are untouched. A reference nothing supplies is left
  /// alone: `RULE-SET` for a provider that does not exist would fail the
  /// configuration instead of the one rule, and the converter already reports
  /// the reference rather than hiding it.
  static Map<String, dynamic> preferRuleSets(Map document) {
    final raw = document['rule-providers'] ?? document['rule_providers'];
    final supplied = <String>{
      if (raw is Map)
        for (final name in raw.keys) name.toString().toLowerCase(),
    };
    final rules = document['rules'];
    if (rules is! List || supplied.isEmpty) {
      return Map<String, dynamic>.from(document);
    }
    return {
      ...Map<String, dynamic>.from(document),
      'rules': [
        for (final rule in rules)
          rule is String ? _nameTheProvider(rule, supplied) : rule,
      ],
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

  static String _nameTheProvider(String rule, Set<String> supplied) {
    return rule.replaceAllMapped(_reference, (match) {
      if (match[3]!.toUpperCase() != 'GEOSITE') return match[0]!;
      final name = match[5]!.trim();
      if (!supplied.contains(name.toLowerCase())) return match[0]!;
      return '${match[1]}RULE-SET${match[4]}$name';
    });
  }
}
