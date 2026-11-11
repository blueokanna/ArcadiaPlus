import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Fonts ship with the app: the first frame never waits for a font download.
abstract final class AppTypography {
  static const family = 'Google Sans Flex';
  static const codeFamily = 'Google Sans Code';
  static const fallback = ['Noto Sans SC'];
  static bool _registered = false;

  static void registerLicenses() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      for (final (family, asset) in [
        ('Google Sans Flex', 'assets/fonts/LICENSE-GoogleSansFlex.txt'),
        ('Noto Sans SC', 'assets/fonts/LICENSE-NotoSansSC.txt'),
        ('Google Sans Code', 'assets/fonts/LICENSE-GoogleSansCode.txt'),
      ]) {
        yield LicenseEntryWithLineBreaks([
          family,
        ], await rootBundle.loadString(asset));
      }
    });
  }
}
