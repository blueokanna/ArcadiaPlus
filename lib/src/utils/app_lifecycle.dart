import 'dart:async';

import 'package:flutter/widgets.dart';

/// Process-wide view of whether the app is on screen and therefore allowed to
/// spend CPU.
///
/// Every timer in the app used to start when its widget or provider was
/// constructed and keep running until it was disposed. On Android that means a
/// backgrounded VeloGuard still woke the CPU once a second to poll a proxy the
/// user cannot see, refreshed the system information every five seconds, and
/// kept the resolver alive — the phone gets warm while nothing is happening.
/// Anything that repeats on a timer should consult [active] (or follow [when])
/// instead of assuming that being alive means being wanted.
///
/// This is deliberately a notifier rather than a bare getter: a timer can
/// listen and stop itself, and an animation can hook the same signal.
///
/// Only `resumed` counts as active. `inactive` covers an incoming call, the
/// app switcher, and a desktop window that has lost focus — none of which the
/// user is watching, and all of which should stop costing power.
class AppLifecycle with WidgetsBindingObserver {
  AppLifecycle._();

  static final AppLifecycle instance = AppLifecycle._();
  final ValueNotifier<bool> active = ValueNotifier<bool>(true);

  bool get isActive => active.value;
  bool _observing = false;

  /// Begin observing the platform's lifecycle. Safe to call more than once;
  /// the binding is only ever subscribed to once.
  void start() {
    if (_observing) return;
    _observing = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    active.value = _isActive(binding.lifecycleState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active.value = _isActive(state);
  }

  static bool _isActive(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  /// Resolves as soon as the app is on screen again, or immediately when it
  /// already is. Lets a paused worker restart without polling.
  ///
  /// The listener is removed on every path, so a caller that is disposed while
  /// waiting cannot leak it.
  static Future<void> whenActive() {
    final instance = AppLifecycle.instance;
    if (instance.isActive) return Future<void>.value();

    final completer = Completer<void>();
    void listener() {
      if (!instance.isActive) return;
      instance.active.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    }

    instance.active.addListener(listener);
    return completer.future;
  }
}

/// Tracks which route is on top.
///
/// Being on screen and being *looked at* are two different things: a route
/// stays mounted — and keeps rebuilding — underneath the one stacked above
/// it, so a screen that polled on mount alone kept paying for the whole time
/// the user spent somewhere else. Screens subscribe to this and take their
/// poll down when they are no longer the visible one.
///
/// Register it on the router's `observers` for it to receive anything.
final RouteObserver<ModalRoute<dynamic>> routeObserver =
    RouteObserver<ModalRoute<dynamic>>();
