import 'proxy_engine_service.dart';

/// A result describes the last observed core state, including failed changes.
/// A null member means that the core state could not be established.
class ProxySelectionResult {
  const ProxySelectionResult(this.member, {this.error, this.changed = false});

  final String? member;
  final Object? error;
  final bool changed;
}

/// Runs one selection transaction. The owner serializes transactions and
/// supplies a generation guard so obsolete work cannot roll back a new profile.
class ProxySelectionService {
  const ProxySelectionService(this.engine);

  final ProxyEngine engine;

  Future<ProxySelectionResult?> select(
    String group,
    String member, {
    required bool Function() isCurrent,
  }) => engine.transaction((_) => _select(group, member, isCurrent: isCurrent));

  Future<ProxySelectionResult?> _select(
    String group,
    String member, {
    required bool Function() isCurrent,
  }) async {
    bool current() => isCurrent() && engine.isReady;
    if (!current()) return null;
    String? previous;
    try {
      previous = await engine.selected(group);
    } catch (error) {
      return current() ? ProxySelectionResult(null, error: error) : null;
    }
    if (!current()) return null;
    if (previous == member) return ProxySelectionResult(member);

    String? effective;
    Object failure;
    try {
      final accepted = await engine.select(group, member);
      if (!current()) return null;
      effective = await engine.selected(group);
      if (!current()) return null;
      if (accepted && effective == member) {
        return ProxySelectionResult(member, changed: true);
      }
      failure = StateError('Engine did not confirm selection: $group');
    } catch (error) {
      failure = error;
    }
    if (!current()) return null;

    // Even a throwing command may have changed the core. Restore the observed
    // baseline when possible, then read back regardless of the command result.
    if (previous != null && effective != previous) {
      try {
        await engine.select(group, previous);
      } catch (_) {
        // The final read determines the state; a command reply cannot do that.
      }
      if (!current()) return null;
    }
    try {
      effective = await engine.selected(group);
    } catch (_) {
      effective = null;
    }
    if (!current()) return null;
    final recovery = effective == null
        ? 'Core selection is unknown.'
        : effective == previous
        ? 'Previous selection restored.'
        : 'Previous selection could not be restored.';
    return ProxySelectionResult(
      effective,
      error: StateError('$failure $recovery'),
      changed: effective != previous,
    );
  }
}
