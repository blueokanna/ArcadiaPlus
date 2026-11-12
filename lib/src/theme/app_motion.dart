import 'package:flutter/material.dart';

/// Motion is measured in time, independent of the display refresh rate.
abstract final class AppMotion {
  static const short = Duration(milliseconds: 160);
  static const standard = Duration(milliseconds: 240);
  static const pageEntrance = Duration(milliseconds: 420);
  static const curve = Curves.easeInOutCubicEmphasized;
  static const standardCurve = Cubic(0.2, 0.0, 0.0, 1.0);
  static const spatialSpring = SpringDescription(
    mass: 1,
    stiffness: 380,
    damping: 34,
  );
  static const pressSpring = SpringDescription(
    mass: 1,
    stiffness: 600,
    damping: 42,
  );

  static Duration duration(BuildContext context, [Duration value = standard]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
}
