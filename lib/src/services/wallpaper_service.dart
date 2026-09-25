import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

/// Owns the wallpaper file: picking one, keeping a copy the app controls, and
/// removing the copy when it is no longer wanted.
///
/// The copy matters. A path returned by a picker on Android or iOS points into
/// a cache directory that the OS is allowed to reclaim at any time, and a
/// background that disappears on its own is worse than no background. Everything
/// is stored under `<support>/wallpapers/`, which is private to the app and
/// survives until the app is uninstalled.
class WallpaperService {
  WallpaperService._();

  static final WallpaperService instance = WallpaperService._();

  /// Extensions [FilePicker] can hand back and Flutter can decode. Anything
  /// outside this set keeps its file name extension only if it is a safe,
  /// short one — the decoder sniffs the bytes, so the extension is a label,
  /// not a contract, but a path built from arbitrary user input is not
  /// something to write into the app's own directory unexamined.
  static const Set<String> _knownExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
    '.heif',
    '.avif',
  };

  static const String _directoryName = 'wallpapers';

  /// Opens the platform file picker and stores the chosen picture.
  ///
  /// Returns the stored path, or null when the user cancelled. Throws only for
  /// a real failure to store — a cancelled dialog is not an error.
  Future<String?> pickAndStore() async {
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return null;

    final directory = Directory(
      '${StorageService.instance.dataDirectory}/$_directoryName',
    );
    await directory.create(recursive: true);

    final destination = File(
      '${directory.path}/wallpaper${_extensionOf(picked.name)}',
    );

    // One wallpaper at a time: a leftover copy under a different extension
    // would sit in the app's directory for good, unreferenced.
    await for (final entity in directory.list()) {
      if (entity is File && entity.path != destination.path) {
        await entity.delete();
      }
    }

    final path = picked.path;
    if (path != null) {
      await File(path).copy(destination.path);
    } else {
      // A picker that hands back a `content://` URI has no path to copy from;
      // the bytes are written through instead, which is the same result
      // without depending on the platform keeping a readable file around.
      final sink = destination.openWrite();
      try {
        await picked
            .readAsByteStream()
            .map<List<int>>((bytes) => bytes)
            .pipe(sink);
      } finally {
        await sink.close();
      }
    }
    return destination.path;
  }

  /// The file name extension to store a file called [fileName] under.
  ///
  /// Keeps an extension only when it is one this app recognises or a short,
  /// plain one; `wallpaper.tar.gz` is stored as `.gz`, not as `.tar.gz`.
  static String _extensionOf(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot < 0 || lastDot == fileName.length - 1) return '.img';

    final extension = fileName.substring(lastDot).toLowerCase();
    if (_knownExtensions.contains(extension)) return extension;
    if (extension.length <= 5 && _plainExtension.hasMatch(extension)) {
      return extension;
    }
    return '.img';
  }

  static final RegExp _plainExtension = RegExp(r'^\.[a-z0-9]+$');

  /// Whether the wallpaper behind [path] is still readable.
  Future<bool> isReadable(String path) async {
    try {
      return await File(path).exists();
    } catch (error) {
      debugPrint('Wallpaper "$path" is not readable: $error');
      return false;
    }
  }

  /// Deletes every stored wallpaper. Failures are logged, not thrown: the
  /// settings are already updated by the time this runs, and an orphaned file
  /// is a smaller problem than a settings screen that cannot finish.
  Future<void> deleteStored() async {
    final directory = Directory(
      '${StorageService.instance.dataDirectory}/$_directoryName',
    );
    try {
      if (!await directory.exists()) return;
      await directory.delete(recursive: true);
    } catch (error) {
      debugPrint('Failed to delete the stored wallpaper: $error');
    }
  }
}
