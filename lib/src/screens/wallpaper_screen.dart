import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/providers/wallpaper_provider.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';
import 'package:arcadiaplus/src/widgets/adaptive_list_tile.dart';
import 'package:arcadiaplus/src/widgets/wallpaper_backdrop.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

/// Wallpaper settings, with a preview of the result.
///
/// The preview is the point of the screen: blur and dim are numbers until they
/// are seen against a surface the app actually draws, so the picture is shown
/// under a real card rather than described in a subtitle.
class WallpaperScreen extends StatelessWidget {
  const WallpaperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.wallpaperScreenTitle ?? 'Wallpaper and appearance'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/settings'),
        ),
      ),
      body: Consumer<WallpaperProvider>(
        builder: (context, wallpaper, child) {
          if (!WallpaperProvider.isSupported) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_not_supported_outlined,
                      size: 56,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n?.wallpaperUnsupported ??
                          'Wallpaper is not supported on this platform',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _FramingPreview(wallpaper: wallpaper),
              if (wallpaper.settings.hasImage) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    l10n?.wallpaperRepositionHint ??
                        'Drag the preview to reposition; pinch to zoom',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Card(
                elevation: 0,
                child: Column(
                  children: [
                    if (wallpaper.settings.hasImage) ...[
                      AdaptiveListTile(
                        title: Text(l10n?.wallpaper ?? 'Wallpaper'),
                        subtitle: Text(l10n?.wallpaperDesc ?? ''),
                        leading: _icon(context, Icons.wallpaper_outlined),
                        trailing: Switch.adaptive(
                          value: wallpaper.settings.enabled,
                          onChanged: wallpaper.setEnabled,
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                    AdaptiveListTile(
                      title: Text(
                        wallpaper.settings.hasImage
                            ? (l10n?.wallpaperChange ?? 'Change image')
                            : (l10n?.wallpaperChoose ?? 'Choose image'),
                      ),
                      subtitle: wallpaper.imagePath == null
                          ? null
                          : Text(
                              wallpaper.imagePath!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                      leading: _icon(context, Icons.image_outlined),
                      trailing: wallpaper.isPicking
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      enabled: !wallpaper.isPicking,
                      onTap: () => _pick(context, wallpaper),
                    ),
                    if (wallpaper.settings.hasImage) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(
                          l10n?.wallpaperRemove ?? 'Remove wallpaper',
                        ),
                        leading: Icon(
                          Icons.delete_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _confirmRemoval(context, wallpaper),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Card(
                elevation: 0,
                child: Column(
                  children: [
                    _Slider(
                      icon: Icons.blur_on_outlined,
                      label: l10n?.wallpaperBlur ?? 'Blur',
                      description: l10n?.wallpaperBlurDesc ?? '',
                      valueLabel: '${wallpaper.blur.round()}',
                      value: wallpaper.blur,
                      max: WallpaperSettings.maxBlur,
                      enabled: wallpaper.settings.hasImage,
                      onChanged: wallpaper.setBlur,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _Slider(
                      icon: Icons.brightness_4_outlined,
                      label: l10n?.wallpaperDim ?? 'Dim',
                      description: l10n?.wallpaperDimDesc ?? '',
                      valueLabel: '${(wallpaper.dim * 100).round()}%',
                      value: wallpaper.dim,
                      max: WallpaperSettings.maxDim,
                      enabled: wallpaper.settings.hasImage,
                      onChanged: wallpaper.setDim,
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _Slider(
                      icon: Icons.zoom_out_map_outlined,
                      label: l10n?.wallpaperZoom ?? 'Zoom',
                      description: '',
                      valueLabel: '${(wallpaper.zoom * 10).round() / 10}×',
                      value: wallpaper.zoom,
                      min: WallpaperSettings.minZoom,
                      max: WallpaperSettings.maxZoom,
                      enabled: wallpaper.settings.hasImage,
                      onChanged: wallpaper.setZoom,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  static Widget _icon(BuildContext context, IconData icon) =>
      Icon(icon, color: Theme.of(context).colorScheme.primary);

  Future<void> _pick(BuildContext context, WallpaperProvider wallpaper) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    await wallpaper.pickImage();
    if (wallpaper.lastError == null) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n?.wallpaperFailed ?? 'That image could not be read.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmRemoval(
    BuildContext context,
    WallpaperProvider wallpaper,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n?.wallpaperRemove ?? 'Remove wallpaper'),
        content: Text(l10n?.wallpaperRemoveConfirm ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n?.cancel ?? 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n?.delete ?? 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) await wallpaper.clearImage();
  }
}

/// The picture with its framing, blur and dim applied, shown under a real
/// card — and draggable, because framing is a gesture, not a number.
///
/// The arithmetic here is the backdrop's: same fit, same alignment, and the
/// same scale about that alignment. What the preview shows is therefore the
/// result, not an approximation of it.
class _FramingPreview extends StatefulWidget {
  const _FramingPreview({required this.wallpaper});

  final WallpaperProvider wallpaper;

  @override
  State<_FramingPreview> createState() => _FramingPreviewState();
}

class _FramingPreviewState extends State<_FramingPreview> {
  double _gestureZoom = WallpaperSettings.minZoom;
  Offset _gestureAlignment = Offset.zero;
  Offset _gestureFocalPoint = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final wallpaper = widget.wallpaper;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final path = wallpaper.imagePath;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 220,
        child: path == null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.landscape_outlined,
                        size: 56,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _previewCard(context),
                ],
              )
            : LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  // Framing is a two-finger gesture by nature; a double tap is
                  // the one-hand way back to the default.
                  onDoubleTap: wallpaper.resetFraming,
                  onScaleStart: (details) {
                    _gestureZoom = wallpaper.zoom;
                    _gestureAlignment = Offset(
                      wallpaper.alignmentX,
                      wallpaper.alignmentY,
                    );
                    _gestureFocalPoint = details.localFocalPoint;
                  },
                  onScaleUpdate: (details) {
                    final pan = details.localFocalPoint - _gestureFocalPoint;
                    // A drag across the whole preview covers the whole
                    // alignment range, so the picture follows the finger at
                    // the speed it is dragged.
                    wallpaper.setFraming(
                      alignmentX:
                          _gestureAlignment.dx -
                          (constraints.maxWidth <= 0
                              ? 0
                              : 2 * pan.dx / constraints.maxWidth),
                      alignmentY:
                          _gestureAlignment.dy -
                          (constraints.maxHeight <= 0
                              ? 0
                              : 2 * pan.dy / constraints.maxHeight),
                      zoom: _gestureZoom * details.scale,
                    );
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _picture(context, wallpaper),
                      ColoredBox(
                        color:
                            (theme.brightness == Brightness.dark
                                    ? Colors.black
                                    : scheme.surface)
                                .withValues(alpha: wallpaper.dim),
                      ),
                      _previewCard(context),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IconButton(
                          tooltip:
                              l10n?.wallpaperResetFraming ?? 'Reset framing',
                          onPressed: wallpaper.resetFraming,
                          icon: const Icon(Icons.center_focus_strong_outlined),
                          style: IconButton.styleFrom(
                            backgroundColor: scheme.surface.withValues(
                              alpha: 0.6,
                            ),
                            foregroundColor: scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// The card that demonstrates what the interface looks like over the
  /// wallpaper, shown in both states: with no picture chosen it is still the
  /// explanation of what a picture would do.
  Widget _previewCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final veil = theme.extension<WallpaperSurface>();
    final l10n = AppLocalizations.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Card(
          elevation: 0,
          color:
              veil?.veil(scheme.surfaceContainerLow) ??
              scheme.surfaceContainerLow,
          child: AdaptiveListTile(
            title: Text(l10n?.wallpaperPreview ?? 'Preview'),
            subtitle: Text(
              l10n?.wallpaperDesc ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            leading: Icon(Icons.wallpaper_outlined, color: scheme.primary),
          ),
        ),
      ),
    );
  }

  Widget _picture(BuildContext context, WallpaperProvider wallpaper) {
    final alignment = Alignment(wallpaper.alignmentX, wallpaper.alignmentY);
    Widget picture = Image.file(
      File(wallpaper.imagePath!),
      fit: BoxFit.cover,
      alignment: alignment,
      cacheWidth: WallpaperBackdrop.decodeWidth(context, zoom: wallpaper.zoom),
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
    if (wallpaper.zoom > WallpaperSettings.minZoom) {
      picture = Transform.scale(
        scale: wallpaper.zoom,
        alignment: alignment,
        child: picture,
      );
    }
    final blur = wallpaper.blur;
    if (blur > 0) {
      // The same treatment the backdrop applies, so what is shown here is
      // what the app will look like rather than an approximation.
      picture = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: ui.TileMode.clamp,
        ),
        child: picture,
      );
    }
    return picture;
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.icon,
    required this.label,
    required this.description,
    required this.valueLabel,
    required this.value,
    this.min = 0,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String description;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                color: enabled ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: enabled
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                valueLabel,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}
