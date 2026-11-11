import 'package:flutter/material.dart';

import 'expressive_shape.dart';

class ExpressiveStatusShape extends StatelessWidget {
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
  Widget build(BuildContext context) => AnimatedExpressiveShape(
    pair: ExpressiveShapePair.status,
    progress: busy
        ? .5
        : running
        ? 1
        : 0,
    child: child,
  );
}
