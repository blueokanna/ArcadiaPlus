import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:arcadiaplus/src/widgets/spring_press.dart';

class AdaptiveButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip clipBehavior;
  final WidgetStatesController? statesController;

  const AdaptiveButton({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
  });

  @override
  State<AdaptiveButton> createState() => _AdaptiveButtonState();
}

class _AdaptiveButtonState extends State<AdaptiveButton> {
  final _internalStates = WidgetStatesController();
  WidgetStatesController get _states =>
      widget.statesController ?? _internalStates;
  bool _pressed = false;
  bool _updateScheduled = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_syncPressed);
    _pressed =
        _states.value.contains(WidgetState.pressed) &&
        (widget.onPressed != null || widget.onLongPress != null);
  }

  @override
  void didUpdateWidget(AdaptiveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      (oldWidget.statesController ?? _internalStates).removeListener(
        _syncPressed,
      );
      _states.addListener(_syncPressed);
    }
    _pressed =
        _states.value.contains(WidgetState.pressed) &&
        (widget.onPressed != null || widget.onLongPress != null);
  }

  void _syncPressed() {
    final pressed =
        _states.value.contains(WidgetState.pressed) &&
        (widget.onPressed != null || widget.onLongPress != null);
    if (_pressed == pressed) return;
    // Material may update disabled/pressed state while rebuilding its child.
    // Rebuilding an ancestor there would violate Flutter's build contract.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_updateScheduled) {
        _updateScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateScheduled = false;
          if (mounted) _syncPressed();
        });
      }
      return;
    }
    setState(() => _pressed = pressed);
  }

  @override
  void dispose() {
    _states.removeListener(_syncPressed);
    _internalStates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SpringPress(
    pressed: _pressed,
    child: FilledButton(
      onPressed: widget.onPressed,
      onLongPress: widget.onLongPress,
      style: widget.style,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      clipBehavior: widget.clipBehavior,
      statesController: _states,
      child: widget.child,
    ),
  );
}

class AdaptiveOutlinedButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip clipBehavior;
  final WidgetStatesController? statesController;

  const AdaptiveOutlinedButton({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      clipBehavior: clipBehavior,
      statesController: statesController,
      child: child,
    );
  }
}

class AdaptiveTextButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip clipBehavior;
  final WidgetStatesController? statesController;

  const AdaptiveTextButton({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      clipBehavior: clipBehavior,
      statesController: statesController,
      child: child,
    );
  }
}
