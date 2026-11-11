import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as md3;

/// Opts into Flutter's official Expressive component without mixing its theme
/// types into plugins that still use the SDK Material library.
class ExpressiveAction extends StatelessWidget {
  const ExpressiveAction({
    super.key,
    required this.onPressed,
    required this.child,
    this.selected = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool selected;

  static final _themes = Expando<md3.ThemeData>();

  static md3.ThemeData _theme(ThemeData source) => _themes[source] ??= () {
    final c = source.colorScheme;
    return md3.ThemeData(
      useMaterial3: true,
      brightness: source.brightness,
      platform: source.platform,
      fontFamily: source.textTheme.bodyMedium?.fontFamily,
      fontFamilyFallback: source.textTheme.bodyMedium?.fontFamilyFallback,
      colorScheme:
          md3.ColorScheme.fromSeed(
            seedColor: c.primary,
            brightness: c.brightness,
          ).copyWith(
            primary: c.primary,
            onPrimary: c.onPrimary,
            primaryContainer: c.primaryContainer,
            onPrimaryContainer: c.onPrimaryContainer,
            secondary: c.secondary,
            onSecondary: c.onSecondary,
            secondaryContainer: c.secondaryContainer,
            onSecondaryContainer: c.onSecondaryContainer,
            surface: c.surface,
            onSurface: c.onSurface,
            onSurfaceVariant: c.onSurfaceVariant,
            surfaceContainerLow: c.surfaceContainerLow,
            surfaceContainer: c.surfaceContainer,
            surfaceContainerHighest: c.surfaceContainerHighest,
            outline: c.outline,
            outlineVariant: c.outlineVariant,
          ),
      elevatedButtonTheme: const md3.ElevatedButtonThemeData(
        variant: md3.StyleVariant.material3Expressive,
      ),
    );
  }();

  @override
  Widget build(BuildContext context) {
    final source = Theme.of(context);
    final c = source.colorScheme;
    return md3.Theme(
      data: _theme(source),
      child: md3.ElevatedButton(
        onPressed: onPressed,
        style: md3.ButtonStyle(
          sizeVariant: md3.ButtonSizeVariant.medium,
          shapeVariant: selected
              ? md3.ButtonShapeVariant.round
              : md3.ButtonShapeVariant.square,
          elevation: const WidgetStatePropertyAll(0),
          minimumSize: const WidgetStatePropertyAll(Size(48, 56)),
          textStyle: WidgetStatePropertyAll(source.textTheme.labelLarge),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? c.onSurface.withValues(alpha: 0.12)
                : selected
                ? c.primary
                : c.surfaceContainerHighest,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? c.onSurface.withValues(alpha: 0.38)
                : selected
                ? c.onPrimary
                : c.onSurface,
          ),
        ),
        child: child,
      ),
    );
  }
}
