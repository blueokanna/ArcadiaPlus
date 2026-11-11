import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../theme/app_motion.dart';

/// A bounded catalogue keeps polygon matching out of the frame callback.
enum ExpressiveShapePair { status, selection, empty, activity }

final _morphs = <ExpressiveShapePair, Morph>{};
Morph _morphFor(ExpressiveShapePair pair) => _morphs.putIfAbsent(
  pair,
  () => switch (pair) {
    ExpressiveShapePair.status => Morph(
      MaterialShapes.cookie6Sided,
      MaterialShapes.cookie9Sided,
    ),
    ExpressiveShapePair.selection => Morph(
      MaterialShapes.square,
      MaterialShapes.cookie4Sided,
    ),
    ExpressiveShapePair.empty => Morph(
      MaterialShapes.clover4Leaf,
      MaterialShapes.cookie9Sided,
    ),
    ExpressiveShapePair.activity => Morph(
      MaterialShapes.diamond,
      MaterialShapes.softBurst,
    ),
  },
);

/// Can share a page/route timeline without allocating a controller per element.
/// Only the clip repaints on a tick; child layout and build stay unchanged.
class ExpressiveShape extends StatelessWidget {
  const ExpressiveShape({
    super.key,
    required this.progress,
    required this.child,
    this.pair = ExpressiveShapePair.selection,
  });
  final Animation<double> progress;
  final ExpressiveShapePair pair;
  final Widget child;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ClipPath(
      clipper: _ShapeClipper(_morphFor(pair), progress),
      child: child,
    ),
  );
}

/// An interruptible spatial spring for state changes. Idle list entries allocate
/// no controller. Reduced motion and hidden routes settle immediately.
class AnimatedExpressiveShape extends StatefulWidget {
  const AnimatedExpressiveShape({
    super.key,
    required this.progress,
    required this.child,
    this.pair = ExpressiveShapePair.selection,
  }) : assert(progress >= 0 && progress <= 1);
  final double progress;
  final ExpressiveShapePair pair;
  final Widget child;
  @override
  State<AnimatedExpressiveShape> createState() =>
      _AnimatedExpressiveShapeState();
}

class _AnimatedExpressiveShapeState extends State<AnimatedExpressiveShape>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late double _settled = widget.progress;
  bool get _animate =>
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;

  void _update() {
    if (!_animate) {
      _controller?.value = widget.progress;
      _settled = widget.progress;
      return;
    }
    final controller = _controller ??= AnimationController.unbounded(
      vsync: this,
      value: _settled,
    );
    controller.animateWith(
      SpringSimulation(
        AppMotion.spatialSpring,
        controller.value,
        widget.progress,
        controller.velocity,
        tolerance: const Tolerance(distance: .001, velocity: .001),
      ),
    );
  }

  @override
  void didUpdateWidget(AnimatedExpressiveShape oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) _update();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_animate) {
      _controller?.value = widget.progress;
      _settled = widget.progress;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExpressiveShape(
    progress: _controller ?? AlwaysStoppedAnimation(_settled),
    pair: widget.pair,
    child: widget.child,
  );
}

class _ShapeClipper extends CustomClipper<Path> {
  _ShapeClipper(this.morph, this.progress) : super(reclip: progress);
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
  bool shouldReclip(_ShapeClipper oldClipper) =>
      oldClipper.morph != morph || oldClipper.progress != progress;
}
