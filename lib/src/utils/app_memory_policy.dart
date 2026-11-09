import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Bounds retained decoded images, not process RSS or live render surfaces.
/// Flutter's binding already evicts this cache on OS memory-pressure events.
abstract final class AppMemoryPolicy {
  static void configure(ImageCache cache, {TargetPlatform? platform}) {
    final target = platform ?? defaultTargetPlatform;
    final mobile =
        target == TargetPlatform.android || target == TargetPlatform.iOS;
    cache.maximumSizeBytes = (mobile ? 32 : 64) * 1024 * 1024;
    cache.maximumSize = mobile ? 100 : 200;
  }
}
