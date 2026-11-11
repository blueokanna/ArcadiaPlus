import 'package:flutter/widgets.dart';

import '../utils/app_lifecycle.dart';

/// A single lifecycle gate for the entire view, including dialogs and overlays.
/// Flutter still schedules frames; this does not add a timer or render engine.
class AppMotionScope extends StatelessWidget {
  const AppMotionScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: AppLifecycle.instance.active,
    child: child,
    builder: (context, active, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(
          disableAnimations: media.disableAnimations || !active,
        ),
        child: TickerMode(enabled: active, child: child!),
      );
    },
  );
}
