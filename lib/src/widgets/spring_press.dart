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
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  bool _reduceMotion = false;
  bool _hasDependencies = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (!_hasDependencies || reduced) {
      _scale.stop();
      _scale.value = reduced || !widget.pressed ? 1 : 0.97;
    } else if (_reduceMotion != reduced) {
      _animateToTarget();
    }
    _hasDependencies = true;
    _reduceMotion = reduced;
  }

  @override
  void didUpdateWidget(SpringPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pressed == widget.pressed || _reduceMotion) return;
    _animateToTarget();
  }

  void _animateToTarget() {
    _scale.animateWith(
      SpringSimulation(
        AppMotion.pressSpring,
        _scale.value,
        widget.pressed ? 0.97 : 1,
        _scale.velocity,
        tolerance: const Tolerance(distance: 0.0001, velocity: 0.001),
      ),
    );
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _scale, child: widget.child);
}
