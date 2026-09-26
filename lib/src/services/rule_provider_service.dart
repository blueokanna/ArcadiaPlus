import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

/// A `rule-providers` entry exactly as the profile declares it.
@immutable
class RuleProviderSpec {
  const RuleProviderSpec({
    required this.name,
    required this.type,
    required this.behavior,
    required this.intervalSeconds,
    this.url,
    this.path,
  });

  final String name;

  /// `http` or `file`.
  final String type;

  /// `domain`, `ipcidr` or `classical`.
  final String behavior;

  final int intervalSeconds;
  final String? url;
  final String? path;

  static const supportedBehaviors = {'domain', 'ipcidr', 'classical'};

  /// Parses the `rule-providers` section of a Clash document.
  ///
  /// Entries the engine cannot build are reported through [onWarning] and
  /// skipped; this mirrors how the rest of the profile is converted, where an
  /// unusable node never takes the whole config down.
  static List<RuleProviderSpec> parse(
    Object? section, {
    void Function(String message)? onWarning,
  }) {
    if (section == null) return const [];
    if (section is! Map) {
      onWarning?.call(
        'rule-providers must be a mapping; the section was ignored.',
      );
      return const [];
    }

    final specs = <RuleProviderSpec>[];
    for (final entry in section.entries) {
      final name = entry.key.toString();
      final value = entry.value;
      if (value is! Map) {
        onWarning?.call(
          'Rule provider "$name" is not a mapping; it was dropped.',
        );
        continue;
      }

      final type = (value['type'] ?? 'http').toString().toLowerCase();
      final behavior = (value['behavior'] ?? 'classical')
          .toString()
          .toLowerCase();
      final url = value['url']?.toString();
      final path = value['path']?.toString();
      final format = (value['format']?.toString() ?? '').trim().toLowerCase();

      if (type != 'http' && type != 'file') {
        onWarning?.call(
          'Rule provider "$name" has unsupported type "$type"; it was dropped.',
        );
        continue;
      }
      if (!supportedBehaviors.contains(behavior)) {
        onWarning?.call(
          'Rule provider "$name" has unsupported behavior "$behavior"; it was dropped.',
        );
        continue;
      }
      // MRS is mihomo's binary rule-set format. Decoding it is not something
      // this engine implements, and guessing would be worse than saying so:
      // the set is dropped with a reason instead of silently contributing
      // nothing. A profile can point the same provider at a YAML or text
      // source and get the rules it intended.
      final source = (url ?? path ?? '').toLowerCase();
      final isMrs =
          format == 'mrs' || (format.isEmpty && source.endsWith('.mrs'));
      if (isMrs) {
        onWarning?.call(
          'Rule provider "$name" is a MRS (binary) rule set, which this build '
          'cannot decode; it was dropped. Point it at a YAML or text rule set.',
        );
        continue;
      }
      if (format.isNotEmpty && format != 'yaml' && format != 'text') {
        onWarning?.call(
          'Rule provider "$name" declares format "$format", which is not '
          'supported; it was dropped.',
        );
        continue;
      }
      if (type == 'http' && (url == null || url.isEmpty)) {
        onWarning?.call('Rule provider "$name" needs a url; it was dropped.');
        continue;
      }
      if (type == 'file' && (path == null || path.isEmpty)) {
        onWarning?.call('Rule provider "$name" needs a path; it was dropped.');
        continue;
      }

      specs.add(
        RuleProviderSpec(
          name: name,
          type: type,
          behavior: behavior,
          intervalSeconds: _parseInterval(value['interval'], name, onWarning),
          url: url,
          path: path,
        ),
      );
    }
    return specs;
  }

  static int _parseInterval(
    Object? raw,
    String name,
    void Function(String message)? onWarning,
  ) {
    const fallback = 86400;
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null) return fallback;
    if (value < 60) {
      onWarning?.call(
        'Rule provider "$name" declares an interval below 60s; raised to 60s.',
      );
      return 60;
    }
    return value;
  }
}

/// Result of materialising one provider on disk.
@immutable
class RuleProviderState {
  const RuleProviderState({
    required this.name,
    required this.behavior,
    required this.entries,
    required this.skipped,
    required this.updatedAt,
    this.path,
    this.error,
  });

  final String name;
  final String behavior;
  final int entries;
  final int skipped;
  final DateTime? updatedAt;

  /// Absolute path the engine should read, when the provider is usable.
  final String? path;
  final String? error;

  bool get ready => path != null;
}

/// The rule sets a profile can hand to the engine: provider name → file path.
@immutable
class RuleProviderReport {
  const RuleProviderReport({required this.paths, required this.states});

  const RuleProviderReport.empty() : paths = const {}, states = const [];

  final Map<String, String> paths;
  final List<RuleProviderState> states;

  List<RuleProviderState> get failed =>
      states.where((state) => !state.ready).toList(growable: false);

  int get entryCount => states.fold(
    0,
    (total, state) => total + (state.ready ? state.entries : 0),
  );

  DateTime? get newestUpdate {
    final stamps = states
        .map((state) => state.updatedAt)
        .whereType<DateTime>()
        .toList(growable: false);
    if (stamps.isEmpty) return null;
    stamps.sort();
    return stamps.last;
  }
}

/// Downloads, normalises and caches the profile's `rule-providers`.
///
/// The engine can fetch HTTP providers itself, but it does so without a proxy,
/// without conditional requests, and any failure aborts engine start-up. This
/// service owns the network side instead: it keeps a local copy per provider,
/// refreshes it on the declared interval (Loyalsoldier-style sets ship
/// `interval: 86400`), normalises YAML `payload:` documents into the plain
/// line format the engine parses for `domain` / `ipcidr` / `classical`, and
/// hands the engine a `file` provider — so a provider that cannot be reached
/// degrades to the last good copy instead of blocking the proxy.
class RuleProviderService extends ChangeNotifier {
  RuleProviderService({
    http.Client? client,
    Future<Directory> Function()? storageRoot,
  }) : _client = client ?? http.Client(),
       _storageRoot = storageRoot ?? defaultStorageRoot;

  static final RuleProviderService instance = RuleProviderService();

  static const _maxPayloadBytes = 32 * 1024 * 1024;
  static const _requestTimeout = Duration(seconds: 20);
  static const _defaultInterval = Duration(days: 1);

  /// Application support directory, where cached rule sets live.
  static Future<Directory> defaultStorageRoot() =>
      getApplicationSupportDirectory();

  final http.Client _client;
  final Future<Directory> Function() _storageRoot;
  Directory? _root;

  /// Profile the last [prepare] call belonged to, so a listener can tell
  /// whether the refresh concerns the config it owns.
  String? _lastProfileId;
  String? get lastProfileId => _lastProfileId;

  Future<Directory> _rootDirectory() async {
    final existing = _root;
    if (existing != null) return existing;
    final support = await _storageRoot();
    final root = Directory(
      '${support.path}${Platform.pathSeparator}rule-providers',
    );
    await root.create(recursive: true);
    _root = root;
    return root;
  }

  Directory _profileDirectory(Directory root, String profileId) => Directory(
    '${root.path}${Platform.pathSeparator}${_safeSegment(profileId)}',
  );

  /// Materialises every provider of [yamlContent] and returns what the engine
  /// can use right now. Never throws for a provider that could not be
  /// refreshed: its previous copy stays in place, and a provider that never
  /// had one is reported as not ready.
  Future<RuleProviderReport> prepare(
    String profileId,
    String yamlContent, {
    bool force = false,
    bool allowNetwork = true,
    Duration budget = const Duration(seconds: 30),
    void Function(String message)? onWarning,
  }) async {
    final Object? section = _ruleProviderSection(yamlContent);
    final specs = RuleProviderSpec.parse(section, onWarning: onWarning);
    if (specs.isEmpty) return const RuleProviderReport.empty();
    final root = await _rootDirectory();
    final directory = _profileDirectory(root, profileId);
    await directory.create(recursive: true);

    final deadline = DateTime.now().add(budget);
    final states = <RuleProviderState>[];
    for (final spec in specs) {
      if (DateTime.now().isAfter(deadline)) {
        onWarning?.call(
          'Rule provider "${spec.name}" was skipped: refresh budget exhausted.',
        );
        states.add(
          await _cachedState(spec, directory) ??
              RuleProviderState(
                name: spec.name,
                behavior: spec.behavior,
                entries: 0,
                skipped: 0,
                updatedAt: null,
                error: 'not downloaded yet',
              ),
        );
        continue;
      }
      states.add(
        await _materialise(
          spec,
          directory,
          force: force,
          allowNetwork: allowNetwork,
          onWarning: onWarning,
        ),
      );
    }

    final paths = <String, String>{
      for (final state in states)
        if (state.path != null) state.name: state.path!,
    };
    for (final state in states) {
      if (!state.ready) {
        onWarning?.call(
          'Rule provider "${state.name}" is unavailable (${state.error}); '
          'rules referencing it fall through.',
        );
      } else if (state.skipped > 0) {
        onWarning?.call(
          'Rule provider "${state.name}" skipped ${state.skipped} unsupported '
          'entries out of ${state.entries + state.skipped}.',
        );
      }
    }
    _lastProfileId = profileId;
    notifyListeners();
    return RuleProviderReport(paths: paths, states: states);
  }

  Future<RuleProviderState> _materialise(
    RuleProviderSpec spec,
    Directory directory, {
    required bool force,
    required bool allowNetwork,
    void Function(String message)? onWarning,
  }) async {
    final meta = await _readMeta(directory, spec.name);
    final cachedPath = meta?['path'] as String?;
    final updatedAt = DateTime.tryParse(meta?['updatedAt'] as String? ?? '');
    final interval = spec.intervalSeconds > 0
        ? Duration(seconds: spec.intervalSeconds)
        : _defaultInterval;
    final due =
        updatedAt == null || DateTime.now().difference(updatedAt) >= interval;

    if (spec.type == 'file') {
      return _fromLocalFile(spec, directory, onWarning: onWarning);
    }
    if (!force && !due && cachedPath != null && File(cachedPath).existsSync()) {
      final entries = meta?['entries'] as int? ?? 0;
      return RuleProviderState(
        name: spec.name,
        behavior: spec.behavior,
        entries: entries,
        skipped: meta?['skipped'] as int? ?? 0,
        updatedAt: updatedAt,
        path: cachedPath,
      );
    }
    if (!allowNetwork) {
      if (cachedPath != null && File(cachedPath).existsSync()) {
        return RuleProviderState(
          name: spec.name,
          behavior: spec.behavior,
          entries: meta?['entries'] as int? ?? 0,
          skipped: meta?['skipped'] as int? ?? 0,
          updatedAt: updatedAt,
          path: cachedPath,
        );
      }
      return RuleProviderState(
        name: spec.name,
        behavior: spec.behavior,
        entries: 0,
        skipped: 0,
        updatedAt: null,
        error: 'network refresh disabled',
      );
    }

    return _fromNetwork(
      spec,
      directory,
      etag: meta?['etag'] as String?,
      lastModified: meta?['lastModified'] as String?,
      cachedPath: cachedPath,
      cachedUpdatedAt: updatedAt,
      cachedEntries: meta?['entries'] as int? ?? 0,
      cachedSkipped: meta?['skipped'] as int? ?? 0,
    );
  }

  Future<RuleProviderState> _fromLocalFile(
    RuleProviderSpec spec,
    Directory directory, {
    void Function(String message)? onWarning,
  }) async {
    final source = File(spec.path!);
    if (!source.existsSync()) {
      final cached = await _cachedState(spec, directory);
      if (cached != null) return cached;
      return RuleProviderState(
        name: spec.name,
        behavior: spec.behavior,
        entries: 0,
        skipped: 0,
        updatedAt: null,
        error: 'file not found: ${spec.path}',
      );
    }

    try {
      // Bytes, not `readAsString`: a packed (binary) rule set would make the
      // strict UTF-8 decoder throw before the binary guard could explain it.
      // The size bound matches the network path for the same reason — a rule
      // set is read into memory, so it needs a ceiling either way.
      final size = await source.length();
      if (size > _maxPayloadBytes) {
        throw const FormatException('rule set exceeds the 32 MiB limit');
      }
      final raw = utf8.decode(await source.readAsBytes(), allowMalformed: true);
      return await _storeNormalised(
        spec,
        directory,
        raw,
        updatedAt: source.lastModifiedSync(),
      );
    } catch (error) {
      onWarning?.call('Rule provider "${spec.name}" could not be read: $error');
      final cached = await _cachedState(spec, directory);
      return cached ??
          RuleProviderState(
            name: spec.name,
            behavior: spec.behavior,
            entries: 0,
            skipped: 0,
            updatedAt: null,
            error: error.toString(),
          );
    }
  }

  Future<RuleProviderState> _fromNetwork(
    RuleProviderSpec spec,
    Directory directory, {
    required String? etag,
    required String? lastModified,
    required String? cachedPath,
    required DateTime? cachedUpdatedAt,
    required int cachedEntries,
    required int cachedSkipped,
  }) async {
    final uri = Uri.tryParse(spec.url!);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return _fallback(
        spec,
        cachedPath: cachedPath,
        cachedUpdatedAt: cachedUpdatedAt,
        cachedEntries: cachedEntries,
        cachedSkipped: cachedSkipped,
        error: 'url must be https: ${spec.url}',
      );
    }

    final headers = <String, String>{
      'User-Agent': 'ArcadiaPlus rule-provider',
      'Accept': 'text/plain, application/yaml, text/yaml, */*',
      if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
      if (lastModified != null && lastModified.isNotEmpty)
        'If-Modified-Since': lastModified,
    };

    try {
      final streamed = await _client
          .send(http.Request('GET', uri)..headers.addAll(headers))
          .timeout(_requestTimeout);

      if (streamed.statusCode == 304) {
        if (cachedPath == null || !File(cachedPath).existsSync()) {
          return _fallback(
            spec,
            cachedPath: cachedPath,
            cachedUpdatedAt: cachedUpdatedAt,
            cachedEntries: cachedEntries,
            cachedSkipped: cachedSkipped,
            error: 'source reported 304 but no local copy exists',
          );
        }
        await _writeMeta(directory, spec.name, {
          'path': cachedPath,
          'url': spec.url,
          'etag': etag,
          'lastModified': lastModified,
          'updatedAt': DateTime.now().toIso8601String(),
          'entries': cachedEntries,
          'skipped': cachedSkipped,
        });
        return RuleProviderState(
          name: spec.name,
          behavior: spec.behavior,
          entries: cachedEntries,
          skipped: cachedSkipped,
          updatedAt: DateTime.now(),
          path: cachedPath,
        );
      }

      if (streamed.statusCode != 200) {
        await streamed.stream.drain<void>();
        return _fallback(
          spec,
          cachedPath: cachedPath,
          cachedUpdatedAt: cachedUpdatedAt,
          cachedEntries: cachedEntries,
          cachedSkipped: cachedSkipped,
          error: 'HTTP ${streamed.statusCode}',
        );
      }

      final finalUrl = streamed.request?.url;
      if (finalUrl != null && finalUrl.scheme != 'https') {
        await streamed.stream.drain<void>();
        return _fallback(
          spec,
          cachedPath: cachedPath,
          cachedUpdatedAt: cachedUpdatedAt,
          cachedEntries: cachedEntries,
          cachedSkipped: cachedSkipped,
          error: 'redirected to a non-TLS url: $finalUrl',
        );
      }

      final raw = await _readBounded(streamed.stream);
      final state = await _storeNormalised(
        spec,
        directory,
        raw,
        updatedAt: DateTime.now(),
      );
      if (!state.ready) return state;

      await _writeMeta(directory, spec.name, {
        'path': state.path,
        'url': spec.url,
        'etag': streamed.headers['etag'],
        'lastModified': streamed.headers['last-modified'],
        'updatedAt': state.updatedAt?.toIso8601String(),
        'entries': state.entries,
        'skipped': state.skipped,
      });
      return state;
    } catch (error) {
      return _fallback(
        spec,
        cachedPath: cachedPath,
        cachedUpdatedAt: cachedUpdatedAt,
        cachedEntries: cachedEntries,
        cachedSkipped: cachedSkipped,
        error: error.toString(),
      );
    }
  }

  RuleProviderState _fallback(
    RuleProviderSpec spec, {
    required String? cachedPath,
    required DateTime? cachedUpdatedAt,
    required int cachedEntries,
    required int cachedSkipped,
    required String error,
  }) {
    if (cachedPath != null && File(cachedPath).existsSync()) {
      return RuleProviderState(
        name: spec.name,
        behavior: spec.behavior,
        entries: cachedEntries,
        skipped: cachedSkipped,
        updatedAt: cachedUpdatedAt,
        path: cachedPath,
        error: error,
      );
    }
    return RuleProviderState(
      name: spec.name,
      behavior: spec.behavior,
      entries: 0,
      skipped: 0,
      updatedAt: null,
      error: error,
    );
  }

  Future<String> _readBounded(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > _maxPayloadBytes) {
        throw const FormatException('rule set exceeds the 32 MiB limit');
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  /// Writes the provider's rules under a content-addressed name, so a changed
  /// rule set produces a changed `path` and the engine reloads it immediately
  /// instead of waiting for its own interval.
  Future<RuleProviderState> _storeNormalised(
    RuleProviderSpec spec,
    Directory directory,
    String raw, {
    required DateTime updatedAt,
  }) async {
    if (_looksBinary(raw)) {
      // A binary payload reached the normaliser — an MRS set whose URL did
      // not announce itself, or some other packed format. Writing the
      // "rules" from it would produce a file of mojibake that matches
      // nothing and looks like it loaded; reporting is the honest outcome.
      return RuleProviderState(
        name: spec.name,
        behavior: spec.behavior,
        entries: 0,
        skipped: 0,
        updatedAt: null,
        error:
            'the rule set is a binary payload this build cannot decode '
            '(MRS?); use a YAML or text source',
      );
    }
    final normalised = _normalise(raw, spec.behavior);
    if (normalised.entries == 0) {
      // The engine rejects a rule set with no usable entries, which would
      // abort engine start-up; report it instead of writing a file.
      return RuleProviderState(
        name: spec.name,
        behavior: spec.behavior,
        entries: 0,
        skipped: normalised.skipped,
        updatedAt: null,
        error: 'no usable rules (${normalised.skipped} entries skipped)',
      );
    }
    final bytes = utf8.encode(normalised.content);
    final digest = sha256.convert(bytes).toString().substring(0, 16);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeSegment(spec.name)}.$digest.rules',
    );

    if (!file.existsSync()) {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }

    final keep = file.uri.pathSegments.last;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('${_safeSegment(spec.name)}.') &&
          name.endsWith('.rules') &&
          name != keep) {
        try {
          await entity.delete();
        } on FileSystemException catch (error) {
          debugPrint('Failed to drop stale rule set $name: $error');
        }
      }
    }

    return RuleProviderState(
      name: spec.name,
      behavior: spec.behavior,
      entries: normalised.entries,
      skipped: normalised.skipped,
      updatedAt: updatedAt,
      path: file.path,
    );
  }

  /// Whether decoded text is actually a binary payload.
  ///
  /// `utf8.decode(allowMalformed: true)` turns a binary set into replacement
  /// characters rather than failing, so the check has to look at the bytes
  /// that arrived: a NUL or a dense run of replacement characters is a
  /// packed format, not a rule list.
  static bool _looksBinary(String raw) {
    if (raw.contains('\u0000')) return true;
    if (raw.isEmpty) return false;
    final head = raw.length > 2048 ? raw.substring(0, 2048) : raw;
    var replacement = 0;
    for (final unit in head.codeUnits) {
      if (unit == 0xFFFD) replacement++;
    }
    return replacement * 10 > head.length;
  }

  ({String content, int entries, int skipped}) _normalise(
    String raw,
    String behavior,
  ) {
    final document = _yamlPayload(raw);
    final entries = <String>[];
    var skipped = 0;

    if (document != null) {
      for (final item in document) {
        final entry = item?.toString().trim() ?? '';
        if (entry.isEmpty) continue;
        if (_isSupported(entry, behavior)) {
          entries.add(entry);
        } else {
          skipped++;
        }
      }
    } else {
      for (final line in raw.split('\n')) {
        final entry = line.trim();
        if (entry.isEmpty || entry.startsWith('#') || entry.startsWith('//')) {
          continue;
        }
        if (_isSupported(entry, behavior)) {
          entries.add(entry);
        } else {
          skipped++;
        }
      }
    }

    return (
      content: entries.isEmpty ? '' : '${entries.join('\n')}\n',
      entries: entries.length,
      skipped: skipped,
    );
  }

  /// Returns the `payload:` list when [raw] is a YAML/JSON rule-set document.
  ///
  /// The engine parses `domain` / `ipcidr` / `classical` providers as plain
  /// line lists; a YAML document fed to it would be read line by line and
  /// produce entries that never match, so the payload is unwrapped here.
  List<Object?>? _yamlPayload(String raw) {
    final head = raw.length > 4096 ? raw.substring(0, 4096) : raw;
    final looksStructured =
        head.trimLeft().startsWith('{') || head.contains('payload:');
    if (!looksStructured) return null;

    try {
      final document = loadYaml(raw);
      if (document is Map && document['payload'] is List) {
        return (document['payload'] as List).cast<Object?>();
      }
    } on YamlException {
      return null;
    }
    return null;
  }

  bool _isSupported(String entry, String behavior) {
    switch (behavior) {
      case 'ipcidr':
        return _cidrPattern.hasMatch(entry);
      case 'classical':
        final parts = entry.split(',');
        // Anything else is dropped by the engine's classical parser; counting
        // it here keeps the reported entry count equal to the live rule count.
        return parts.length >= 2 &&
            _classicalTypes.contains(parts.first.trim().toUpperCase());
      case 'domain':
      default:
        return !entry.contains(RegExp(r'\s'));
    }
  }

  static const _classicalTypes = {
    'DOMAIN',
    'DOMAIN-SUFFIX',
    'DOMAIN-KEYWORD',
    'DOMAIN-REGEX',
    'IP-CIDR',
    'IP-CIDR6',
    'SRC-IP-CIDR',
    'PROCESS-NAME',
  };

  static final RegExp _cidrPattern = RegExp(
    r'^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{2,45})/\d{1,3}$',
  );

  Future<RuleProviderState?> _cachedState(
    RuleProviderSpec spec,
    Directory directory,
  ) async {
    final meta = await _readMeta(directory, spec.name);
    final path = meta?['path'] as String?;
    if (path == null || !File(path).existsSync()) return null;
    return RuleProviderState(
      name: spec.name,
      behavior: spec.behavior,
      entries: meta?['entries'] as int? ?? 0,
      skipped: meta?['skipped'] as int? ?? 0,
      updatedAt: DateTime.tryParse(meta?['updatedAt'] as String? ?? ''),
      path: path,
    );
  }

  Future<Map<String, dynamic>?> _readMeta(
    Directory directory,
    String name,
  ) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeSegment(name)}.meta.json',
    );
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (error) {
      debugPrint('Failed to read rule provider metadata for $name: $error');
      return null;
    }
  }

  Future<void> _writeMeta(
    Directory directory,
    String name,
    Map<String, dynamic> values,
  ) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeSegment(name)}.meta.json',
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(values), flush: true);
    await tmp.rename(file.path);
  }

  Object? _ruleProviderSection(String yamlContent) {
    final document = loadYaml(yamlContent);
    if (document is! Map) return null;
    return document['rule-providers'] ?? document['rule_providers'];
  }

  /// Removes every cached copy belonging to a deleted profile.
  Future<void> forgetProfile(String profileId) async {
    try {
      final root = await _rootDirectory();
      final directory = _profileDirectory(root, profileId);
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    } catch (error) {
      debugPrint('Failed to drop cached rule providers of $profileId: $error');
    }
  }
}

String _safeSegment(String value) {
  final sanitised = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return sanitised.isEmpty ? 'unnamed' : sanitised;
}
