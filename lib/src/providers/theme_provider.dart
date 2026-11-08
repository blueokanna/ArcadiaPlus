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
  int _revision = 0;
  Future<void> _pendingSave = Future<void>.value();

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
    if (!_disposed &&
        _selectedTheme != themeName &&
        availableThemes.contains(themeName)) {
      _revision++;
      _selectedTheme = themeName;
      _saveSettings();
      notifyListeners();
    }
  }

  void setUseDynamicColors(bool useDynamic) {
    if (!_disposed && _useDynamicColors != useDynamic) {
      _revision++;
      _useDynamicColors = useDynamic;
      _saveSettings();
      notifyListeners();
    }
  }

  Future<void> _loadSettings() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || revision != _revision) return;
      final saved = prefs.getString(_themeKey);
      _selectedTheme = availableThemes.contains(saved)
          ? saved!
          : AppTheme.defaultTheme;
      _useDynamicColors = prefs.getBool(_dynamicColorsKey) ?? false;
      notifyListeners();
    } catch (error) {
      debugPrint('Unable to load theme preferences: $error');
    }
  }

  void _saveSettings() {
    final selected = _selectedTheme;
    final dynamic = _useDynamicColors;
    // Preserve selection order even when the platform store responds slowly.
    _pendingSave = _pendingSave
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(_themeKey, selected) ||
              !await prefs.setBool(_dynamicColorsKey, dynamic)) {
            throw StateError('Theme preferences were not saved');
          }
        })
        .catchError((Object error) {
          debugPrint('Unable to save theme preferences: $error');
        });
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
