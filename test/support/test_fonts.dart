import 'package:flutter/services.dart';

Future<void> loadAppFonts() async {
  for (final (family, asset) in [
    ('Google Sans Flex', 'assets/fonts/GoogleSansFlex.ttf'),
    ('Noto Sans SC', 'assets/fonts/NotoSansSC.ttf'),
    ('Google Sans Code', 'assets/fonts/GoogleSansCode.ttf'),
    ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
  ]) {
    await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
  }
}
