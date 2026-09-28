import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:arcadiaplus/src/utils/animation_utils.dart';

/// How a route enters and leaves.
enum AppPageTransition {
  /// A page opened on top of another one: it slides in over the page that
  /// stays below, and that page dims where it is.
  ///
  /// The page below deliberately does not move. It is the only thing under
  /// the incoming page, and the app draws its interface over a wallpaper —
  /// the pages themselves are translucent — so a page that slid or faded out
  /// from under its child would drag an edge across the one surface a
  /// transition must never expose on its own.
  ///
  /// This is the motion for every page reached from Settings and anything
  /// else that has a page to return to.
  hierarchical,

  /// A page that replaces the current one with nothing to return to — a
  /// bottom-navigation destination. There is no page underneath, so any
  /// movement below full size would leave the wallpaper alone on screen; the
  /// page magnifies into place from just above its final size instead.
  destination,
}

/// Builds the page for [child] using the app's motion.
CustomTransitionPage<void> buildAppPage(
  GoRouterState state,
  Widget child, {
  AppPageTransition transition = AppPageTransition.hierarchical,
}) {
  final isHierarchical = transition == AppPageTransition.hierarchical;
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: isHierarchical
        ? AnimationUtils.durationMedium3
        : AnimationUtils.durationMedium2,
    reverseTransitionDuration: AnimationUtils.durationMedium2,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(context)) {
        return child;
      }
      return isHierarchical
          ? _HierarchicalTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            )
          : _DestinationTransition(animation: animation, child: child);
    },
  );
}

/// Slides a pushed page in while the page it covers dims.
///
/// The dim is painted by this page over its own content and is driven by
/// [secondaryAnimation], which runs when a page is pushed on top. Both halves
/// of the motion are anchored to the same controller run, so the slide and
/// the dim settle together.
class _HierarchicalTransition extends StatelessWidget {
  const _HierarchicalTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  /// How far the incoming page travels, in logical pixels. Material's shared
  /// axis moves a fixed distance rather than a share of the viewport, so the
  /// motion is the same on a phone and in an expanded desktop window.
  static const double _travel = 32;

  /// How far the covered page dims. Deep enough to read as a layer boundary
  /// in both themes, shallow enough that the page below never disappears.
  static const double _maxScrim = 0.26;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final enter = CurvedAnimation(
      parent: animation,
      curve: AnimationUtils.curveEmphasizedDecelerate,
      reverseCurve: AnimationUtils.curveEmphasizedAccelerate,
    );
    final slide = Tween<Offset>(
      begin: Offset(width > 0 ? _travel / width : 0, 0),
      end: Offset.zero,
    ).animate(enter);

    final scrim = CurvedAnimation(
      parent: secondaryAnimation,
      curve: AnimationUtils.curveStandard,
      reverseCurve: AnimationUtils.curveStandard,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        SlideTransition(position: slide, child: child),
        IgnorePointer(
          child: FadeTransition(
            opacity: scrim.drive(Tween<double>(begin: 0, end: _maxScrim)),
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ],
    );
  }
}

/// Magnifies a replacement page into place.
///
/// The scale never goes below one, so the page always covers the viewport and
/// the backdrop is never on screen by itself.
class _DestinationTransition extends StatelessWidget {
  const _DestinationTransition({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  /// The overscan the page settles in from. Large enough to read as motion,
  /// small enough to read as a settle rather than a zoom.
  static const double _overscan = 1.035;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: AnimationUtils.curveEmphasizedDecelerate,
      reverseCurve: AnimationUtils.curveEmphasizedAccelerate,
    );
    return ScaleTransition(
      scale: Tween<double>(begin: _overscan, end: 1).animate(curved),
      child: child,
    );
  }
}
