import 'dart:ffi' as ffi;
import 'dart:io' show Platform, Directory, File, FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:arcadiaplus/src/rust/api.dart' show setGeoipDatabasePath;
import 'package:arcadiaplus/src/rust/frb_generated.dart';

enum NativeCoreStatus { idle, initializing, ready, failed }

/// Owns native library diagnostics and flutter_rust_bridge initialization.
class NativeCoreService extends ChangeNotifier {
  NativeCoreService._();

  static final NativeCoreService instance = NativeCoreService._();

  static const MethodChannel _androidChannel = MethodChannel(
    'com.arcadiaplus/proxy',
  );

  static const String _geoIpAsset = 'assets/Country.mmdb';
  static const String _wintunAsset = 'assets/wintun/wintun.dll';

  NativeCoreStatus _status = NativeCoreStatus.idle;
  String? _lastError;
  String? _geoIpError;
  String? _geoIpDatabasePath;
  Future<bool>? _pendingInitialization;

  NativeCoreStatus get status => _status;
  bool get isReady => _status == NativeCoreStatus.ready;
  bool get isInitializing => _status == NativeCoreStatus.initializing;
  String? get lastError => _lastError;
  String? get geoIpError => _geoIpError;

  /// The unpacked `Country.mmdb` path, or `null` before installation.
  ///
  /// The HarmonyOS extension process runs its own engine and must be told
  /// where the database is: paths, not objects, are what crosses between the
  /// app's processes.
  String? get geoIpDatabasePath => _geoIpDatabasePath;

  Future<bool> initialize({int maxAttempts = 3}) {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
    }

    final pending = _pendingInitialization;
    if (pending != null) {
      return pending;
    }

    final initialization = _initialize(maxAttempts);
    _pendingInitialization = initialization;
    return initialization.whenComplete(() => _pendingInitialization = null);
  }

  Future<bool> _initialize(int maxAttempts) async {
    _setStatus(NativeCoreStatus.initializing);
    _lastError = null;

    final androidDiagnostic = await _readAndroidDiagnostic();
    if (androidDiagnostic != null) {
      debugPrint(androidDiagnostic);
    }

    if (Platform.isAndroid) {
      try {
        ffi.DynamicLibrary.open('librust_lib_arcadiaplus.so');
        debugPrint('Native core dynamic library is loadable.');
      } catch (error) {
        _lastError = 'Dynamic library load failed: $error';
        debugPrint(_lastError);
      }
    }

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await RustLib.init();
        _lastError = null;
        await _installGeoIpDatabase();
        await _installWintunLibrary();
        _setStatus(NativeCoreStatus.ready);
        debugPrint('Native core initialized on attempt $attempt.');
        return true;
      } catch (error, stackTrace) {
        _lastError = error.toString();
        debugPrint(
          'Native core initialization failed '
          '(attempt $attempt/$maxAttempts): $error',
        );
        debugPrintStack(stackTrace: stackTrace);

        if (attempt < maxAttempts) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    }

    if (androidDiagnostic != null && _lastError != null) {
      _lastError = '$androidDiagnostic\n$_lastError';
    }
    _setStatus(NativeCoreStatus.failed);
    return false;
  }

  Future<String?> _readAndroidDiagnostic() async {
    if (!Platform.isAndroid) {
      return null;
    }

    try {
      final result = await _androidChannel.invokeMapMethod<String, dynamic>(
        'getNativeLibraryInfo',
      );
      if (result == null || result['loaded'] == true) {
        return null;
      }

      final error = result['error']?.toString();
      return error == null || error.isEmpty
          ? 'Android could not load the native core.'
          : 'Android native loader: $error';
    } on MissingPluginException {
      return 'Android native diagnostics channel is unavailable.';
    } catch (error) {
      return 'Android native diagnostics failed: $error';
    }
  }

  void _setStatus(NativeCoreStatus value) {
    _status = value;
    notifyListeners();
  }

  /// Unpacks the bundled GeoIP database and registers its real path with the
  /// engine.
  ///
  /// corduit resolves `Country.mmdb` from `CORDUIT_GEOIP_DB` or from the
  /// executable's directory, neither of which exists for a Flutter app: the
  /// asset is sealed inside the APK / `.app` / install directory. Without this
  /// step a `GEOIP` rule never matches and China-direct profiles quietly route
  /// everything through the proxy, so a failure here is recorded and logged
  /// rather than swallowed.
  Future<void> _installGeoIpDatabase() async {
    try {
      final data = await rootBundle.load(_geoIpAsset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.isEmpty) {
        throw const FormatException('bundled GeoIP database is empty');
      }

      final support = await getApplicationSupportDirectory();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}geoip',
      );
      await directory.create(recursive: true);
      final target = File(
        '${directory.path}${Platform.pathSeparator}Country.mmdb',
      );
      final stamp = File('${target.path}.stamp');
      final installed = await _readStamp(stamp);
      final fingerprint = '${_fingerprint(bytes)}:${bytes.length}';

      if (target.existsSync() && installed == fingerprint) {
        debugPrint('GeoIP database already installed at ${target.path}');
      } else {
        final temporary = File('${target.path}.tmp');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(target.path);
        await stamp.writeAsString(fingerprint, flush: true);
        debugPrint('GeoIP database installed at ${target.path}');
      }

      await setGeoipDatabasePath(path: target.path);
      _geoIpDatabasePath = target.path;
      _geoIpError = null;
    } catch (error) {
      _geoIpError = error.toString();
      debugPrint('GeoIP database unavailable, GEOIP rules stay inert: $error');
    }
  }

  Future<String?> _readStamp(File stamp) async {
    try {
      return (await stamp.readAsString()).trim();
    } on FileSystemException {
      return null;
    }
  }

  /// Places the bundled Wintun driver where the engine looks for it.
  ///
  /// TUN mode on Windows needs `wintun.dll`, which is not part of Windows:
  /// the engine searches beside the executable and in the per-user
  /// application directory. The executable directory is tried first so a
  /// portable build stays self-contained; an installed build whose directory
  /// is read-only falls back to `%LOCALAPPDATA%`. A failure here is logged
  /// rather than fatal — the engine can still download the DLL — but it is
  /// what makes TUN work on a machine with no route to wintun.net.
  Future<void> _installWintunLibrary() async {
    if (!Platform.isWindows) return;
    try {
      final data = await rootBundle.load(_wintunAsset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.isEmpty) {
        throw const FormatException('bundled wintun.dll is empty');
      }

      final executableDirectory = File(Platform.resolvedExecutable).parent;
      final beside = File(
        '${executableDirectory.path}${Platform.pathSeparator}wintun.dll',
      );
      if (await _writeIfChanged(beside, bytes)) {
        debugPrint('wintun.dll staged at ${beside.path}');
        return;
      }

      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) {
        debugPrint('wintun.dll could not be staged: LOCALAPPDATA is unset');
        return;
      }
      final fallbackDirectory = Directory(
        '$localAppData${Platform.pathSeparator}ArcadiaPlus',
      );
      await fallbackDirectory.create(recursive: true);
      final fallback = File(
        '${fallbackDirectory.path}${Platform.pathSeparator}wintun.dll',
      );
      if (await _writeIfChanged(fallback, bytes)) {
        debugPrint('wintun.dll staged at ${fallback.path}');
      }
    } catch (error) {
      debugPrint(
        'wintun.dll staging failed; the engine may download it instead: $error',
      );
    }
  }

  /// Writes [bytes] only when the target is absent or different.
  ///
  /// The comparison is content-based rather than length-based so a driver
  /// upgrade that happens to keep its size still lands, and an unchanged
  /// binary is not rewritten on every start (which anti-virus suites read as
  /// suspicious behaviour). Returns whether the target now holds [bytes].
  Future<bool> _writeIfChanged(File target, Uint8List bytes) async {
    try {
      if (target.existsSync()) {
        final existing = await target.readAsBytes();
        if (existing.length == bytes.length && _bytesEqual(existing, bytes)) {
          return true;
        }
      }
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static int _fingerprint(Uint8List bytes) {
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash = (hash ^ byte) * 0x100000001b3;
    }
    return hash;
  }
}
