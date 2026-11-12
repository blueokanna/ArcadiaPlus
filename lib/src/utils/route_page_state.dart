import 'package:flutter/widgets.dart';

/// Retains scroll offsets across destination replacement, not widget trees,
/// controllers or render layers. Older destination state is bounded by LRU.
abstract final class RoutePageState {
  static const capacity = 12;
  static final _buckets = <String, PageStorageBucket>{};

  static PageStorageBucket forPath(String path) {
    final bucket = _buckets.remove(path) ?? PageStorageBucket();
    _buckets[path] = bucket;
    while (_buckets.length > capacity) {
      _buckets.remove(_buckets.keys.first);
    }
    return bucket;
  }
}
