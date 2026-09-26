import 'package:arcadiaplus/src/theme/app_shapes.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppTheme {
  static const String _fontFamily = 'Roboto';

  /// Alpha of the interface's background layers while a wallpaper is showing.
  ///
  /// Translucent enough that the picture reads through, dense enough that text
  /// keeps its contrast against whatever the picture happens to be there. A
  /// surface that stayed opaque would hide the wallpaper completely, which is
  /// the whole reason this exists.
  static const double wallpaperSurfaceAlpha = 0.78;

  static TextStyle _textStyle({
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  // Theme names
  static const String defaultTheme = 'default';
  static const String oceanTheme = 'ocean';
  static const String forestTheme = 'forest';
  static const String sunsetTheme = 'sunset';
  static const String purpleTheme = 'purple';
  static const String tealTheme = 'teal';
  static const String roseTheme = 'rose';
  static const String amberTheme = 'amber';
  static const String indigoTheme = 'indigo';
  static const String cyanTheme = 'cyan';

  // All available themes
  static const List<String> allThemes = [
    defaultTheme,
    oceanTheme,
    forestTheme,
    sunsetTheme,
    purpleTheme,
    tealTheme,
    roseTheme,
    amberTheme,
    indigoTheme,
    cyanTheme,
  ];

  // Theme display names
  static String getThemeDisplayName(String themeName) {
    switch (themeName) {
      case oceanTheme:
        return 'Ocean Blue';
      case forestTheme:
        return 'Forest Green';
      case sunsetTheme:
        return 'Sunset Red';
      case purpleTheme:
        return 'Deep Purple';
      case tealTheme:
        return 'Teal';
      case roseTheme:
        return 'Rose Pink';
      case amberTheme:
        return 'Amber';
      case indigoTheme:
        return 'Indigo';
      case cyanTheme:
        return 'Cyan';
      default:
        return 'Default Blue';
    }
  }

  // Theme seed colors for preview
  static Color getThemeSeedColor(String themeName) {
    switch (themeName) {
      case oceanTheme:
        return const Color(0xFF0061A4);
      case forestTheme:
        return const Color(0xFF146C2E);
      case sunsetTheme:
        return const Color(0xFF8F4A4A);
      case purpleTheme:
        return const Color(0xFF6750A4);
      case tealTheme:
        return const Color(0xFF006A6A);
      case roseTheme:
        return const Color(0xFFB4004E);
      case amberTheme:
        return const Color(0xFF7D5700);
      case indigoTheme:
        return const Color(0xFF3F51B5);
      case cyanTheme:
        return const Color(0xFF006978);
      default:
        return const Color(0xFF1976D2);
    }
  }

  // Generate ColorScheme from seed color using Material 3
  static ColorScheme _generateColorScheme(
    String themeName,
    Brightness brightness,
  ) {
    final seedColor = getThemeSeedColor(themeName);
    return ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  }

  /// The palette [themeName] resolves to in [brightness], for a preview.
  ///
  /// Cached because `ColorScheme.fromSeed` is HCT arithmetic, not a lookup: a
  /// grid of ten themes would otherwise run it twenty times per rebuild just
  /// to draw the swatches. The cache is bounded by the theme list, which is a
  /// compile-time constant.
  static ColorScheme previewScheme(String themeName, Brightness brightness) {
    final key = '$themeName:${brightness.name}';
    return _previewSchemes[key] ??= _generateColorScheme(themeName, brightness);
  }

  static final Map<String, ColorScheme> _previewSchemes = {};

  /// The built [ThemeData] for a named theme and brightness.
  ///
  /// Memoised for the same reason as [previewScheme], only more so: this builds
  /// a colour scheme and twenty-odd sub-themes, and the app asks for both
  /// brightnesses every time the locale or the theme mode changes. [ThemeData]
  /// is immutable, so handing out the same instance is safe.
  static ThemeData createTheme(String themeName, Brightness brightness) {
    final key = '$themeName:${brightness.name}';
    return _themes[key] ??= _buildThemeData(
      _generateColorScheme(themeName, brightness),
      brightness,
    );
  }

  static final Map<String, ThemeData> _themes = {};

  // Create theme data for a specific theme
  //
  // Implemented by the memoised [createTheme] above; this used to build the
  // theme on every call, which is what the cache avoids.

  // Create dynamic theme from system colors
  static ThemeData createDynamicTheme(
    ColorScheme? dynamicColorScheme,
    Brightness brightness,
  ) {
    if (dynamicColorScheme != null) {
      return _buildThemeData(dynamicColorScheme, brightness);
    }
    return createTheme(defaultTheme, brightness);
  }

  /// Returns [base] with its background layers made translucent, so a wallpaper
  /// drawn behind the app shows through.
  ///
  /// Only the layers that sit *under* content are changed. Text, icons, and the
  /// contrast between a container and what is written on it come from the
  /// colour scheme and stay exactly as they were; what changes is that a card
  /// is a veil over the picture instead of a lid on it.
  ///
  /// Memoised per base theme: the derivation runs on every rebuild of the
  /// `MaterialApp` while a wallpaper is showing, and [ThemeData] is immutable,
  /// so the result for one base theme is always the same. An [Expando] rather
  /// than a map, so a theme nothing uses any more does not stay alive to keep
  /// its entry alive with it.
  static ThemeData withTranslucentSurfaces(ThemeData base) =>
      _translucent[base] ??= _deriveTranslucent(base);

  static final Expando<ThemeData> _translucent = Expando<ThemeData>(
    'wallpaper surfaces',
  );

  static ThemeData _deriveTranslucent(ThemeData base) {
    final scheme = base.colorScheme;
    Color veil(Color color) => color.withValues(alpha: wallpaperSurfaceAlpha);

    return base.copyWith(
      // The page background itself is the wallpaper, so the scaffold stops
      // painting over it.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: veil(scheme.surfaceContainerLow),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: veil(scheme.surfaceContainerHigh),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: veil(scheme.surfaceContainerLow),
        modalBackgroundColor: veil(scheme.surfaceContainerLow),
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        color: veil(scheme.surfaceContainerHigh),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: Colors.transparent,
      ),
      extensions: [
        ...base.extensions.values.where(
          (extension) => extension is! WallpaperSurface,
        ),
        const WallpaperSurface(alpha: wallpaperSurfaceAlpha),
      ],
    );
  }

  // Build complete ThemeData from ColorScheme
  static ThemeData _buildThemeData(
    ColorScheme colorScheme,
    Brightness brightness,
  ) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: _fontFamily,
      textTheme: _createTextTheme(colorScheme),
      pageTransitionsTheme: _createPageTransitionsTheme(),
      splashFactory: _splashFactory(),
      appBarTheme: _createAppBarTheme(colorScheme),
      cardTheme: _createCardTheme(colorScheme),
      listTileTheme: _createListTileTheme(colorScheme),
      dividerTheme: _createDividerTheme(colorScheme),
      switchTheme: _createSwitchTheme(colorScheme),
      dropdownMenuTheme: _createDropdownMenuTheme(colorScheme),
      popupMenuTheme: _createPopupMenuTheme(colorScheme),
      iconButtonTheme: _createIconButtonTheme(colorScheme),
      segmentedButtonTheme: _createSegmentedButtonTheme(colorScheme),
      elevatedButtonTheme: _createElevatedButtonTheme(colorScheme),
      filledButtonTheme: _createFilledButtonTheme(colorScheme),
      outlinedButtonTheme: _createOutlinedButtonTheme(colorScheme),
      textButtonTheme: _createTextButtonTheme(colorScheme),
      floatingActionButtonTheme: _createFabTheme(colorScheme),
      navigationBarTheme: _createNavigationBarTheme(colorScheme),
      navigationRailTheme: _createNavigationRailTheme(colorScheme),
      bottomSheetTheme: _createBottomSheetTheme(colorScheme),
      dialogTheme: _createDialogTheme(colorScheme),
      snackBarTheme: _createSnackBarTheme(colorScheme),
      chipTheme: _createChipTheme(colorScheme),
      inputDecorationTheme: _createInputDecorationTheme(colorScheme),
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      primaryIconTheme: IconThemeData(color: colorScheme.primary),
      scaffoldBackgroundColor: colorScheme.surface,
      canvasColor: colorScheme.surface,
      splashColor: colorScheme.primary.withValues(alpha: 0.08),
      highlightColor: colorScheme.primary.withValues(alpha: 0.04),
      hoverColor: colorScheme.primary.withValues(alpha: 0.04),
      focusColor: colorScheme.primary.withValues(alpha: 0.12),
      tooltipTheme: TooltipThemeData(
        decoration: ShapeDecoration(
          color: colorScheme.inverseSurface,
          shape: AppShapes.card,
        ),
        textStyle: _textStyle(
          fontSize: 12,
          color: colorScheme.onInverseSurface,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  /// Material 3's fade-forwards transition wherever the framework drives the
  /// route. The app's own screens ride go_router's expressive page builder
  /// (`_buildExpressivePage`); this covers everything else — a
  /// `MaterialPageRoute`, a full-screen dialog route, a platform default.
  ///
  /// Apple platforms keep their own builders: the interactive back-swipe and
  /// the parallax are platform behaviour, not a theme choice.
  static PageTransitionsTheme _createPageTransitionsTheme() {
    return const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    );
  }

  /// M3's expressive ripple on the platform that renders it.
  ///
  /// `InkSparkle` is an Android-only shader; everywhere else the classic
  /// ripple is the correct fallback.
  static InteractiveInkFeatureFactory _splashFactory() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return InkSparkle.splashFactory;
    }
    return InkRipple.splashFactory;
  }

  static TextTheme _createTextTheme(ColorScheme colorScheme) {
    return const TextTheme().copyWith(
      displayLarge: _textStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurface,
      ),
      displayMedium: _textStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurface,
      ),
      displaySmall: _textStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurface,
      ),
      headlineLarge: _textStyle(
        fontSize: 32,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurface,
      ),
      headlineMedium: _textStyle(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurface,
      ),
      headlineSmall: _textStyle(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurface,
      ),
      titleLarge: _textStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      titleMedium: _textStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.15,
        color: colorScheme.onSurface,
      ),
      titleSmall: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
      ),
      labelLarge: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: colorScheme.onSurface,
      ),
      labelMedium: _textStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
      ),
      labelSmall: _textStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: colorScheme.onSurface,
      ),
      bodyLarge: _textStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.15,
        color: colorScheme.onSurface,
      ),
      bodyMedium: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        color: colorScheme.onSurface,
      ),
      bodySmall: _textStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  static AppBarTheme _createAppBarTheme(ColorScheme colorScheme) {
    return AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      titleTextStyle: _textStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      actionsIconTheme: IconThemeData(color: colorScheme.onSurface),
    );
  }

  static CardThemeData _createCardTheme(ColorScheme colorScheme) {
    return CardThemeData(
      elevation: 0,
      shape: AppShapes.card,
      color: colorScheme.surfaceContainerLow,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
    );
  }

  static ListTileThemeData _createListTileTheme(ColorScheme colorScheme) {
    return ListTileThemeData(
      tileColor: Colors.transparent,
      selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
      iconColor: colorScheme.onSurfaceVariant,
      textColor: colorScheme.onSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: AppShapes.control,
    );
  }

  static DividerThemeData _createDividerTheme(ColorScheme colorScheme) {
    return DividerThemeData(
      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
      thickness: 1,
      space: 1,
    );
  }

  static SwitchThemeData _createSwitchTheme(ColorScheme colorScheme) {
    return SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.onPrimary;
        }
        return colorScheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.primary;
        }
        return colorScheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return Colors.transparent;
        }
        return colorScheme.outline;
      }),
      trackOutlineWidth: WidgetStateProperty.all(2),
    );
  }

  static DropdownMenuThemeData _createDropdownMenuTheme(
    ColorScheme colorScheme,
  ) {
    return DropdownMenuThemeData(
      textStyle: _textStyle(fontSize: 14, color: colorScheme.onSurface),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStateProperty.all(
          colorScheme.surfaceContainerHigh,
        ),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        elevation: WidgetStateProperty.all(3),
        shape: WidgetStateProperty.all(AppShapes.control),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: AppShapes.medium,
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    );
  }

  static PopupMenuThemeData _createPopupMenuTheme(ColorScheme colorScheme) {
    return PopupMenuThemeData(
      color: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: AppShapes.control,
      textStyle: _textStyle(fontSize: 14, color: colorScheme.onSurface),
    );
  }

  static IconButtonThemeData _createIconButtonTheme(ColorScheme colorScheme) {
    return IconButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(AppShapes.circle),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colorScheme.onSurface.withValues(alpha: 0.38);
          }
          return colorScheme.onSurfaceVariant;
        }),
        overlayColor: WidgetStatePropertyAll(
          colorScheme.primary.withValues(alpha: 0.08),
        ),
      ),
    );
  }

  static SegmentedButtonThemeData _createSegmentedButtonTheme(
    ColorScheme colorScheme,
  ) {
    return SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(AppShapes.control),
        side: WidgetStatePropertyAll(
          BorderSide(color: colorScheme.outlineVariant),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.secondaryContainer;
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onSecondaryContainer;
          }
          return colorScheme.onSurface;
        }),
      ),
    );
  }

  static ElevatedButtonThemeData _createElevatedButtonTheme(
    ColorScheme colorScheme,
  ) {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerHigh,
        foregroundColor: colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: AppShapes.pill,
        textStyle: _textStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    );
  }

  static FilledButtonThemeData _createFilledButtonTheme(
    ColorScheme colorScheme,
  ) {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: AppShapes.pill,
        textStyle: _textStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    );
  }

  static OutlinedButtonThemeData _createOutlinedButtonTheme(
    ColorScheme colorScheme,
  ) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: AppShapes.pill,
        side: BorderSide(color: colorScheme.outline, width: 1),
        textStyle: _textStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    );
  }

  static TextButtonThemeData _createTextButtonTheme(ColorScheme colorScheme) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: AppShapes.pill,
        textStyle: _textStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    );
  }

  static FloatingActionButtonThemeData _createFabTheme(
    ColorScheme colorScheme,
  ) {
    return FloatingActionButtonThemeData(
      backgroundColor: colorScheme.primaryContainer,
      foregroundColor: colorScheme.onPrimaryContainer,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 1,
      highlightElevation: 0,
      shape: AppShapes.floatingAction,
    );
  }

  static NavigationBarThemeData _createNavigationBarTheme(
    ColorScheme colorScheme,
  ) {
    return NavigationBarThemeData(
      backgroundColor: colorScheme.surfaceContainer,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colorScheme.secondaryContainer,
      indicatorShape: AppShapes.pill,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _textStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          );
        }
        return _textStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(
            color: colorScheme.onSecondaryContainer,
            size: 24,
          );
        }
        return IconThemeData(color: colorScheme.onSurfaceVariant, size: 24);
      }),
    );
  }

  static NavigationRailThemeData _createNavigationRailTheme(
    ColorScheme colorScheme,
  ) {
    return NavigationRailThemeData(
      backgroundColor: colorScheme.surface,
      elevation: 0,
      indicatorColor: colorScheme.secondaryContainer,
      indicatorShape: AppShapes.pill,
      selectedIconTheme: IconThemeData(
        color: colorScheme.onSecondaryContainer,
        size: 24,
      ),
      unselectedIconTheme: IconThemeData(
        color: colorScheme.onSurfaceVariant,
        size: 24,
      ),
      selectedLabelTextStyle: _textStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      unselectedLabelTextStyle: _textStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  static BottomSheetThemeData _createBottomSheetTheme(ColorScheme colorScheme) {
    return BottomSheetThemeData(
      backgroundColor: colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 1,
      shape: AppShapes.bottomSheet,
      dragHandleColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
      dragHandleSize: const Size(32, 4),
    );
  }

  static DialogThemeData _createDialogTheme(ColorScheme colorScheme) {
    return DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: AppShapes.dialog,
      titleTextStyle: _textStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      contentTextStyle: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  static SnackBarThemeData _createSnackBarTheme(ColorScheme colorScheme) {
    return SnackBarThemeData(
      backgroundColor: colorScheme.inverseSurface,
      contentTextStyle: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: colorScheme.onInverseSurface,
      ),
      actionTextColor: colorScheme.inversePrimary,
      shape: AppShapes.card,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    );
  }

  static ChipThemeData _createChipTheme(ColorScheme colorScheme) {
    return ChipThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      selectedColor: colorScheme.secondaryContainer,
      disabledColor: colorScheme.surfaceContainerHighest,
      labelStyle: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      secondaryLabelStyle: _textStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSecondaryContainer,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: AppShapes.card,
      side: BorderSide.none,
    );
  }

  static InputDecorationTheme _createInputDecorationTheme(
    ColorScheme colorScheme,
  ) {
    return InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppShapes.medium,
        borderSide: BorderSide(color: colorScheme.error, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      hintStyle: _textStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
      labelStyle: _textStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
    );
  }

  // Default themes for backward compatibility
  static ThemeData get lightTheme =>
      createTheme(defaultTheme, Brightness.light);
  static ThemeData get darkTheme => createTheme(defaultTheme, Brightness.dark);

  // Custom colors for specific use cases
  static const Color successColor = Color(0xFF146C2E);
  static const Color warningColor = Color(0xFF7D5800);
  static const Color infoColor = Color(0xFF005AC1);
  static const Color connectedColor = Color(0xFF146C2E);
  static const Color disconnectedColor = Color(0xFFBA1A1A);
  static const Color connectingColor = Color(0xFF7D5800);
}

/// Tells widgets that paint their own background how far their surface should
/// be veiled while a wallpaper is showing.
///
/// A [ThemeExtension] rather than a flag threaded through constructors: the
/// bottom navigation bar, for one, chooses its own colour, and it has to match
/// what [AppTheme.withTranslucentSurfaces] did to the cards and app bars. This
/// is the framework's own mechanism for a theme to hand a value to a widget
/// without either of them knowing the other.
class WallpaperSurface extends ThemeExtension<WallpaperSurface> {
  const WallpaperSurface({required this.alpha});

  /// Alpha to apply to a surface colour, 0 = nothing drawn, 1 = opaque.
  final double alpha;

  /// [color] as a veil over the wallpaper.
  Color veil(Color color) => color.withValues(alpha: alpha);

  @override
  WallpaperSurface copyWith({double? alpha}) =>
      WallpaperSurface(alpha: alpha ?? this.alpha);

  @override
  WallpaperSurface lerp(ThemeExtension<WallpaperSurface>? other, double t) {
    if (other is! WallpaperSurface) return this;
    return WallpaperSurface(alpha: alpha + (other.alpha - alpha) * t);
  }
}
