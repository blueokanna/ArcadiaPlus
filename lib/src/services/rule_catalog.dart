/// Materialises the individual GEOSITE categories a Clash profile references.
/// Classical lists retain exact, suffix, keyword and regular-expression rules.
abstract final class RuleCatalog {
  static final _category = RegExp(r'^[a-z0-9][a-z0-9_@!.-]*$');
  static const maxDepth = 8;

  static final _regexField = RegExp(
    r'(?:^|\()\s*DOMAIN-REGEX\s*,',
    caseSensitive: false,
  );
  static final _repeat = RegExp(r'\{[0-9]+,[0-9]*\}');

  /// Hide literal punctuation from the Clash field scanner while keeping all
  /// offsets into the original rule. A regex may contain e.g. `[(),]`, `\(`
  /// or `{1,3}` inside a logical condition.
  static String _structuralText(String text) {
    StringBuffer? result;
    var copied = 0;
    var scanned = 0;
    for (final match in _regexField.allMatches(text)) {
      if (match.start < scanned) continue;
      var groups = 0;
      var i = match.end;
      while (i < text.length) {
        final ch = text.codeUnitAt(i);
        var end = i;
        if (ch == 92 && i + 1 < text.length) {
          // escaped character
          end = i + 2;
        } else if (ch == 91) {
          // character class, including nested classes
          var depth = 1;
          end = i + 1;
          while (end < text.length && depth > 0) {
            final c = text.codeUnitAt(end++);
            if (c == 92 && end < text.length) {
              end++;
            } else if (c == 91) {
              depth++;
            } else if (c == 93) {
              depth--;
            }
          }
        } else if (ch == 123) {
          end = _repeat.matchAsPrefix(text, i)?.end ?? i;
        }
        if (end > i) {
          (result ??= StringBuffer())
            ..write(text.substring(copied, i))
            ..write(' ' * (end - i));
          copied = i = end;
          continue;
        }
        if (groups == 0 && (ch == 41 || ch == 44)) break;
        if (ch == 40) groups++;
        if (ch == 41) groups--;
        i++;
      }
      scanned = i;
    }
    return result == null
        ? text
        : (result..write(text.substring(copied))).toString();
  }

  static List<String> splitFields(String rule) {
    final syntax = _structuralText(rule);
    final fields = <String>[];
    var start = 0;
    var depth = 0;
    for (var i = 0; i < rule.length; i++) {
      switch (syntax.codeUnitAt(i)) {
        case 40:
          depth++;
        case 41:
          if (depth > 0) depth--;
        case 44:
          if (depth == 0) {
            fields.add(rule.substring(start, i));
            start = i + 1;
          }
      }
    }
    return fields..add(rule.substring(start));
  }

  static String? stripOuterParens(String text) {
    if (!text.startsWith('(') || !text.endsWith(')')) return null;
    final syntax = _structuralText(text);
    var depth = 0;
    for (var i = 0; i < text.length; i++) {
      if (syntax.codeUnitAt(i) == 40) depth++;
      if (syntax.codeUnitAt(i) == 41 && --depth == 0) {
        return i == text.length - 1 ? text.substring(1, i) : null;
      }
    }
    return null;
  }

  /// A regex payload can itself contain `(GEOSITE,cn)`. Only visit the
  /// condition field of logical operators and the first two fields of leaves.
  static String _visit(
    String rule,
    String? Function(String, String) visit, [
    int depth = 0,
  ]) {
    final comma = rule.indexOf(',');
    if (comma < 0 || depth > maxDepth) return rule;
    final kind = rule.substring(0, comma).trim().toUpperCase();
    if (kind == 'GEOSITE' || kind == 'RULE-SET') {
      final next = rule.indexOf(',', comma + 1);
      final end = next < 0 ? rule.length : next;
      final replacement = visit(kind, rule.substring(comma + 1, end).trim());
      return replacement == null ? rule : '$replacement${rule.substring(end)}';
    }
    if (kind != 'AND' && kind != 'OR' && kind != 'NOT') return rule;
    final fields = splitFields(rule);
    final inner = stripOuterParens(fields[1].trim());
    if (inner == null) return rule;
    final children = splitFields(inner);
    for (var i = 0; i < children.length; i++) {
      final body = stripOuterParens(children[i].trim());
      if (body != null) children[i] = '(${_visit(body, visit, depth + 1)})';
    }
    fields[1] = '(${children.join(',')})';
    return fields.join(',');
  }

  static Iterable<({String kind, String name})> references(Map document) sync* {
    for (final rule in (document['rules'] as List? ?? const [])) {
      if (rule is! String) continue;
      final refs = <({String kind, String name})>[];
      _visit(rule, (kind, name) {
        refs.add((kind: kind, name: name));
        return null;
      });
      yield* refs;
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
    String? rewrite(String kind, String name) {
      if (kind != 'GEOSITE') return null;
      final category = name.toLowerCase();
      return _category.hasMatch(category)
          ? 'RULE-SET,${supply(category)}'
          : null;
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
            rule is String ? _visit(rule, rewrite) : rule,
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
