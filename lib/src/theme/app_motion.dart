import 'package:flutter/material.dart';

/// Motion is measured in time, independent of the display refresh rate.
abstract final class AppMotion {
  static const short = Duration(milliseconds: 160);
  static const standard = Duration(milliseconds: 240);
  static const curve = Curves.easeInOutCubicEmphasized;
  static const pressSpring = SpringDescription(
    mass: 1,
    stiffness: 600,
    damping: 42,
  );

  static Duration duration(BuildContext context, [Duration value = standard]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
}
