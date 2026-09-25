import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DNS settings model.
///
/// Only the knobs the engine can actually carry are modelled here
/// (`dns.enable`, `dns.listen`, `dns.nameservers`, `dns.fallback`,
/// `dns.enhanced_mode`). Everything else the profile may declare
/// (`nameserver-policy`, `fallback-filter`, `fake-ip-range`, `fake-ip-filter`,
/// `fake-ip-ttl`, `cache-size`, a hosts table) is passed through by the config
/// converter untouched: it is a profile-level knob, and duplicating it here
/// would mean two owners for one value.
///
/// Records carry [nameserversRevision] so a list this app shipped as a default
/// can be told apart from one the user built, which is what makes it safe to
/// grow the former and leave the latter alone.
class DnsSettings {
  /// Every value `dns.enhanced_mode` may hold.
  ///
  /// The engine accepts all three: `normal` and `redir-host` are two spellings
  /// of one behaviour (it answers with the real address and routes on the
  /// resolved IP), and `fake-ip` answers from a reserved pool instead. The
  /// vocabulary lives here because the settings store, the settings provider
  /// and the picker all have to agree on it, and they drift the moment one of
  /// them keeps its own copy.
  static const List<String> modes = ['redir-host', 'fake-ip', 'normal'];

  /// What a profile that names no mode gets, and what a stored value that is
  /// not in [modes] falls back to.
  ///
  /// mihomo's default: a profile that does not ask for fake addresses should
  /// not get them, so every connection keeps the name it was made to and
  /// nothing depends on an address that only exists in this process.
  static const String defaultMode = 'redir-host';

  /// The upstreams a fresh install starts with.
  ///
  /// Two public DoH resolvers that are reachable almost everywhere, plus the
  /// two large Chinese operators so a user behind a network that drops the
  /// first pair still resolves. Four is not a statement about how many are
  /// ideal — it is one working entry per failure mode this app has actually
  /// seen, and the editor offers more in one tap.
  static const List<String> defaultNameservers = [
    'https://dns.cloudflare.com/dns-query',
    'https://dns.google/dns-query',
    'https://doh.pub/dns-query',
    'https://dns.alidns.com/dns-query',
  ];

  /// The list an earlier build shipped. A stored list that still matches it
  /// exactly was never touched by the user, so it is safe to grow.
  static const List<String> _legacyDefaultNameservers = [
    'https://dns.google/dns-query',
    'https://cloudflare-dns.com/dns-query',
  ];

  /// Bumped when [defaultNameservers] grows. Records on disk carry the value
  /// they were written with, so the migration below runs once per install.
  static const int nameserverDefaultsRevision = 2;

  /// The revision this record was written with.
  final int nameserversRevision;

  final bool enable;
  final bool overrideDns;
  final String listen;
  final bool useRecursiveResolver;
  final String dnsMode;
  final List<String> nameservers;
  final List<String> fallback;

  DnsSettings({
    this.enable = true,
    this.overrideDns = false,
    this.listen = '127.0.0.1:53',
    this.useRecursiveResolver = false,
    this.dnsMode = defaultMode,
    this.nameservers = defaultNameservers,
    this.fallback = const [],
    this.nameserversRevision = nameserverDefaultsRevision,
  }) : assert(
         modes.contains(dnsMode),
         'dnsMode must be one of ${DnsSettings.modes}',
       );

  Map<String, dynamic> toJson() => {
    'enable': enable,
    'overrideDns': overrideDns,
    'listen': listen,
    'useRecursiveResolver': useRecursiveResolver,
    'dnsMode': dnsMode,
    'nameservers': nameservers,
    'fallback': fallback,
    'nameserversRevision': nameserversRevision,
  };

  factory DnsSettings.fromJson(Map<String, dynamic> json) => DnsSettings(
    enable: json['enable'] as bool? ?? true,
    overrideDns: json['overrideDns'] as bool? ?? false,
    listen: json['listen'] as String? ?? '127.0.0.1:53',
    useRecursiveResolver: json['useRecursiveResolver'] as bool? ?? false,
    dnsMode: normaliseMode(json['dnsMode']),
    nameservers: (json['nameservers'] as List?)?.cast<String>() ?? const [],
    fallback: (json['fallback'] as List?)?.cast<String>() ?? const [],
    // Records written before the revision existed carry the first default set.
    nameserversRevision: (json['nameserversRevision'] as num?)?.toInt() ?? 1,
  );

  /// A stored mode, or [defaultMode] when it is missing or no longer one of
  /// [modes].
  ///
  /// Persisted values outlive the vocabulary that wrote them, and the picker
  /// asserts that its value is one of its items — so an unknown string read
  /// back from disk would not merely be wrong, it would take the screen down.
  /// Normalising on read keeps that class of failure out of the UI.
  static String normaliseMode(Object? stored) =>
      stored is String && modes.contains(stored) ? stored : defaultMode;

  /// Grows an untouched nameserver list to the current default set and stamps
  /// the record, so this happens once rather than on every load.
  ///
  /// A list that no longer matches the old default is the user's own choice —
  /// including an empty one — and is left exactly as it is, because silently
  /// adding resolvers to a list somebody pruned would undo their decision.
  DnsSettings withCurrentNameserverDefaults() {
    if (nameserversRevision >= nameserverDefaultsRevision) return this;

    final untouched =
        nameservers.length == _legacyDefaultNameservers.length &&
        nameservers.toSet().containsAll(_legacyDefaultNameservers);

    return copyWith(
      nameservers: untouched ? defaultNameservers : nameservers,
      nameserversRevision: nameserverDefaultsRevision,
    );
  }

  DnsSettings copyWith({
    bool? enable,
    bool? overrideDns,
    String? listen,
    bool? useRecursiveResolver,
    String? dnsMode,
    List<String>? nameservers,
    List<String>? fallback,
    int? nameserversRevision,
  }) {
    return DnsSettings(
      enable: enable ?? this.enable,
      overrideDns: overrideDns ?? this.overrideDns,
      listen: listen ?? this.listen,
      useRecursiveResolver: useRecursiveResolver ?? this.useRecursiveResolver,
      dnsMode: dnsMode ?? this.dnsMode,
      nameservers: nameservers ?? this.nameservers,
      fallback: fallback ?? this.fallback,
      nameserversRevision: nameserversRevision ?? this.nameserversRevision,
    );
  }
}

/// General settings model
class GeneralSettings {
  final int tcpKeepAliveInterval;
  final String speedTestUrl;
  final int httpPort;
  final int socksPort;
  final int mixedPort;
  final bool ipv6;
  final bool allowLan;
  final bool unifiedDelay;
  final bool appendSystemDns;
  final bool findProcess;
  final bool tcpConcurrent;
  final String bindAddress;
  final String mode; // 'rule', 'global', 'direct'
  final String logLevel;
  final String? externalController;
  final String? externalUi;
  final String? secret;
  final bool hapticFeedbackEnabled; // 震动反馈开关

  GeneralSettings({
    this.tcpKeepAliveInterval = 30,
    this.speedTestUrl = 'http://www.gstatic.com/generate_204',
    this.httpPort = 7890,
    this.socksPort = 7891,
    this.mixedPort = 7897,
    this.ipv6 = false,
    this.allowLan = false,
    this.unifiedDelay = false,
    this.appendSystemDns = false,
    this.findProcess = true,
    this.tcpConcurrent = false,
    this.bindAddress = '127.0.0.1',
    this.mode = 'rule',
    this.logLevel = 'info',
    this.externalController,
    this.externalUi,
    this.secret,
    this.hapticFeedbackEnabled = false, // 默认关闭
  });

  Map<String, dynamic> toJson() => {
    'tcpKeepAliveInterval': tcpKeepAliveInterval,
    'speedTestUrl': speedTestUrl,
    'httpPort': httpPort,
    'socksPort': socksPort,
    'mixedPort': mixedPort,
    'ipv6': ipv6,
    'allowLan': allowLan,
    'unifiedDelay': unifiedDelay,
    'appendSystemDns': appendSystemDns,
    'findProcess': findProcess,
    'tcpConcurrent': tcpConcurrent,
    'bindAddress': bindAddress,
    'mode': mode,
    'logLevel': logLevel,
    'externalController': externalController,
    'externalUi': externalUi,
    'secret': secret,
    'hapticFeedbackEnabled': hapticFeedbackEnabled,
  };

  factory GeneralSettings.fromJson(Map<String, dynamic> json) {
    final allowLan = json['allowLan'] as bool? ?? false;
    final ipv6 = json['ipv6'] as bool? ?? false;
    var bindAddress = json['bindAddress'] as String? ?? '127.0.0.1';

    // Convert '*' or invalid addresses to proper IP format
    if (bindAddress == '*') {
      if (allowLan) {
        bindAddress = ipv6 ? '::' : '0.0.0.0';
      } else {
        bindAddress = ipv6 ? '::1' : '127.0.0.1';
      }
    }

    return GeneralSettings(
      tcpKeepAliveInterval: json['tcpKeepAliveInterval'] as int? ?? 30,
      speedTestUrl:
          json['speedTestUrl'] as String? ??
          'http://www.gstatic.com/generate_204',
      httpPort: json['httpPort'] as int? ?? 7890,
      socksPort: json['socksPort'] as int? ?? 7891,
      mixedPort: json['mixedPort'] as int? ?? 7897,
      ipv6: ipv6,
      allowLan: allowLan,
      unifiedDelay: json['unifiedDelay'] as bool? ?? false,
      appendSystemDns: json['appendSystemDns'] as bool? ?? false,
      findProcess: json['findProcess'] as bool? ?? true,
      tcpConcurrent: json['tcpConcurrent'] as bool? ?? false,
      bindAddress: bindAddress,
      mode: json['mode'] as String? ?? 'rule',
      logLevel: json['logLevel'] as String? ?? 'info',
      externalController: json['externalController'] as String?,
      externalUi: json['externalUi'] as String?,
      secret: json['secret'] as String?,
      hapticFeedbackEnabled: json['hapticFeedbackEnabled'] as bool? ?? false,
    );
  }

  GeneralSettings copyWith({
    int? tcpKeepAliveInterval,
    String? speedTestUrl,
    int? httpPort,
    int? socksPort,
    int? mixedPort,
    bool? ipv6,
    bool? allowLan,
    bool? unifiedDelay,
    bool? appendSystemDns,
    bool? findProcess,
    bool? tcpConcurrent,
    String? bindAddress,
    String? mode,
    String? logLevel,
    String? externalController,
    String? externalUi,
    String? secret,
    bool? hapticFeedbackEnabled,
  }) {
    return GeneralSettings(
      tcpKeepAliveInterval: tcpKeepAliveInterval ?? this.tcpKeepAliveInterval,
      speedTestUrl: speedTestUrl ?? this.speedTestUrl,
      httpPort: httpPort ?? this.httpPort,
      socksPort: socksPort ?? this.socksPort,
      mixedPort: mixedPort ?? this.mixedPort,
      ipv6: ipv6 ?? this.ipv6,
      allowLan: allowLan ?? this.allowLan,
      unifiedDelay: unifiedDelay ?? this.unifiedDelay,
      appendSystemDns: appendSystemDns ?? this.appendSystemDns,
      findProcess: findProcess ?? this.findProcess,
      tcpConcurrent: tcpConcurrent ?? this.tcpConcurrent,
      bindAddress: bindAddress ?? this.bindAddress,
      mode: mode ?? this.mode,
      logLevel: logLevel ?? this.logLevel,
      externalController: externalController ?? this.externalController,
      externalUi: externalUi ?? this.externalUi,
      secret: secret ?? this.secret,
      hapticFeedbackEnabled:
          hapticFeedbackEnabled ?? this.hapticFeedbackEnabled,
    );
  }
}

/// Profile configuration model with JSON serialization
class ProfileConfig {
  final String id;
  final String name;
  final String type; // 'url', 'file', 'qrcode'
  final String source;
  final String? configContent;
  final DateTime? lastUpdated;
  final DateTime? expiresAt;
  final int? usedTraffic;
  final int? totalTraffic;
  final bool autoUpdate;
  final int autoUpdateInterval; // in minutes

  ProfileConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.source,
    this.configContent,
    this.lastUpdated,
    this.expiresAt,
    this.usedTraffic,
    this.totalTraffic,
    this.autoUpdate = false,
    this.autoUpdateInterval = 180,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'source': source,
    'configContent': configContent,
    'lastUpdated': lastUpdated?.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'usedTraffic': usedTraffic,
    'totalTraffic': totalTraffic,
    'autoUpdate': autoUpdate,
    'autoUpdateInterval': autoUpdateInterval,
  };

  factory ProfileConfig.fromJson(Map<String, dynamic> json) => ProfileConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    type: json['type'] as String,
    source: json['source'] as String,
    configContent: json['configContent'] as String?,
    lastUpdated: json['lastUpdated'] != null
        ? DateTime.parse(json['lastUpdated'] as String)
        : null,
    expiresAt: json['expiresAt'] != null
        ? DateTime.parse(json['expiresAt'] as String)
        : null,
    usedTraffic: json['usedTraffic'] as int?,
    totalTraffic: json['totalTraffic'] as int?,
    autoUpdate: json['autoUpdate'] as bool? ?? false,
    autoUpdateInterval: json['autoUpdateInterval'] as int? ?? 180,
  );

  ProfileConfig copyWith({
    String? id,
    String? name,
    String? type,
    String? source,
    String? configContent,
    DateTime? lastUpdated,
    DateTime? expiresAt,
    int? usedTraffic,
    int? totalTraffic,
    bool? autoUpdate,
    int? autoUpdateInterval,
  }) {
    return ProfileConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      source: source ?? this.source,
      configContent: configContent ?? this.configContent,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      expiresAt: expiresAt ?? this.expiresAt,
      usedTraffic: usedTraffic ?? this.usedTraffic,
      totalTraffic: totalTraffic ?? this.totalTraffic,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      autoUpdateInterval: autoUpdateInterval ?? this.autoUpdateInterval,
    );
  }
}

/// Network settings model.
///
/// [systemProxy] and [tunEnabled] are descriptions of what the platform is
/// doing right now, not preferences: they are read back from the OS (or from
/// the tunnel) whenever settings load, and the stored copy exists only so the
/// record is complete on disk.
class NetworkSettings {
  /// The bypass entries a proxy client is expected to ship with: loopback,
  /// link-local and the private ranges. Sending a router page, a NAS share or
  /// a printer through a tunnel is never what anyone meant, and on most home
  /// LANs those names only resolve locally anyway.
  ///
  /// Entries are in this app's canonical form — host names, `*.suffix`
  /// patterns and CIDR blocks. Each platform renders them into the dialect its
  /// own proxy setting understands; see `PlatformProxyService`.
  static const List<String> defaultBypassDomains = <String>[
    'localhost',
    '127.0.0.1',
    '::1',
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '169.254.0.0/16',
    '*.local',
    '*.lan',
  ];

  /// Revision of [defaultBypassDomains] an install has been brought up to.
  ///
  /// Bump this when the list gains an entry existing installs should get too:
  /// [StorageService.getNetworkSettings] then merges the missing entries once
  /// and stamps the record, so an entry the user deletes afterwards stays gone
  /// until the default list itself next changes.
  static const int bypassDefaultsRevision = 1;

  final bool systemProxy;
  final List<String> bypassDomains;
  final bool tunEnabled;

  /// Revision of [defaultBypassDomains] this record already carries. Zero for
  /// records written before the revision was tracked.
  final int bypassRevision;

  NetworkSettings({
    this.systemProxy = false,
    this.bypassDomains = defaultBypassDomains,
    this.tunEnabled = false,
    this.bypassRevision = bypassDefaultsRevision,
  });

  Map<String, dynamic> toJson() => {
    'systemProxy': systemProxy,
    'bypassDomains': bypassDomains,
    'tunEnabled': tunEnabled,
    'bypassRevision': bypassRevision,
  };

  factory NetworkSettings.fromJson(Map<String, dynamic> json) =>
      NetworkSettings(
        systemProxy: json['systemProxy'] as bool? ?? false,
        bypassDomains:
            (json['bypassDomains'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
        tunEnabled: json['tunEnabled'] as bool? ?? false,
        // Absent means the record predates the revision field, which is
        // exactly the case the migration in `getNetworkSettings` is for.
        bypassRevision: json['bypassRevision'] as int? ?? 0,
      );

  /// This record with every default entry it does not already carry, stamped
  /// with [bypassDefaultsRevision]. Order is preserved so the user's own
  /// entries stay where they put them.
  NetworkSettings withDefaultBypassDomains() {
    final merged = List<String>.of(bypassDomains);
    for (final entry in defaultBypassDomains) {
      if (!merged.contains(entry)) merged.add(entry);
    }
    return copyWith(
      bypassDomains: merged,
      bypassRevision: bypassDefaultsRevision,
    );
  }

  NetworkSettings copyWith({
    bool? systemProxy,
    List<String>? bypassDomains,
    bool? tunEnabled,
    int? bypassRevision,
  }) {
    return NetworkSettings(
      systemProxy: systemProxy ?? this.systemProxy,
      bypassDomains: bypassDomains ?? this.bypassDomains,
      tunEnabled: tunEnabled ?? this.tunEnabled,
      bypassRevision: bypassRevision ?? this.bypassRevision,
    );
  }
}

/// Wallpaper settings model.
///
/// [imagePath] is a file this app owns a copy of, not the file the user picked:
/// a mobile picker hands out a path in a cache directory the OS is free to
/// reclaim, and a picture that silently disappears after a week is worse than
/// no picture at all. `WallpaperService` does the copying.
///
/// [blur] and [dim] are what make a photograph usable as a background: without
/// blur, details compete with text; without dim, a bright photo does the same.
class WallpaperSettings {
  /// Sigma of the gaussian blur, in logical pixels. The ceiling keeps the cost
  /// of the filter bounded — a full-screen blur is not free.
  static const double maxBlur = 40;

  /// Alpha of the scrim drawn between the picture and the interface.
  static const double maxDim = 0.8;

  final String? imagePath;
  final bool enabled;
  final double blur;
  final double dim;

  const WallpaperSettings({
    this.imagePath,
    this.enabled = true,
    this.blur = 18,
    this.dim = 0.35,
  });

  /// Whether a picture exists to draw.
  bool get hasImage => (imagePath ?? '').isNotEmpty;

  /// Whether the picture should be drawn right now.
  bool get isVisible => enabled && hasImage;

  Map<String, dynamic> toJson() => {
    'imagePath': imagePath,
    'enabled': enabled,
    'blur': blur,
    'dim': dim,
  };

  factory WallpaperSettings.fromJson(Map<String, dynamic> json) =>
      WallpaperSettings(
        imagePath: json['imagePath'] as String?,
        enabled: json['enabled'] as bool? ?? true,
        blur: _clamp(json['blur'] as num?, 0, maxBlur, 18),
        dim: _clamp(json['dim'] as num?, 0, maxDim, 0.35),
      );

  WallpaperSettings copyWith({
    Object? imagePath = _unset,
    bool? enabled,
    double? blur,
    double? dim,
  }) {
    return WallpaperSettings(
      imagePath: imagePath == _unset ? this.imagePath : imagePath as String?,
      enabled: enabled ?? this.enabled,
      blur: _clamp(blur, 0, maxBlur, this.blur),
      dim: _clamp(dim, 0, maxDim, this.dim),
    );
  }

  /// A stored number, or [fallback] when it is missing or outside `[min, max]`.
  ///
  /// A slider whose value is out of range throws at build time, and these
  /// numbers outlive the code that wrote them, so they are bounded on read.
  static double _clamp(num? value, double min, double max, double fallback) {
    if (value == null) return fallback;
    final number = value.toDouble();
    if (number.isNaN || number.isInfinite) return fallback;
    return number.clamp(min, max);
  }
}

/// Sentinel for [WallpaperSettings.copyWith] so `imagePath: null` can mean
/// "clear the picture" instead of "keep the current one".
const Object _unset = Object();

/// Storage service for persisting app data
class StorageService {
  static StorageService? _instance;
  static StorageService get instance => _instance ??= StorageService._();

  StorageService._();

  SharedPreferences? _prefs;
  String? _dataDir;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final appDir = await getApplicationSupportDirectory();
    _dataDir = appDir.path;

    // Ensure data directories exist
    await Directory('$_dataDir/profiles').create(recursive: true);
    await Directory('$_dataDir/config').create(recursive: true);
  }

  // ==================== Profile Management ====================

  Future<List<ProfileConfig>> getProfiles() async {
    final profilesJson = _prefs?.getString('profiles');
    if (profilesJson == null) return [];

    try {
      final List<dynamic> decoded = jsonDecode(profilesJson);
      return decoded
          .map((e) => ProfileConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Failed to load profiles: $e');
      return [];
    }
  }

  Future<void> saveProfiles(List<ProfileConfig> profiles) async {
    final jsonList = profiles.map((p) => p.toJson()).toList();
    await _prefs?.setString('profiles', jsonEncode(jsonList));
  }

  Future<void> addProfile(ProfileConfig profile) async {
    final profiles = await getProfiles();
    profiles.add(profile);
    await saveProfiles(profiles);
  }

  Future<void> updateProfile(ProfileConfig profile) async {
    final profiles = await getProfiles();
    final index = profiles.indexWhere((p) => p.id == profile.id);
    if (index != -1) {
      profiles[index] = profile;
      await saveProfiles(profiles);
    }
  }

  Future<void> deleteProfile(String id) async {
    final profiles = await getProfiles();
    profiles.removeWhere((p) => p.id == id);
    await saveProfiles(profiles);

    // Also delete config file if exists
    final configFile = File('$_dataDir/profiles/$id.yaml');
    if (await configFile.exists()) {
      await configFile.delete();
    }
  }

  Future<void> saveProfileConfig(String profileId, String configContent) async {
    final configFile = File('$_dataDir/profiles/$profileId.yaml');
    await configFile.writeAsString(configContent);
  }

  Future<String?> getProfileConfig(String profileId) async {
    final configFile = File('$_dataDir/profiles/$profileId.yaml');
    if (await configFile.exists()) {
      return configFile.readAsString();
    }
    return null;
  }

  // ==================== Active Profile ====================

  Future<String?> getActiveProfileId() async {
    return _prefs?.getString('activeProfileId');
  }

  Future<void> setActiveProfileId(String? id) async {
    if (id != null) {
      await _prefs?.setString('activeProfileId', id);
    } else {
      await _prefs?.remove('activeProfileId');
    }
  }

  // ==================== Network Settings ====================

  Future<NetworkSettings> getNetworkSettings() async {
    final json = _prefs?.getString('networkSettings');
    if (json == null) return NetworkSettings();

    try {
      final settings = NetworkSettings.fromJson(jsonDecode(json));
      if (settings.bypassRevision >= NetworkSettings.bypassDefaultsRevision) {
        return settings;
      }
      // The bypass list gained entries since this install last saved it. Merge
      // them in and stamp the record, so this happens once rather than on
      // every load.
      final migrated = settings.withDefaultBypassDomains();
      await saveNetworkSettings(migrated);
      return migrated;
    } catch (e) {
      debugPrint('Failed to load network settings: $e');
      return NetworkSettings();
    }
  }

  Future<void> saveNetworkSettings(NetworkSettings settings) async {
    await _prefs?.setString('networkSettings', jsonEncode(settings.toJson()));
  }

  // ==================== Language Settings ====================

  Future<String?> getLocale() async {
    return _prefs?.getString('locale');
  }

  Future<void> setLocale(String? locale) async {
    if (locale != null) {
      await _prefs?.setString('locale', locale);
    } else {
      await _prefs?.remove('locale');
    }
  }

  // ==================== General Settings ====================

  Future<String> getLogLevel() async {
    return _prefs?.getString('logLevel') ?? 'info';
  }

  Future<void> setLogLevel(String level) async {
    await _prefs?.setString('logLevel', level);
  }

  // ==================== DNS Settings ====================

  Future<DnsSettings> getDnsSettings() async {
    final json = _prefs?.getString('dnsSettings');
    if (json == null) return DnsSettings();

    try {
      final settings = DnsSettings.fromJson(jsonDecode(json));
      if (settings.nameserversRevision >=
          DnsSettings.nameserverDefaultsRevision) {
        return settings;
      }
      // The default upstream list grew since this record was written. Grow it
      // once, then stamp the record, so this happens once rather than on every
      // load.
      final migrated = settings.withCurrentNameserverDefaults();
      await saveDnsSettings(migrated);
      return migrated;
    } catch (e) {
      debugPrint('Failed to load DNS settings: $e');
      return DnsSettings();
    }
  }

  Future<void> saveDnsSettings(DnsSettings settings) async {
    await _prefs?.setString('dnsSettings', jsonEncode(settings.toJson()));
  }

  // ==================== General Settings ====================

  Future<GeneralSettings> getGeneralSettings() async {
    final json = _prefs?.getString('generalSettings');
    if (json == null) return GeneralSettings();

    try {
      return GeneralSettings.fromJson(jsonDecode(json));
    } catch (e) {
      debugPrint('Failed to load general settings: $e');
      return GeneralSettings();
    }
  }

  Future<void> saveGeneralSettings(GeneralSettings settings) async {
    await _prefs?.setString('generalSettings', jsonEncode(settings.toJson()));
  }

  // ==================== Wallpaper ====================

  Future<WallpaperSettings> getWallpaperSettings() async {
    final json = _prefs?.getString('wallpaperSettings');
    if (json == null) return const WallpaperSettings();

    try {
      return WallpaperSettings.fromJson(jsonDecode(json));
    } catch (e) {
      debugPrint('Failed to load wallpaper settings: $e');
      return const WallpaperSettings();
    }
  }

  Future<void> saveWallpaperSettings(WallpaperSettings settings) async {
    await _prefs?.setString('wallpaperSettings', jsonEncode(settings.toJson()));
  }

  // ==================== Data Directory ====================

  String get dataDirectory => _dataDir ?? '';
  Future<String> getConfigPath() async {
    return '$_dataDir/config';
  }
}
