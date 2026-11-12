import 'package:flutter/material.dart';

import 'expressive_shape.dart';

import '../theme/app_motion.dart';
import 'page_insets.dart';
import '../utils/app_lifecycle.dart';

/// One finite timeline per page, shared by entrance and shape transitions.
/// Rendering stays on Flutter's scheduler; no timer, polling or idle loop.
class FluidPage extends StatefulWidget {
  const FluidPage({super.key, required this.child});
  final Widget child;

  static Animation<double>? animationOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FluidScope>()?.animation;
  @override
  State<FluidPage> createState() => _FluidPageState();
}

class _FluidPageState extends State<FluidPage>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  CurvedAnimation? _curve;
  Animation<double>? _opacity;
  Animation<Offset>? _position;
  void _createEntrance() {
    if (_controller != null) return;
    final controller = _controller = AnimationController(
      vsync: this,
      duration: AppMotion.pageEntrance,
    );
    final curve = _curve = CurvedAnimation(
      parent: controller,
      curve: AppMotion.curve,
    );
    _opacity = Tween<double>(begin: .65, end: 1).animate(curve);
    _position = Tween<Offset>(
      begin: const Offset(0, .012),
      end: Offset.zero,
    ).animate(curve);
  }

  bool _started = false;
  Animation<double>? _routeAnimation;
  bool _timelineSelected = false;
  @override
  void initState() {
    super.initState();
    AppLifecycle.instance.active.addListener(_pause);
  }

  void _pause() {
    if (!AppLifecycle.instance.isActive) _controller?.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_timelineSelected) {
      _timelineSelected = true;
      final route = ModalRoute.of(context)?.animation;
      // The first route is already complete when mounted; give it one finite
      // entrance. Pushed routes keep the navigator's interactive timeline.
      if (route != null && route.status != AnimationStatus.completed) {
        // One eased shape timeline follows the navigator, including reversals
        // during back gestures. No second page controller or composited fade.
        _routeAnimation = route.drive(
          CurveTween(curve: AppMotion.standardCurve),
        );
      }
    }
    // A Material route already owns the page transition. Share its timeline
    // with shape reveals instead of stacking another fade/slide over it.
    if (_routeAnimation != null) {
      _started = true;
      return;
    }
    _createEntrance();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled ||
        !AppLifecycle.instance.isActive) {
      _controller!.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      _controller!.forward();
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_pause);
    _curve?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FluidScope(
    animation: MediaQuery.disableAnimationsOf(context)
        ? const AlwaysStoppedAnimation(1.0)
        : _routeAnimation ?? _curve!,
    child: _routeAnimation != null
        ? widget.child
        : FadeTransition(
            opacity: _opacity!,
            child: SlideTransition(position: _position!, child: widget.child),
          ),
  );
}

class _FluidScope extends InheritedWidget {
  const _FluidScope({required this.animation, required super.child});
  final Animation<double> animation;
  @override
  bool updateShouldNotify(_FluidScope oldWidget) =>
      oldWidget.animation != animation;
}

class FluidEmptyState extends StatelessWidget {
  const FluidEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final animation =
        context.dependOnInheritedWidgetOfExactType<_FluidScope>()?.animation ??
        const AlwaysStoppedAnimation(1.0);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: PageInsets.scroll(context, const EdgeInsets.all(24)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: (constraints.maxWidth - 48).clamp(0, double.infinity),
            minHeight:
                (constraints.maxHeight - 48 - PageInsets.bottomOf(context))
                    .clamp(0, double.infinity),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ExpressiveShape(
                progress: animation,
                pair: ExpressiveShapePair.empty,
                child: ColoredBox(
                  color: colors.secondaryContainer,
                  child: SizedBox(
                    width: 88,
                    height: 88,
                    child: Icon(
                      icon,
                      size: 34,
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
