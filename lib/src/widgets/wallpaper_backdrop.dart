import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/wallpaper_provider.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

/// Draws the wallpaper behind [child], blurred and dimmed.
///
/// The blur is an [ui.ImageFilter] on the picture itself rather than a
/// [BackdropFilter] over it. Blurring what is behind a full-screen layer means
/// compositing the whole screen into an offscreen buffer every frame; blurring
/// the picture once is the same picture at a fraction of the cost, because the
/// only thing behind the interface here is the picture.
///
/// The layer is wrapped in a [RepaintBoundary] so scrolling a list on top of it
/// does not re-run the filter, and the picture is decoded at screen resolution
/// rather than at its own: a 12-megapixel photo is tens of megabytes of bitmap
/// for a background that is blurred anyway.
///
/// The user's framing — where the picture sits and how far it is magnified —
/// is applied here and by the settings preview through the same arithmetic, so
/// the preview is the result rather than an approximation of it.
class WallpaperBackdrop extends StatelessWidget {
  const WallpaperBackdrop({super.key, required this.child});

  /// The interface the wallpaper sits behind.
  final Widget child;

  /// Widest bitmap decoded for the background, in pixels.
  ///
  /// Above roughly this size the extra pixels are not visible after a blur of
  /// any reasonable radius, and the memory they cost is.
  static const int maxDecodeWidth = 2048;

  @override
  Widget build(BuildContext context) {
    final wallpaper = context.watch<WallpaperProvider>();
    if (!wallpaper.isVisible) return child;

    final scheme = Theme.of(context).colorScheme;
    final scrim =
        (Theme.of(context).brightness == Brightness.dark
                ? Colors.black
                : scheme.surface)
            .withValues(alpha: wallpaper.dim);

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildPicture(context, wallpaper),
              DecoratedBox(decoration: BoxDecoration(color: scrim)),
            ],
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildPicture(BuildContext context, WallpaperProvider wallpaper) {
    final alignment = Alignment(wallpaper.alignmentX, wallpaper.alignmentY);
    Widget picture = Image.file(
      File(wallpaper.imagePath!),
      fit: BoxFit.cover,
      alignment: alignment,
      cacheWidth: decodeWidth(context, zoom: wallpaper.zoom),
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        debugPrint('Failed to draw the wallpaper: $error');
        return const ColoredBox(color: Colors.transparent);
      },
    );

    final zoom = wallpaper.zoom;
    if (zoom > WallpaperSettings.minZoom) {
      picture = Transform.scale(
        scale: zoom,
        alignment: alignment,
        child: picture,
      );
    }

    final blur = wallpaper.blur;
    if (blur > 0) {
      picture = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          // Sampling beyond the edge instead of fading it out: a blurred
          // picture whose border goes transparent would leave a visible frame
          // of whatever is behind it.
          tileMode: ui.TileMode.clamp,
        ),
        child: picture,
      );
    }
    return picture;
  }

  static int decodeWidth(BuildContext context, {double zoom = 1}) {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null) return maxDecodeWidth;
    final physicalWidth = (mediaQuery.size.width * mediaQuery.devicePixelRatio)
        .round();
    if (physicalWidth <= 0) return maxDecodeWidth;
    final visibleWidth = (physicalWidth * (zoom < 1 ? 1.0 : zoom)).round();
    final wanted = visibleWidth < physicalWidth ? physicalWidth : visibleWidth;
    return wanted < maxDecodeWidth ? wanted : maxDecodeWidth;
  }
}
