import 'dart:async';

/// Revision is retained even when the dashboard is not mounted.
abstract final class ProxySelectionEvents {
  static final _controller = StreamController<String>.broadcast();
  static int _revision = 0;
  static int get revision => _revision;
  static Stream<String> get changes => _controller.stream;

  static void applied(String name) {
    _revision++;
    _controller.add(name);
  }
}
