import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/services/profile_metadata_migration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'legacy YAML is recovered before duplicate preferences are removed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arcadia-metadata-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/existing.yaml').writeAsString('newer file');
      SharedPreferences.setMockInitialValues({
        'profiles': jsonEncode([
          {
            'id': 'existing',
            'name': 'Existing',
            'configContent': 'older backup',
          },
          {
            'id': 'missing',
            'name': 'Recovered',
            'configContent': 'recovered YAML',
          },
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      await migrateProfileMetadata(prefs, directory);
      expect(
        await File('${directory.path}/existing.yaml').readAsString(),
        'newer file',
      );
      expect(
        await File('${directory.path}/existing.legacy.yaml').readAsString(),
        'older backup',
      );
      expect(
        await File('${directory.path}/missing.yaml').readAsString(),
        'recovered YAML',
      );
      final metadata = prefs.getString('profiles')!;
      expect(metadata, isNot(contains('configContent')));
      expect(metadata, contains('Recovered'));
      await migrateProfileMetadata(prefs, directory);
      expect(prefs.getString('profiles'), metadata);
    },
  );
  test(
    'invalid IDs preserve the backup and cannot escape the profile directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'arcadia-metadata-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = jsonEncode([
        {'id': '../escape', 'configContent': 'private'},
      ]);
      SharedPreferences.setMockInitialValues({'profiles': source});
      final prefs = await SharedPreferences.getInstance();
      await expectLater(
        migrateProfileMetadata(prefs, directory),
        throwsFormatException,
      );
      expect(prefs.getString('profiles'), source);
      expect(await directory.list().toList(), isEmpty);
    },
  );
}
