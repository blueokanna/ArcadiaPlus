import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/app_lifecycle.dart';
import 'storage_service.dart';

/// Reclaims abandoned app-owned files, never live rule sets or user profiles.
/// Runs on foreground entry at most once per day, without a periodic timer.
class CacheMaintenance {
  CacheMaintenance._();
  static final instance = CacheMaintenance._();
  DateTime? _lastRun;
  bool _running = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    AppLifecycle.instance.active.addListener(_onForeground);
    _onForeground();
  }

  void _onForeground() {
    if (AppLifecycle.instance.isActive) unawaited(_run());
  }

  Future<void> _run() async {
    final now = DateTime.now();
    if (_running ||
        (_lastRun != null &&
            now.difference(_lastRun!) < const Duration(days: 1))) {
      return;
    }
    final root = StorageService.instance.dataDirectory;
    if (root.isEmpty) return;
    _running = true;
    _lastRun = now;
    try {
      final wallpaper = await StorageService.instance.getWallpaperSettings();
      await clean(
        Directory(root),
        now: now,
        wallpaperPath: wallpaper.imagePath,
      );
    } catch (error) {
      debugPrint('Cache maintenance: $error');
    } finally {
      _running = false;
    }
  }

  @visibleForTesting
  static Future<void> clean(
    Directory root, {
    required DateTime now,
    String? wallpaperPath,
  }) async {
    final cutoff = now.subtract(const Duration(days: 1));
    String pathKey(String path) {
      final normalized = File(path).absolute.uri.normalizePath().toString();
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final selectedWallpaper = wallpaperPath == null
        ? null
        : pathKey(wallpaperPath);
    Future<void> removeOld(File file) async {
      try {
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return;
        }
        if ((await file.stat()).modified.isBefore(cutoff)) await file.delete();
      } on FileSystemException catch (error) {
        debugPrint('Cache file retained: $error');
      }
    }

    Future<bool> plainDirectory(Directory dir) async =>
        await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.directory;

    if (!await plainDirectory(root)) return;
    final profiles = Directory('${root.path}/profiles');
    if (await plainDirectory(profiles)) {
      await for (final file in profiles.list(followLinks: false)) {
        if (file is File && file.path.endsWith('.migration.tmp')) {
          await removeOld(file);
        }
      }
    }
    final rules = Directory('${root.path}/rule-providers');
    if (await plainDirectory(rules)) {
      await for (final profile in rules.list(followLinks: false)) {
        if (profile is! Directory || !await plainDirectory(profile)) continue;
        await for (final file in profile.list(followLinks: false)) {
          if (file is File &&
              (file.path.endsWith('.rules.tmp') ||
                  file.path.endsWith('.meta.json.tmp'))) {
            await removeOld(file);
          }
        }
      }
    }
    final wallpapers = Directory('${root.path}/wallpapers');
    if (await plainDirectory(wallpapers)) {
      await for (final file in wallpapers.list(followLinks: false)) {
        if (file is! File || pathKey(file.path) == selectedWallpaper) {
          continue;
        }
        if (RegExp(r'^wallpaper_\d+\.[a-z0-9]+$')
            .hasMatch(file.uri.pathSegments.last)) {
          await removeOld(file);
        }
      }
    }
  }
}
