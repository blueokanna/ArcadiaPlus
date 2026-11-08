import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AnimationUtils {
  AnimationUtils._();

  static double getDeviceRefreshRate() {
    final window = WidgetsBinding.instance.platformDispatcher.views.first;
    return window.display.refreshRate;
  }

  static Duration getOptimalDuration({
    Duration baseDuration = const Duration(milliseconds: 300),
  }) {
    // Refresh rate changes frame density, not the duration of an interaction.
    return baseDuration;
  }

  static const Duration durationShort1 = Duration(milliseconds: 50);
  static const Duration durationShort2 = Duration(milliseconds: 100);
  static const Duration durationShort3 = Duration(milliseconds: 150);
  static const Duration durationShort4 = Duration(milliseconds: 200);

  static const Duration durationMedium1 = Duration(milliseconds: 250);
  static const Duration durationMedium2 = Duration(milliseconds: 300);
  static const Duration durationMedium3 = Duration(milliseconds: 350);
  static const Duration durationMedium4 = Duration(milliseconds: 400);

  static const Duration durationLong1 = Duration(milliseconds: 450);
  static const Duration durationLong2 = Duration(milliseconds: 500);
  static const Duration durationLong3 = Duration(milliseconds: 550);
  static const Duration durationLong4 = Duration(milliseconds: 600);

  static const Duration durationExtraLong1 = Duration(milliseconds: 700);
  static const Duration durationExtraLong2 = Duration(milliseconds: 800);
  static const Duration durationExtraLong3 = Duration(milliseconds: 900);
  static const Duration durationExtraLong4 = Duration(milliseconds: 1000);

  static const Curve curveEmphasized = Curves.easeInOutCubicEmphasized;

  static const Curve curveEmphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  static const Curve curveEmphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  static const Curve curveStandard = Cubic(0.2, 0.0, 0.0, 1.0);

  static const Curve curveStandardAccelerate = Cubic(0.3, 0.0, 1.0, 1.0);

  static const Curve curveStandardDecelerate = Cubic(0.0, 0.0, 0.0, 1.0);

  static const Curve curveSpring = _SpringCurve(damping: 0.7, stiffness: 200);

  static const Curve curveSpringLight = _SpringCurve(
    damping: 0.8,
    stiffness: 300,
  );

  static const Curve curveSpringBouncy = _SpringCurve(
    damping: 0.5,
    stiffness: 150,
  );

  static const Curve curveSpringExpressive = _SpringCurve(
    damping: 0.4,
    stiffness: 120,
  );

  static const Curve curveOvershoot = _OvershootCurve(tension: 1.5);

  static const Curve curveOvershootLight = _OvershootCurve(tension: 1.0);

  static const Curve curveOvershootStrong = _OvershootCurve(tension: 2.0);

  static const Curve curveAnticipate = _AnticipateCurve(tension: 2.0);

  static const Curve curveAnticipateOvershoot = _AnticipateOvershootCurve(
    tension: 1.5,
  );

  static const Curve curveBounce = _BounceCurve();

  static const Curve curveElasticBounce = _ElasticCurve(period: 0.4);

  static const buttonPressDuration = Duration(milliseconds: 80);
  static const buttonReleaseDuration = Duration(milliseconds: 200);
  static const buttonPressCurve = curveStandardAccelerate;
  static const buttonReleaseCurve = curveSpringLight;

  static const cardExpandDuration = Duration(milliseconds: 350);
  static const cardExpandCurve = curveEmphasizedDecelerate;
  static const cardCollapseDuration = Duration(milliseconds: 300);
  static const cardCollapseCurve = curveEmphasizedAccelerate;

  static const pageTransitionDuration = Duration(milliseconds: 400);
  static const pageTransitionCurve = curveEmphasized;

  static const listItemDuration = Duration(milliseconds: 300);
  static const listItemCurve = curveEmphasizedDecelerate;
  static const listItemStaggerDelay = Duration(milliseconds: 50);

  static const stateChangeDuration = Duration(milliseconds: 250);
  // Decoration tweens contain constrained values such as shadow blur radii.
  // Overshooting curves can drive those values below zero while reversing.
  static const Curve stateChangeCurve = curveStandard;

  static const iconMorphDuration = Duration(milliseconds: 200);
  static const iconMorphCurve = curveEmphasized;

  static const fabExpandDuration = Duration(milliseconds: 300);
  static const fabExpandCurve = curveSpringBouncy;

  static const dialogEnterDuration = Duration(milliseconds: 350);
  static const dialogExitDuration = Duration(milliseconds: 250);
  static const dialogEnterCurve = curveEmphasizedDecelerate;
  static const dialogExitCurve = curveEmphasizedAccelerate;

  static const bottomSheetDuration = Duration(milliseconds: 400);
  static const bottomSheetCurve = curveEmphasized;

  static const navBarDuration = Duration(milliseconds: 300);
  static const navBarCurve = curveSpring;

  static const switchDuration = Duration(milliseconds: 200);
  static const switchCurve = curveSpringLight;

  static const sliderDuration = Duration(milliseconds: 150);
  static const sliderCurve = curveStandard;

  // 震动反馈全局开关
  static bool _hapticEnabled = false;

  /// 设置震动反馈开关
  static void setHapticEnabled(bool enabled) {
    _hapticEnabled = enabled;
  }

  /// 获取震动反馈开关状态
  static bool get hapticEnabled => _hapticEnabled;

  static void lightHaptic() {
    if (!_hapticEnabled) return;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      HapticFeedback.lightImpact();
    }
  }

  static void selectionHaptic() {
    if (!_hapticEnabled) return;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      HapticFeedback.selectionClick();
    }
  }

  static void mediumHaptic() {
    if (!_hapticEnabled) return;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      HapticFeedback.mediumImpact();
    }
  }

  static void heavyHaptic() {
    if (!_hapticEnabled) return;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      HapticFeedback.heavyImpact();
    }
  }

  static void vibrateHaptic() {
    if (!_hapticEnabled) return;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      HapticFeedback.vibrate();
    }
  }

  static double getExpressiveBorderRadius({
    required double baseRadius,
    bool isPressed = false,
    bool isHovered = false,
    bool isExpanded = false,
  }) {
    if (isExpanded) return baseRadius * 1.5;
    if (isPressed) return baseRadius * 0.8;
    if (isHovered) return baseRadius * 1.1;
    return baseRadius;
  }

  static double getExpressiveScale({
    bool isPressed = false,
    bool isHovered = false,
    bool isActive = false,
  }) {
    if (isPressed) return 0.95;
    if (isActive) return 1.02;
    if (isHovered) return 1.01;
    return 1.0;
  }

  static List<BoxShadow> getExpressiveShadow({
    required Color color,
    bool isElevated = false,
    bool isPressed = false,
  }) {
    if (isPressed) {
      return [
        BoxShadow(
          color: color.withValues(alpha: 0.1),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ];
    }
    if (isElevated) {
      return [
        BoxShadow(
          color: color.withValues(alpha: 0.15),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: color.withValues(alpha: 0.1),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ];
    }
    return [
      BoxShadow(
        color: color.withValues(alpha: 0.1),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ];
  }
}

class _SpringCurve extends Curve {
  final double damping;
  final double stiffness;

  const _SpringCurve({this.damping = 0.7, this.stiffness = 200});

  @override
  double transformInternal(double t) {
    final omega = math.sqrt(stiffness);
    final dampingRatio = damping;

    if (dampingRatio < 1) {
      final omegaD = omega * math.sqrt(1 - dampingRatio * dampingRatio);
      return 1 -
          math.exp(-dampingRatio * omega * t) *
              (math.cos(omegaD * t) +
                  (dampingRatio * omega / omegaD) * math.sin(omegaD * t));
    } else {
      return 1 - (1 + omega * t) * math.exp(-omega * t);
    }
  }
}

class _OvershootCurve extends Curve {
  final double tension;

  const _OvershootCurve({this.tension = 1.5});

  @override
  double transformInternal(double t) {
    final s = tension;
    return (t - 1) * (t - 1) * ((s + 1) * (t - 1) + s) + 1;
  }
}

class _AnticipateCurve extends Curve {
  final double tension;

  const _AnticipateCurve({this.tension = 2.0});

  @override
  double transformInternal(double t) {
    final s = tension;
    return t * t * ((s + 1) * t - s);
  }
}

class _AnticipateOvershootCurve extends Curve {
  final double tension;

  const _AnticipateOvershootCurve({this.tension = 1.5});

  @override
  double transformInternal(double t) {
    final s = tension * 1.5;
    if (t < 0.5) {
      return 0.5 * (2 * t) * (2 * t) * ((s + 1) * 2 * t - s);
    } else {
      final t2 = 2 * t - 2;
      return 0.5 * (t2 * t2 * ((s + 1) * t2 + s) + 2);
    }
  }
}

class _BounceCurve extends Curve {
  const _BounceCurve();

  @override
  double transformInternal(double t) {
    if (t < 1 / 2.75) {
      return 7.5625 * t * t;
    } else if (t < 2 / 2.75) {
      final t2 = t - 1.5 / 2.75;
      return 7.5625 * t2 * t2 + 0.75;
    } else if (t < 2.5 / 2.75) {
      final t2 = t - 2.25 / 2.75;
      return 7.5625 * t2 * t2 + 0.9375;
    } else {
      final t2 = t - 2.625 / 2.75;
      return 7.5625 * t2 * t2 + 0.984375;
    }
  }
}

class _ElasticCurve extends Curve {
  final double period;

  const _ElasticCurve({this.period = 0.4});

  @override
  double transformInternal(double t) {
    final p = period;
    final s = p / 4;
    return math.pow(2, -10 * t) * math.sin((t - s) * (2 * math.pi) / p) + 1;
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
    this.duration = const Duration(milliseconds: 300),
    this.curve = const Cubic(0.05, 0.7, 0.1, 1.0),
    this.slideOffset = const Offset(0, 0.1),
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
  late Animation<double> _scaleAnimation;

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

    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(_curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance?.cancel();
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      // A virtual list may build its thousandth row first. Its global index
      // must not hide the row for tens of seconds or retain a long-lived timer.
      final micros = (widget.delay.inMicroseconds * widget.index).clamp(
        0,
        160000,
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
      child: SlideTransition(
        position: _slideAnimation,
        child: ScaleTransition(scale: _scaleAnimation, child: widget.child),
      ),
    );
  }
}
