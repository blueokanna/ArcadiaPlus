import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../theme/app_motion.dart';

/// One interruptible shape transition; there is no idle animation or timer.
class ExpressiveStatusShape extends StatefulWidget {
  const ExpressiveStatusShape({
    super.key,
    required this.running,
    required this.child,
    this.busy = false,
  });
  final bool running;
  final bool busy;
  final Widget child;

  @override
  State<ExpressiveStatusShape> createState() => _ExpressiveStatusShapeState();
}

class _ExpressiveStatusShapeState extends State<ExpressiveStatusShape>
    with SingleTickerProviderStateMixin {
  double get _target => widget.busy
      ? .5
      : widget.running
      ? 1
      : 0;
  static final _morph = Morph(
    MaterialShapes.cookie12Sided,
    MaterialShapes.cookie9Sided,
  );
  late final _progress = AnimationController.unbounded(
    vsync: this,
    value: _target,
  );

  void _update() {
    final target = _target;
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _progress.value = target;
    } else {
      _progress.animateWith(
        SpringSimulation(
          AppMotion.spatialSpring,
          _progress.value,
          target,
          _progress.velocity,
          tolerance: const Tolerance(distance: 0.001, velocity: 0.001),
        ),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _progress.value = _target;
    }
  }

  @override
  void didUpdateWidget(ExpressiveStatusShape oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running || oldWidget.busy != widget.busy) {
      _update();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ClipPath(clipper: _StatusClipper(_morph, _progress), child: widget.child);
}

class _StatusClipper extends CustomClipper<Path> {
  _StatusClipper(this.morph, this.progress) : super(reclip: progress);
  final Morph morph;
  final Animation<double> progress;

  @override
  Path getClip(Size size) => morph
      .toPath(progress: progress.value.clamp(0, 1))
      .transform(
        (Matrix4.identity()..scaleByDouble(size.width, size.height, 1, 1))
            .storage,
      );

  @override
  bool shouldReclip(_StatusClipper oldClipper) =>
      oldClipper.morph != morph || oldClipper.progress != progress;
}
