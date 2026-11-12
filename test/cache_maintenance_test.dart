import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/cache_maintenance.dart';

void main() {
  test(
    'maintenance preserves active files and only removes expired owned cache',
    () async {
      final root = await Directory.systemTemp.createTemp('arcadia-cache-test-');
      addTearDown(() => root.delete(recursive: true));
      final now = DateTime.now();
      Future<File> file(String relative, {bool old = true}) async {
        final f = File('${root.path}/$relative');
        await f.parent.create(recursive: true);
        await f.writeAsString('fixture');
        await f.setLastModified(now.subtract(Duration(hours: old ? 25 : 1)));
        return f;
      }

      final stale = await file('rule-providers/p/r.hash.rules.tmp');
      final staleMeta = await file('rule-providers/p/r.meta.json.tmp');
      final previousWallpaper = await file('wallpapers/wallpaper_1.png');
      final currentWallpaper = await file('wallpapers/wallpaper_2.png');
      final preserved = [
        currentWallpaper,
        await file('wallpapers/wallpaper_3.png', old: false),
        await file('wallpapers/my_photo.png'),
        await file('rule-providers/p/r.hash.rules'),
        await file('rule-providers/p/r.meta.json'),
        await file('rule-providers/p/r.new.rules.tmp', old: false),
        await file('profiles/user.yaml'),
        await file('config/user.tmp'),
      ];
      await CacheMaintenance.clean(
        root,
        now: now,
        wallpaperPath: currentWallpaper.path,
      );
      for (final f in [stale, staleMeta, previousWallpaper]) {
        expect(await f.exists(), isFalse, reason: f.path);
      }
      for (final f in preserved) {
        expect(await f.exists(), isTrue, reason: f.path);
      }
    },
  );
}
