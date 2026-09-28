import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FileImage;
import 'package:arcadiaplus/src/services/storage_service.dart';

class WallpaperService {
  WallpaperService._();

  static final WallpaperService instance = WallpaperService._();
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

    // The stored name changes with every pick. Flutter's decoder caches a
    // decoded bitmap under the file path, so re-using `wallpaper.png` for a
    // new picture keeps handing back the old bitmap until the cache entry
    // ages out — which is exactly the "the wallpaper does not change" this
    // flow used to show. A fresh path is a fresh cache entry, every time.
    final destination = File(
      '${directory.path}/wallpaper_'
      '${DateTime.now().microsecondsSinceEpoch}'
      '${_extensionOf(picked.name)}',
    );

    try {
      final path = picked.path;
      if (path != null) {
        await File(path).copy(destination.path);
      } else {
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
    } catch (_) {
      try {
        if (await destination.exists()) await destination.delete();
      } catch (error) {
        debugPrint('Failed to remove the partial wallpaper copy: $error');
      }
      rethrow;
    }

    await for (final entity in directory.list()) {
      if (entity is File && entity.path != destination.path) {
        try {
          await entity.delete();
        } catch (error) {
          debugPrint('Failed to remove an old wallpaper copy: $error');
        }
      }
    }
    return destination.path;
  }

  /// The file name extension to store a file called [fileName] under.
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

  /// Drops the decoded copy of the picture at [path] from the image cache.
  static Future<void> forgetImage(String path) async {
    try {
      await FileImage(File(path)).evict();
    } catch (error) {
      debugPrint('Failed to forget the wallpaper image "$path": $error');
    }
  }

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
