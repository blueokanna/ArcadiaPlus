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
              _Preview(wallpaper: wallpaper),
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

/// The picture with its blur and dim applied, shown under a real card.
class _Preview extends StatelessWidget {
  const _Preview({required this.wallpaper});

  final WallpaperProvider wallpaper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final veil = theme.extension<WallpaperSurface>();
    final l10n = AppLocalizations.of(context);
    final path = wallpaper.imagePath;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 220,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path == null)
              ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: Icon(
                    Icons.landscape_outlined,
                    size: 56,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              // The same treatment the backdrop applies, so what is shown here
              // is what the app will look like rather than an approximation.
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: wallpaper.blur,
                  sigmaY: wallpaper.blur,
                  tileMode: ui.TileMode.clamp,
                ),
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: WallpaperBackdrop.decodeWidth(context),
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      ColoredBox(color: scheme.surfaceContainerHighest),
                ),
              ),
            ColoredBox(
              color:
                  (theme.brightness == Brightness.dark
                          ? Colors.black
                          : scheme.surface)
                      .withValues(alpha: wallpaper.dim),
            ),
            Center(
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
                    leading: Icon(
                      Icons.wallpaper_outlined,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.icon,
    required this.label,
    required this.description,
    required this.valueLabel,
    required this.value,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String description;
  final String valueLabel;
  final double value;
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
          Slider(value: value, max: max, onChanged: enabled ? onChanged : null),
        ],
      ),
    );
  }
}
