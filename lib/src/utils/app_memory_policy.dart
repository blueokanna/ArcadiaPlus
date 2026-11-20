import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Bounds retained decoded images, not process RSS or live render surfaces.
/// Flutter's binding already evicts this cache on OS memory-pressure events.
abstract final class AppMemoryPolicy {
  static final _observer = _MemoryObserver();
  static final retainedBytes = ValueNotifier<int>(0);
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(_observer);
    // Sample after painting, including the first frame that decodes a wallpaper.
    // Registering a frame callback does not schedule frames while idle.
    binding.addPersistentFrameCallback((_) {
      binding.addPostFrameCallback(
        (_) => maintain(PaintingBinding.instance.imageCache),
      );
    });
  }

  static void maintain(ImageCache cache) {
    if ((cache.maximumSizeBytes > 0 &&
            cache.currentSizeBytes * 100 >= cache.maximumSizeBytes * 95) ||
        (cache.maximumSize > 0 && cache.currentSize >= cache.maximumSize)) {
      releaseImageCache(cache);
    }
    retainedBytes.value = cache.currentSizeBytes;
  }

  /// Evicts retained decoded images. Live image listeners and native engine
  /// allocations remain owned by their consumers; RSS is not a reclaim count.
  static int releaseImageCache(ImageCache cache) {
    final before = cache.currentSizeBytes;
    cache.clear();
    retainedBytes.value = cache.currentSizeBytes;
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
