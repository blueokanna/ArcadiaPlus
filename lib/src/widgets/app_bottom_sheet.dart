import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_shapes.dart';

/// Modal surfaces belong above the shell navigator and its floating navigation.
/// The route owns the only entrance timeline; content handles keyboard insets.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool? showDragHandle,
  Color? backgroundColor,
  ShapeBorder? shape,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: isScrollControlled,
  useSafeArea: useSafeArea,
  showDragHandle: showDragHandle,
  backgroundColor: backgroundColor,
  shape: shape ?? AppShapes.bottomSheet,
  clipBehavior: Clip.antiAlias,
  sheetAnimationStyle: AnimationStyle(
    duration: AppMotion.duration(context, AppMotion.pageEntrance),
    reverseDuration: AppMotion.duration(context),
  ),
  builder: (context) => SafeArea(top: false, child: builder(context)),
);
