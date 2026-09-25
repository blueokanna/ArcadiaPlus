import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/theme/app_shapes.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';

void main() {
  test('application theme uses Material 3 and bundled Roboto', () {
    final theme = AppTheme.createTheme(AppTheme.defaultTheme, Brightness.light);

    expect(theme.useMaterial3, isTrue);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Roboto');
  });

  test('Material surfaces use the shared shape hierarchy', () {
    final theme = AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark);

    expect(theme.cardTheme.shape, AppShapes.card);
    expect(theme.dialogTheme.shape, AppShapes.dialog);
    expect(theme.bottomSheetTheme.shape, AppShapes.bottomSheet);
    expect(theme.floatingActionButtonTheme.shape, AppShapes.floatingAction);
    expect(
      theme.filledButtonTheme.style?.shape?.resolve(<WidgetState>{}),
      AppShapes.pill,
    );
  });

  test('the same theme is built once', () {
    expect(
      identical(
        AppTheme.createTheme(AppTheme.oceanTheme, Brightness.dark),
        AppTheme.createTheme(AppTheme.oceanTheme, Brightness.dark),
      ),
      isTrue,
    );
  });

  group('wallpaper surfaces', () {
    test('background layers become veils and the base theme stays intact', () {
      final base = AppTheme.createTheme(
        AppTheme.defaultTheme,
        Brightness.light,
      );
      final wallpapered = AppTheme.withTranslucentSurfaces(base);

      expect(wallpapered.scaffoldBackgroundColor, Colors.transparent);
      expect(
        wallpapered.cardTheme.color?.a,
        closeTo(AppTheme.wallpaperSurfaceAlpha, 0.001),
      );
      expect(
        wallpapered.extension<WallpaperSurface>()?.alpha,
        AppTheme.wallpaperSurfaceAlpha,
      );

      // The theme the rest of the app builds from is not mutated.
      expect(base.scaffoldBackgroundColor, base.colorScheme.surface);
      expect(base.cardTheme.color, base.colorScheme.surfaceContainerLow);
    });

    test('deriving twice from one base returns the same instance', () {
      final base = AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark);

      expect(
        identical(
          AppTheme.withTranslucentSurfaces(base),
          AppTheme.withTranslucentSurfaces(base),
        ),
        isTrue,
      );
    });

    test('deriving from a derived theme does not stack veils', () {
      final base = AppTheme.createTheme(AppTheme.defaultTheme, Brightness.dark);
      final twice = AppTheme.withTranslucentSurfaces(
        AppTheme.withTranslucentSurfaces(base),
      );

      expect(
        twice.cardTheme.color?.a,
        closeTo(AppTheme.wallpaperSurfaceAlpha, 0.001),
      );
      expect(
        twice.extension<WallpaperSurface>()?.alpha,
        AppTheme.wallpaperSurfaceAlpha,
      );
    });
  });
}
