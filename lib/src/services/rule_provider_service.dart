import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arcadiaplus/src/utils/serial_task_queue.dart';

import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';
import 'package:arcadiaplus/src/services/rule_catalog.dart';

import '../rust/api.dart' show validateMrs;

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
    this.format = '',
    this.payload,
    this.geosite = false,
  });

  final String name;

  /// `http` or `file`.
  final String type;

  /// `domain`, `ipcidr` or `classical`.
  final String behavior;

  final int intervalSeconds;
  final String? url;
  final String? path;
  final String format;
  final List? payload;
  final bool geosite;

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

      final payload = value['payload'];
      if (type == 'inline' && (payload is! List || payload.isEmpty)) {
        onWarning?.call('Inline rule provider "$name" needs a payload list.');
        continue;
      }
      if (type != 'http' && type != 'file' && type != 'inline') {
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
      final source = (Uri.tryParse(url ?? '')?.path ?? '').toLowerCase();
      final isMrs =
          format == 'mrs' ||
          (format.isEmpty &&
              (source.endsWith('.mrs') ||
                  (path ?? '').toLowerCase().endsWith('.mrs')));
      if (isMrs && (behavior == 'classical' || type == 'inline')) {
        onWarning?.call(
          'MRS provider "$name" requires a domain or ipcidr file.',
        );
        continue;
      }
      if (!const {'', 'yaml', 'text', 'mrs'}.contains(format)) {
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
          format: isMrs ? 'mrs' : format,
          payload: type == 'inline' ? payload as List : null,
          geosite: value['_geosite'] == true,
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
/// line format shared with the engine for `domain` / `ipcidr` / `classical`, and
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

  static Future<Directory> defaultStorageRoot() =>
      getApplicationSupportDirectory();

  final http.Client _client;
  final Future<Directory> Function() _storageRoot;
  Directory? _root;
  final _updates = SerialTaskQueue();

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
  }) => _updates.run(
    () => _prepare(
      profileId,
      yamlContent,
      force: force,
      allowNetwork: allowNetwork,
      budget: budget,
      onWarning: onWarning,
    ),
  );

  Future<RuleProviderReport> _prepare(
    String profileId,
    String yamlContent, {
    required bool force,
    required bool allowNetwork,
    required Duration budget,
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
    Future<RuleProviderState> prepareOne(RuleProviderSpec spec) async {
      if (spec.type == 'http' && DateTime.now().isAfter(deadline)) {
        onWarning?.call(
          'Rule provider "${spec.name}" was skipped: refresh budget exhausted.',
        );
        return await _cachedState(spec, directory) ??
            RuleProviderState(
              name: spec.name,
              behavior: spec.behavior,
              entries: 0,
              skipped: 0,
              updatedAt: null,
              error: 'not downloaded yet',
            );
      }
      return _materialise(
        spec,
        directory,
        force: force,
        allowNetwork: allowNetwork,
        timeout: deadline.difference(DateTime.now()),
        onWarning: onWarning,
      );
    }

    // Bound network concurrency and preserve declaration order. A slow first
    // provider must not consume the entire refresh budget for every other set.
    for (var offset = 0; offset < specs.length; offset += 3) {
      states.addAll(
        await Future.wait(specs.skip(offset).take(3).map(prepareOne)),
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
          'the profile cannot start until required routing data is available.',
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
    required Duration timeout,
    void Function(String message)? onWarning,
  }) async {
    if (spec.type == 'inline') {
      return _storeNormalised(
        spec,
        directory,
        utf8.encode(jsonEncode({'payload': spec.payload})),
        updatedAt: DateTime.now(),
      );
    }
    final meta = await _sourceMeta(directory, spec);
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

    final hasCache = cachedPath != null && await File(cachedPath).exists();
    return _fromNetwork(
      spec,
      directory,
      timeout: timeout < _requestTimeout ? timeout : _requestTimeout,
      etag: hasCache ? (meta?['etag'] as String?) : null,
      lastModified: hasCache ? (meta?['lastModified'] as String?) : null,
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
      final raw = await _readBounded(source.openRead());
      final state = await _storeNormalised(
        spec,
        directory,
        raw,
        updatedAt: await source.lastModified(),
      );
      if (!state.ready) {
        throw FormatException(state.error ?? 'invalid rule set');
      }
      await _writeMeta(directory, spec, {
        'path': state.path,
        'url': spec.url,
        'sourcePath': spec.path,
        'behavior': spec.behavior,
        'updatedAt': state.updatedAt?.toIso8601String(),
        'entries': state.entries,
        'skipped': state.skipped,
      });
      return state;
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
    required Duration timeout,
    required String? etag,
    required String? lastModified,
    required String? cachedPath,
    required DateTime? cachedUpdatedAt,
    required int cachedEntries,
    required int cachedSkipped,
  }) async {
    final uri = Uri.tryParse(spec.url!);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return _fallback(
        spec,
        cachedPath: cachedPath,
        cachedUpdatedAt: cachedUpdatedAt,
        cachedEntries: cachedEntries,
        cachedSkipped: cachedSkipped,
        error: 'rule URL must use HTTPS without credentials',
      );
    }

    final headers = <String, String>{
      'User-Agent': 'ArcadiaPlus rule-provider',
      'Accept': 'text/plain, application/yaml, text/yaml, */*',
      if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
      if (lastModified != null && lastModified.isNotEmpty)
        'If-Modified-Since': lastModified,
    };

    final abort = Completer<void>();
    final timer = Timer(timeout, () => abort.complete());
    try {
      final streamed = await _sendSecure(uri, headers, abort.future);

      if (streamed.statusCode == 304) {
        await streamed.stream.listen((_) {}).cancel();
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
        await _writeMeta(directory, spec, {
          'path': cachedPath,
          'url': spec.url,
          'behavior': spec.behavior,
          'sourcePath': spec.path,
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
        await streamed.stream.listen((_) {}).cancel();
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
        await streamed.stream.listen((_) {}).cancel();
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
      if (!state.ready) {
        return _fallback(
          spec,
          cachedPath: cachedPath,
          cachedUpdatedAt: cachedUpdatedAt,
          cachedEntries: cachedEntries,
          cachedSkipped: cachedSkipped,
          error: state.error ?? 'invalid rule set',
        );
      }

      await _writeMeta(directory, spec, {
        'path': state.path,
        'url': spec.url,
        'behavior': spec.behavior,
        'sourcePath': spec.path,
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
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<http.StreamedResponse> _sendSecure(
    Uri uri,
    Map<String, String> headers,
    Future<void> abort,
  ) async {
    var current = uri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.AbortableRequest('GET', current, abortTrigger: abort)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await _client.send(request);
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      if (location == null) {
        throw const FormatException('redirect has no location');
      }
      final next = current.resolve(location);
      if (next.scheme != 'https' ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty) {
        throw const FormatException(
          'rule redirects must use HTTPS without credentials',
        );
      }
      current = next;
    }
    throw const FormatException('too many rule-provider redirects');
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

  Future<Uint8List> _readBounded(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > _maxPayloadBytes) {
        throw const FormatException('rule set exceeds the 32 MiB limit');
      }
    }
    return builder.takeBytes();
  }

  /// Writes the provider's rules under a content-addressed name, so a changed
  /// rule set produces a changed `path` and the engine reloads it immediately
  /// instead of waiting for its own interval.
  Future<RuleProviderState> _storeNormalised(
    RuleProviderSpec spec,
    Directory directory,
    Uint8List raw, {
    required DateTime updatedAt,
  }) async {
    late Uint8List bytes;
    late int entries;
    final mrs =
        raw.length >= 4 &&
        raw[0] == 0x28 &&
        raw[1] == 0xb5 &&
        raw[2] == 0x2f &&
        raw[3] == 0xfd;
    if (spec.format == 'mrs' || (spec.format.isEmpty && mrs)) {
      entries = await validateMrs(bytes: raw, behavior: spec.behavior);
      bytes = raw;
    } else {
      if (raw.contains(0)) {
        throw const FormatException('Unexpected binary rule payload');
      }
      final normalised = await compute(_normalisePayload, (
        raw,
        spec.behavior,
        spec.geosite,
      ));
      if (normalised.entries == 0 || normalised.skipped != 0) {
        return RuleProviderState(
          name: spec.name,
          behavior: spec.behavior,
          entries: 0,
          skipped: normalised.skipped,
          updatedAt: null,
          error: normalised.entries == 0 && normalised.skipped == 0
              ? 'no usable rules'
              : 'incomplete rule set: ${normalised.skipped} unsupported entries; '
                    'refusing to publish partial routing data',
        );
      }
      bytes = utf8.encode(normalised.content);
      entries = normalised.entries;
    }
    final digest = sha256.convert(bytes).toString().substring(0, 16);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeSegment(spec.name)}.$digest.rules',
    );

    if (!file.existsSync()) {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    }

    final previous = (await _readMeta(directory, spec.name))?['path'];
    final keep = file.uri.pathSegments.last;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.length ==
              _safeSegment(spec.name).length +
                  '.0123456789abcdef.rules'.length &&
          name.startsWith('${_safeSegment(spec.name)}.') &&
          name.endsWith('.rules') &&
          name != keep &&
          entity.path != previous) {
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
      entries: entries,
      skipped: 0,
      updatedAt: updatedAt,
      path: file.path,
    );
  }

  static ({String content, int entries, int skipped}) _normalisePayload(
    (Uint8List, String, bool) input,
  ) => _normalise(utf8.decode(input.$1), input.$2, input.$3);

  static ({String content, int entries, int skipped}) _normalise(
    String raw,
    String behavior,
    bool geosite,
  ) {
    final document = _yamlPayload(raw);
    final entries = <String>[];
    var skipped = 0;

    void addEntry(String entry) {
      if (geosite) {
        // A regex quantifier can contain commas. Split only at the type.
        final comma = entry.indexOf(',');
        if (comma < 0) throw const FormatException('Invalid GEOSITE entry');
        final value = entry.substring(comma + 1);
        entry = switch (entry.substring(0, comma)) {
          'DOMAIN' => 'full:$value',
          'DOMAIN-SUFFIX' => '+.$value',
          'DOMAIN-KEYWORD' => 'keyword:$value',
          'DOMAIN-REGEX' => 'regexp:$value',
          final type => throw FormatException(
            'Unsupported GEOSITE entry: $type',
          ),
        };
      }
      if (_isSupported(entry, behavior)) {
        entries.add(behavior == 'domain' ? _domainPattern(entry) : entry);
      } else {
        skipped++;
      }
    }

    if (document != null) {
      for (final item in document) {
        if (item is! String || item.trim().isEmpty) {
          throw const FormatException(
            'every rule payload entry must be a non-empty string',
          );
        }
        final entry = item.trim();
        addEntry(entry);
      }
    } else {
      for (final line in raw.split('\n')) {
        final entry = line.trim();
        if (entry.isEmpty || entry.startsWith('#') || entry.startsWith('//')) {
          continue;
        }
        addEntry(entry);
      }
    }

    return (
      content: entries.isEmpty ? '' : '${entries.join('\n')}\n',
      entries: entries.length,
      skipped: skipped,
    );
  }

  /// Returns the `payload:` list when [raw] is a YAML/JSON rule-set document.
  static Iterable<Object?>? _yamlPayload(String raw) {
    final quoted = _quotedPayload(raw);
    if (quoted != null) return quoted;
    final lines = LineSplitter.split(raw);
    final first = lines
        .map((line) => line.trim())
        .firstWhere(
          (line) => line.isNotEmpty && !line.startsWith('#'),
          orElse: () => '',
        );
    final looksStructured =
        first.startsWith('{') ||
        first.startsWith('[') ||
        first == '---' ||
        lines.any((line) => line.trimLeft().startsWith('payload:'));
    if (!looksStructured) return null;

    try {
      final document = loadYaml(raw);
      if (document is Map && document['payload'] is List) {
        return (document['payload'] as List).cast<Object?>();
      }
    } on YamlException catch (error) {
      throw FormatException('invalid rule payload: ${error.message}');
    }
    throw const FormatException('rule document must contain a payload array');
  }

  /// Published domain/CIDR sets commonly contain hundreds of thousands of
  /// single-quoted scalars. Recognise only that exact, unambiguous subset so
  /// parsing does not retain a YAML node tree alongside the normalised rules.
  /// Anything more complex still goes through the full YAML parser.
  static Iterable<String>? _quotedPayload(String raw) {
    final lines = LineSplitter.split(raw);
    final iterator = lines.iterator;
    if (!iterator.moveNext() || iterator.current != 'payload:') return null;
    while (iterator.moveNext()) {
      final line = iterator.current;
      if (line.isEmpty) continue;
      if (!line.startsWith("  - '") ||
          !line.endsWith("'") ||
          line.length < 7 ||
          line.indexOf("'", 5) != line.length - 1) {
        return null;
      }
    }
    return lines
        .skip(1)
        .where((line) => line.isNotEmpty)
        .map((line) => line.substring(5, line.length - 1));
  }

  /// Encode Clash's exact, one-label wildcard and subdomain-only patterns
  /// explicitly. Corduit otherwise treats every unprefixed name as a suffix.
  static String _domainPattern(String entry) {
    if (entry.contains(':')) return entry;
    final domain = entry.endsWith('.')
        ? entry.substring(0, entry.length - 1)
        : entry;
    if (domain.startsWith('+.') && !domain.contains('*')) return domain;
    if (!domain.startsWith('.') && !domain.contains('*')) return 'full:$domain';
    final labels = domain.split('.');
    final prefix = switch (labels.first) {
      '' => r'(?:[^.]+\.)+',
      '+' => r'(?:[^.]+\.)*',
      _ => '',
    };
    final pattern = labels
        .skip(prefix.isEmpty ? 0 : 1)
        .map(
          (label) =>
              label == '*' ? r'[^.]+' : RegExp.escape(label.toLowerCase()),
        )
        .join(r'\.');
    return 'regexp:^$prefix$pattern\$';
  }

  static bool _isSupported(String entry, String behavior) {
    switch (behavior) {
      case 'ipcidr':
        return _isCidr(entry);
      case 'classical':
        final parts = entry.split(',');
        // Corduit's classical reader consumes only type and payload. An
        // entry-level modifier would be discarded, changing the rule's meaning.
        // Put no-resolve on the referencing RULE-SET, or use SRC-IP-CIDR.
        if (parts.length != 2 || parts[1].trim().isEmpty) return false;
        final type = parts.first.trim().toUpperCase();
        if (!_classicalTypes.contains(type)) return false;
        return !const {'IP-CIDR', 'IP-CIDR6', 'SRC-IP-CIDR'}.contains(type) ||
            _isCidr(parts[1].trim());
      case 'domain':
      default:
        for (final prefix in const ['regexp:', 'regex:', 'keyword:']) {
          if (entry.startsWith(prefix)) {
            return entry.length > prefix.length;
          }
        }
        var domain = entry;
        for (final prefix in const ['full:', '+.', '.']) {
          if (domain.startsWith(prefix)) {
            domain = domain.substring(prefix.length);
            break;
          }
        }
        if (domain.endsWith('.')) {
          domain = domain.substring(0, domain.length - 1);
        }
        return domain.isNotEmpty &&
            domain.length <= 253 &&
            domain
                .split('.')
                .every(
                  (label) =>
                      (label == '*' && !entry.startsWith('full:')) ||
                      (label.length <= 63 && _domainLabel.hasMatch(label)),
                );
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

  static bool _isCidr(String entry) {
    final parts = entry.split('/');
    if (parts.length != 2 || !_prefixLength.hasMatch(parts[1])) return false;
    final address = InternetAddress.tryParse(parts[0]);
    final prefix = int.tryParse(parts[1]);
    if (address == null || prefix == null || parts[0].contains('%')) {
      return false;
    }
    return prefix <= (address.type == InternetAddressType.IPv4 ? 32 : 128);
  }

  static final _prefixLength = RegExp(r'^\d{1,3}$');
  static final _domainLabel = RegExp(
    r'^[a-zA-Z0-9_](?:[a-zA-Z0-9_-]*[a-zA-Z0-9_])?$',
  );

  Future<RuleProviderState?> _cachedState(
    RuleProviderSpec spec,
    Directory directory,
  ) async {
    final meta = await _sourceMeta(directory, spec);
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

  Future<Map<String, dynamic>?> _sourceMeta(
    Directory directory,
    RuleProviderSpec spec,
  ) async {
    final meta = await _readMeta(directory, spec.name);
    if (meta == null ||
        meta['url'] != spec.url ||
        meta['behavior'] != spec.behavior ||
        meta['sourcePath'] != spec.path ||
        (meta['skipped'] ?? 0) != 0 ||
        (meta['entries'] as int? ?? 0) <= 0 ||
        (meta['format'] != null
            ? meta['format'] != spec.format
            : spec.format == 'mrs') ||
        (spec.behavior == 'classical' &&
            meta['classicalValidationVersion'] != 1)) {
      return null;
    }
    if (spec.behavior != 'domain' || meta['domainPatternVersion'] == 1) {
      return meta;
    }
    // Earlier versions cached the original domain lines. Re-index them even
    // when the device cannot reach the provider after upgrading.
    final path = meta['path'] as String?;
    if (path == null || spec.geosite) return null;
    try {
      final migrated = await _storeNormalised(
        spec,
        directory,
        await _readBounded(File(path).openRead()),
        updatedAt: DateTime.parse(meta['updatedAt'] as String),
      );
      if (!migrated.ready) return null;
      final updated = {
        ...meta,
        'path': migrated.path,
        'entries': migrated.entries,
      };
      await _writeMeta(directory, spec, updated);
      return updated;
    } on Exception {
      return null;
    }
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
    RuleProviderSpec spec,
    Map<String, dynamic> values,
  ) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeSegment(spec.name)}.meta.json',
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        ...values,
        'format': spec.format,
        'domainPatternVersion': 1,
        'classicalValidationVersion': 1,
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Object? _ruleProviderSection(String yamlContent) {
    final document = loadYaml(yamlContent);
    if (document is! Map) return null;
    return RuleCatalog.expand(document)['rule-providers'];
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
  final safe = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}$');
  if (safe.hasMatch(value)) return value;
  return 'key_${sha256.convert(utf8.encode(value))}';
}
