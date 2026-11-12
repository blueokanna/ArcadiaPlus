import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/fluid_page.dart';
import 'route_page_state.dart';

/// Navigation intent; destination changes replace, hierarchical changes push.
enum AppPageTransition { hierarchical, destination }

/// MaterialPage keeps Android's predictive-back gesture and iOS's interactive
/// swipe in the route lifecycle. A CustomTransitionPage cannot participate in
/// those gestures merely by drawing a similar transition.
Page<void> buildAppPage(
  GoRouterState state,
  Widget child, {
  AppPageTransition transition = AppPageTransition.hierarchical,
}) => MaterialPage<void>(
  key: state.pageKey,
  child: PageStorage(
    bucket: RoutePageState.forPath(state.uri.path),
    child: FluidPage(child: child),
  ),
);
