import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Older builds stored each YAML twice: a file and a JSON preference retained
/// by SharedPreferences for the process lifetime. Keep metadata in preferences
/// and recover any missing file before removing the legacy backup.
Future<void> migrateProfileMetadata(
  SharedPreferences preferences,
  Directory profilesDirectory,
) async {
  final source = preferences.getString('profiles');
  if (source == null || !source.contains('"configContent"')) return;
  final decoded = jsonDecode(source);
  if (decoded is! List) throw const FormatException('Invalid profile metadata');
  final safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
  // Validate the complete record before writing any files. A malformed entry
  // must not redirect recovery outside the app's profile directory.
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic> ||
        entry['id'] is! String ||
        !safeId.hasMatch(entry['id'] as String) ||
        (entry['configContent'] != null && entry['configContent'] is! String)) {
      throw const FormatException('Invalid legacy profile record');
    }
  }
  final directoryType = await FileSystemEntity.type(
    profilesDirectory.path,
    followLinks: false,
  );
  if (directoryType != FileSystemEntityType.directory &&
      directoryType != FileSystemEntityType.notFound) {
    throw const FileSystemException(
      'Profile directory is not a regular directory',
    );
  }
  await profilesDirectory.create(recursive: true);
  for (final entry in decoded.cast<Map<String, dynamic>>()) {
    final content = entry['configContent'] as String?;
    if (content != null && content.isNotEmpty) {
      final file = File('${profilesDirectory.path}/${entry['id']}.yaml');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const FileSystemException('Profile is not a regular file');
      }
      if (type == FileSystemEntityType.notFound || await file.length() == 0) {
        await _writeRecovered(file, content);
      } else if (!await _containsContent(file, content)) {
        // A newer edit on disk may differ from the preference. Preserve both
        // versions, moving the legacy value out of the resident JSON store.
        final backup = File(
          '${profilesDirectory.path}/${entry['id']}.legacy.yaml',
        );
        final backupType = await FileSystemEntity.type(
          backup.path,
          followLinks: false,
        );
        if (backupType == FileSystemEntityType.notFound) {
          await _writeRecovered(backup, content);
        } else if (backupType != FileSystemEntityType.file ||
            !await _containsContent(backup, content)) {
          throw const FileSystemException(
            'A different legacy profile backup exists',
          );
        }
      }
    }
    entry.remove('configContent');
  }
  if (!await preferences.setString('profiles', jsonEncode(decoded))) {
    throw const FileSystemException(
      'Could not commit profile metadata migration',
    );
  }
}

Future<void> _writeRecovered(File file, String content) async {
  final temporary = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.migration.tmp',
  );
  if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FileSystemException('Profile recovery file already exists');
  }
  try {
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<bool> _containsContent(File file, String content) async {
  var offset = 0;
  try {
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      if (!content.startsWith(chunk, offset)) return false;
      offset += chunk.length;
    }
    return offset == content.length;
  } on FormatException {
    return false;
  }
}
