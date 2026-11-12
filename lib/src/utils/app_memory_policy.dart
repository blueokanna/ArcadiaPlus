import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Bounds retained decoded images, not process RSS or live render surfaces.
/// Flutter's binding already evicts this cache on OS memory-pressure events.
abstract final class AppMemoryPolicy {
  static final _observer = _MemoryObserver();
  static void start() {
    final binding = WidgetsBinding.instance;
    binding.removeObserver(_observer);
    binding.addObserver(_observer);
  }

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
    cache.maximumSizeBytes = (mobile ? 16 : 32) * 1024 * 1024;
    cache.maximumSize = mobile ? 48 : 96;
  }
}

class _MemoryObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      AppMemoryPolicy.releaseImageCache(PaintingBinding.instance.imageCache);
    }
  }
}
