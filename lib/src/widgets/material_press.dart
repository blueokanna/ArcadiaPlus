import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:arcadiaplus/src/widgets/spring_press.dart';

/// Native Material buttons own gestures and semantics; this decorator observes
/// their pressed state so touch, keyboard and cancellation share one response.
class MaterialPress extends StatefulWidget {
  const MaterialPress({
    super.key,
    required this.enabled,
    required this.builder,
    this.statesController,
  });
  final bool enabled;
  final WidgetStatesController? statesController;
  final Widget Function(WidgetStatesController) builder;

  @override
  State<MaterialPress> createState() => _MaterialPressState();
}

class _MaterialPressState extends State<MaterialPress> {
  WidgetStatesController? _internalStates;
  WidgetStatesController get _states =>
      widget.statesController ?? (_internalStates ??= WidgetStatesController());
  bool _pressed = false;
  bool _updateScheduled = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_syncPressed);
    _pressed = _states.value.contains(WidgetState.pressed) && widget.enabled;
  }

  @override
  void didUpdateWidget(MaterialPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      (oldWidget.statesController ?? _internalStates)!.removeListener(
        _syncPressed,
      );
      _states.addListener(_syncPressed);
    }
    _pressed = _states.value.contains(WidgetState.pressed) && widget.enabled;
  }

  void _syncPressed() {
    final pressed =
        _states.value.contains(WidgetState.pressed) && widget.enabled;
    if (_pressed == pressed) return;
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
    _internalStates?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SpringPress(pressed: _pressed, child: widget.builder(_states));
}
