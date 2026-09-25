import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/wallpaper_provider.dart';

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
    Widget picture = Image.file(
      File(wallpaper.imagePath!),
      fit: BoxFit.cover,
      cacheWidth: decodeWidth(context),
      // The picture is about to be blurred, so the extra sampling cost of a
      // higher quality filter buys nothing.
      filterQuality: FilterQuality.low,
      // Keeps the previous frame on screen while the next one decodes, so
      // changing the wallpaper does not flash an empty background.
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        // The file was removed or unreadable. Painting the interface without a
        // background is the only thing this layer can do; the settings screen
        // drops the reference the next time it loads.
        debugPrint('Failed to draw the wallpaper: $error');
        return const ColoredBox(color: Colors.transparent);
      },
    );

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

  /// The width to decode the picture at, in pixels.
  static int decodeWidth(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null) return maxDecodeWidth;
    final physicalWidth = (mediaQuery.size.width * mediaQuery.devicePixelRatio)
        .round();
    if (physicalWidth <= 0) return maxDecodeWidth;
    return physicalWidth < maxDecodeWidth ? physicalWidth : maxDecodeWidth;
  }
}
