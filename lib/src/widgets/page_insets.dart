import 'package:flutter/widgets.dart';

/// The shell owns navigation geometry. Pages reserve it inside their scroll
/// content, so the viewport can continue behind the floating navigation.
class PageInsets extends InheritedWidget {
  const PageInsets({super.key, required this.bottom, required super.child});
  final double bottom;

  static double bottomOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageInsets>()?.bottom ?? 0;

  static EdgeInsetsGeometry scroll(
    BuildContext context,
    EdgeInsetsGeometry base,
  ) => base.add(EdgeInsets.only(bottom: bottomOf(context)));

  @override
  bool updateShouldNotify(PageInsets oldWidget) => bottom != oldWidget.bottom;
}
