import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Returns from a page that was opened from Settings.
///
/// A page can be reached twice over: pushed on top of the Settings tab, or
/// entered directly — a desktop tab switch, a deep link at cold start — with
/// nothing underneath. Popping is what keeps the page below alive during the
/// return animation and what lets the system back gesture leave the page; the
/// jump back to Settings is only the fallback for when there is nothing to
/// pop. The old unconditional `go` replaced the whole history, so the page
/// underneath was gone before the animation ran and the back gesture had
/// nowhere to go.
void popOrGoSettings(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/settings');
  }
}
