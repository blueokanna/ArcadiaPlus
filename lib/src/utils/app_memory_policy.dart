import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Bounds retained decoded images, not process RSS or live render surfaces.
/// Flutter's binding already evicts this cache on OS memory-pressure events.
abstract final class AppMemoryPolicy {
  /// Evicts retained decoded images. Live image listeners and native engine
  /// allocations remain owned by their consumers; RSS is not a reclaim count.
  static int releaseImageCache(ImageCache cache) {
    final before = cache.currentSizeBytes;
    cache.clear();
    return (before - cache.currentSizeBytes).clamp(0, before);
  }

  static void configure(ImageCache cache, {TargetPlatform? platform}) {
    final target = platform ?? defaultTargetPlatform;
    final mobile =
        target == TargetPlatform.android || target == TargetPlatform.iOS;
    cache.maximumSizeBytes = (mobile ? 32 : 64) * 1024 * 1024;
    cache.maximumSize = mobile ? 100 : 200;
  }
}
