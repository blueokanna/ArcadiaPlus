import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';

/// Shared motion tokens and optional platform feedback. Press physics lives in
/// SpringPress; color and decoration transitions use bounded Material curves.
abstract final class AnimationUtils {
  static const curveEmphasized = AppMotion.curve;
  static const curveStandard = AppMotion.standardCurve;
  static const stateChangeCurve = AppMotion.standardCurve;
  static const durationMedium2 = AppMotion.standard;
  static bool _hapticEnabled = false;

  static void setHapticEnabled(bool enabled) => _hapticEnabled = enabled;

  static void lightHaptic() => _feedback(HapticFeedback.lightImpact);
  static void mediumHaptic() => _feedback(HapticFeedback.mediumImpact);
  static void selectionHaptic() => _feedback(HapticFeedback.selectionClick);

  static void _feedback(Future<void> Function() feedback) {
    if (!_hapticEnabled ||
        kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    // Feedback is optional; an unsupported platform channel must not fail the
    // navigation or proxy action that requested it.
    unawaited(
      feedback().catchError((Object error) {
        debugPrint('Haptic feedback unavailable: $error');
      }),
    );
  }
}

class StaggeredListItem extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration delay;
  final Duration duration;
  final Curve curve;
  final Offset slideOffset;

  const StaggeredListItem({
    super.key,
    required this.child,
    required this.index,
    this.delay = const Duration(milliseconds: 50),
    this.duration = AppMotion.standard,
    this.curve = AppMotion.curve,
    this.slideOffset = const Offset(0, 0.04),
  });

  @override
  State<StaggeredListItem> createState() => _StaggeredListItemState();
}

class _StaggeredListItemState extends State<StaggeredListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late CurvedAnimation _curve;
  Timer? _entrance;
  bool _started = false;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _curve = CurvedAnimation(parent: _controller, curve: widget.curve);

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(_curve);

    _slideAnimation = Tween<Offset>(
      begin: widget.slideOffset,
      end: Offset.zero,
    ).animate(_curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled ||
        widget.index >= 8) {
      _entrance?.cancel();
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      // Stagger only the first viewport. Rows reached by scrolling remain
      // immediately readable and do not create a ticker per new connection.
      final micros = (widget.delay.inMicroseconds * widget.index).clamp(
        0,
        80000,
      );
      if (micros == 0) {
        _controller.forward();
      } else {
        _entrance = Timer(Duration(microseconds: micros), _controller.forward);
      }
    }
  }

  @override
  void didUpdateWidget(StaggeredListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    _curve.curve = widget.curve;
    if (oldWidget.slideOffset != widget.slideOffset) {
      _slideAnimation = Tween<Offset>(
        begin: widget.slideOffset,
        end: Offset.zero,
      ).animate(_curve);
    }
  }

  @override
  void dispose() {
    _entrance?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}
