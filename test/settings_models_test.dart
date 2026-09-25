import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

void main() {
  group('DnsSettings defaults', () {
    test('a fresh install starts with more than one upstream family', () {
      final settings = DnsSettings();

      expect(settings.nameservers, DnsSettings.defaultNameservers);
      expect(settings.nameservers.length, greaterThan(2));
      expect(
        settings.nameserversRevision,
        DnsSettings.nameserverDefaultsRevision,
      );
    });

    test('an unknown stored mode falls back instead of reaching the picker', () {
      expect(DnsSettings.normaliseMode('fake-ip'), 'fake-ip');
      // The engine has no `redir-host` variant; it is one of the spellings the
      // FFI layer maps onto `normal`, so it has to survive being read back.
      expect(DnsSettings.normaliseMode('redir-host'), 'redir-host');
      expect(DnsSettings.normaliseMode('nonsense'), DnsSettings.defaultMode);
      expect(DnsSettings.normaliseMode(null), DnsSettings.defaultMode);
    });
  });

  group('DnsSettings default-upstream migration', () {
    /// A record as an earlier build wrote it: the old pair, no revision.
    Map<String, dynamic> legacyRecord(List<String> nameservers) => {
      'dnsMode': 'redir-host',
      'nameservers': nameservers,
      'fallback': <String>[],
    };

    test('the untouched legacy pair grows to the current defaults', () {
      final settings = DnsSettings.fromJson(
        legacyRecord(const [
          'https://dns.google/dns-query',
          'https://cloudflare-dns.com/dns-query',
        ]),
      );

      expect(settings.nameserversRevision, 1);
      final migrated = settings.withCurrentNameserverDefaults();
      expect(migrated.nameservers, DnsSettings.defaultNameservers);
      expect(
        migrated.nameserversRevision,
        DnsSettings.nameserverDefaultsRevision,
      );
    });

    test("the user's own list is stamped, not extended", () {
      const own = ['tls://1.1.1.1', 'https://dns.quad9.net/dns-query'];
      final migrated = DnsSettings.fromJson(
        legacyRecord(own),
      ).withCurrentNameserverDefaults();

      expect(migrated.nameservers, own);
      expect(
        migrated.nameserversRevision,
        DnsSettings.nameserverDefaultsRevision,
      );
    });

    test('an emptied list stays empty', () {
      final migrated = DnsSettings.fromJson(
        legacyRecord(const []),
      ).withCurrentNameserverDefaults();

      expect(migrated.nameservers, isEmpty);
    });

    test('a record already at the current revision is returned untouched', () {
      final settings = DnsSettings.fromJson({
        'nameservers': const ['1.1.1.1'],
        'nameserversRevision': DnsSettings.nameserverDefaultsRevision,
      });

      expect(
        identical(settings.withCurrentNameserverDefaults(), settings),
        isTrue,
      );
    });

    test('the round trip keeps the revision', () {
      final settings = DnsSettings(
        nameservers: const ['1.1.1.1'],
        fallback: const ['9.9.9.9'],
      );
      final restored = DnsSettings.fromJson(settings.toJson());

      expect(restored.nameservers, settings.nameservers);
      expect(restored.fallback, settings.fallback);
      expect(restored.nameserversRevision, settings.nameserversRevision);
    });
  });

  group('WallpaperSettings', () {
    test('a fresh record has no picture to draw', () {
      const settings = WallpaperSettings();
      expect(settings.hasImage, isFalse);
      expect(settings.isVisible, isFalse);
    });

    test('isVisible needs a picture and the switch', () {
      const settings = WallpaperSettings(imagePath: '/tmp/a.png');
      expect(settings.isVisible, isTrue);
      expect(settings.copyWith(enabled: false).isVisible, isFalse);
    });

    test('copyWith can clear the picture', () {
      const settings = WallpaperSettings(imagePath: '/tmp/a.png');
      expect(settings.copyWith(imagePath: null).hasImage, isFalse);
      expect(settings.copyWith().imagePath, '/tmp/a.png');
    });

    test('values out of range are clamped on read, not trusted', () {
      final settings = WallpaperSettings.fromJson({
        'imagePath': '/tmp/a.png',
        'blur': 900,
        'dim': -4,
      });

      expect(settings.blur, WallpaperSettings.maxBlur);
      expect(settings.dim, 0);
    });

    test('a nonsense number falls back to the default', () {
      final settings = WallpaperSettings.fromJson({'blur': double.nan});
      expect(settings.blur, 18);
    });
  });
}
