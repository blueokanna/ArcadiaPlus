import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';

/// Interruptible press feedback. A release starts at the current position and
/// velocity, so quick taps do not reset the motion or delay the button action.
class SpringPress extends StatefulWidget {
  const SpringPress({super.key, required this.pressed, required this.child});

  final bool pressed;
  final Widget child;

  @override
  State<SpringPress> createState() => _SpringPressState();
}

class _SpringPressState extends State<SpringPress>
    with SingleTickerProviderStateMixin {
  AnimationController? _scale;
  double _restingScale = 1;
  bool _reduceMotion = false;
  bool _visible = true;
  bool _hasDependencies = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    final visible = TickerMode.valuesOf(context).enabled;
    final changed = _reduceMotion != reduced || _visible != visible;
    _reduceMotion = reduced;
    _visible = visible;
    if (!_hasDependencies || reduced || !visible) {
      _settle();
    } else if (changed) {
      _animateToTarget();
    }
    _hasDependencies = true;
  }

  @override
  void didUpdateWidget(SpringPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pressed == widget.pressed) return;
    if (_reduceMotion || !_visible) {
      _settle();
    } else {
      _animateToTarget();
    }
  }

  double get _target => _reduceMotion || !widget.pressed ? 1 : 0.97;

  void _settle() {
    _restingScale = _target;
    _scale?.stop();
    _scale?.value = _restingScale;
  }

  void _animateToTarget() {
    if ((_scale?.value ?? _restingScale) == _target &&
        !(_scale?.isAnimating ?? false)) {
      return;
    }
    final scale = _scale ??= AnimationController.unbounded(
      vsync: this,
      value: _restingScale,
    );
    scale.animateWith(
      SpringSimulation(
        AppMotion.pressSpring,
        scale.value,
        _target,
        scale.velocity,
        tolerance: const Tolerance(distance: 0.0001, velocity: 0.001),
      ),
    );
  }

  @override
  void dispose() {
    _scale?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale ?? AlwaysStoppedAnimation(_restingScale),
    child: widget.child,
  );
}
