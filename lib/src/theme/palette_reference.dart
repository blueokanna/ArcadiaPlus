import 'package:flutter/painting.dart';

/// Screen approximations sampled from the supplied CMYK simulation PDF with
/// MuPDF's sRGB renderer. These are not certified Pantone RGB definitions.
class PaletteReference {
  const PaletteReference(this.number, this.seed, this.page);
  final String number;
  final Color seed;
  final int page;
  String get label => 'PANTONE $number C';

  static const values = <String, PaletteReference>{
    'default': PaletteReference('286', Color(0xFF0060A9), 6),
    'ocean': PaletteReference('3005', Color(0xFF0081C4), 7),
    'forest': PaletteReference('347', Color(0xFF009A66), 8),
    'sunset': PaletteReference('179', Color(0xFFF15C2A), 3),
    'purple': PaletteReference('2587', Color(0xFF6351A2), 5),
    'teal': PaletteReference('320', Color(0xFF00A1B2), 7),
    'rose': PaletteReference('213', Color(0xFFEC0B6D), 4),
    'amber': PaletteReference('123', Color(0xFFFDB826), 1),
    'indigo': PaletteReference('2756', Color(0xFF173B8D), 6),
    'cyan': PaletteReference('3125', Color(0xFF00B5C8), 7),
  };

  static PaletteReference forTheme(String id) =>
      values[id] ?? values['default']!;
}
