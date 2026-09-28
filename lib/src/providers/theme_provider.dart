import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'selected_theme';
  static const String _dynamicColorsKey = 'use_dynamic_colors';

  String _selectedTheme = AppTheme.defaultTheme;
  bool _useDynamicColors = false;
  bool? _dynamicColorAvailable;
  bool _disposed = false;

  ThemeProvider() {
    _loadSettings();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String get selectedTheme => _selectedTheme;
  bool get useDynamicColors => _useDynamicColors;

  /// Whether the platform produced a dynamic palette on its last report.
  ///
  /// Null means "not known yet": the platform query is asynchronous, and
  /// treating the absence of an answer as an answer would disable the switch
  /// for the first frame on devices that do support it. Only an explicit
  /// false — reported once the builder has actually seen a null palette —
  /// disables it and explains why.
  bool? get dynamicColorAvailable => _dynamicColorAvailable;

  /// Records what the dynamic-colour builder last received. Called once per
  /// palette change, so "unavailable" is a statement about the platform
  /// rather than about the current moment of the query.
  ///
  /// The availability report is scheduled as a post-frame callback, and the
  /// one that is still in flight when the app goes away would otherwise call
  /// `notifyListeners` on a disposed notifier.
  void setDynamicColorAvailable(bool value) {
    if (_disposed || _dynamicColorAvailable == value) return;
    _dynamicColorAvailable = value;
    notifyListeners();
  }

  // Available themes
  List<String> get availableThemes => AppTheme.allThemes;

  String getThemeDisplayName(String themeName) {
    return AppTheme.getThemeDisplayName(themeName);
  }

  Color getThemeSeedColor(String themeName) {
    return AppTheme.getThemeSeedColor(themeName);
  }

  /// The palette a theme resolves to, for the picker's swatches.
  ColorScheme getThemePreviewScheme(String themeName, Brightness brightness) {
    return AppTheme.previewScheme(themeName, brightness);
  }

  /// The palette of the theme in use, for the settings row.
  ColorScheme get currentThemePreviewScheme =>
      AppTheme.previewScheme(_selectedTheme, _previewBrightness);

  /// The brightness the last built theme used. Defaults to light so the row
  /// has something plausible to draw before the first theme is built.
  Brightness _previewBrightness = Brightness.light;

  /// Remembers which brightness the app is actually in, so the settings row
  /// previews the theme the user is looking at rather than the other one.
  void setPreviewBrightness(Brightness brightness) {
    if (_previewBrightness == brightness) return;
    _previewBrightness = brightness;
  }

  void setTheme(String themeName) {
    if (_selectedTheme != themeName && availableThemes.contains(themeName)) {
      _selectedTheme = themeName;
      _saveSettings();
      notifyListeners();
    }
  }

  void setUseDynamicColors(bool useDynamic) {
    if (_useDynamicColors != useDynamic) {
      _useDynamicColors = useDynamic;
      _saveSettings();
      notifyListeners();
    }
  }

  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedTheme = prefs.getString(_themeKey) ?? AppTheme.defaultTheme;
    _useDynamicColors = prefs.getBool(_dynamicColorsKey) ?? false;
    notifyListeners();
  }

  void _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, _selectedTheme);
    await prefs.setBool(_dynamicColorsKey, _useDynamicColors);
  }

  // Get the current theme data
  ThemeData getCurrentTheme(Brightness brightness) {
    return AppTheme.createTheme(_selectedTheme, brightness);
  }

  // Cycle to next theme
  void cycleTheme() {
    final currentIndex = availableThemes.indexOf(_selectedTheme);
    final nextIndex = (currentIndex + 1) % availableThemes.length;
    setTheme(availableThemes[nextIndex]);
  }
}
