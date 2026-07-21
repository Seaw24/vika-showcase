// Abridged from production source (lib/exercise/metric_base.dart).
// Internal doc references removed; logic unchanged.

import 'dart:collection';

import 'fault_record.dart';

/* =========================================================================
   MetricBase — generic lifecycle contract for every exercise metric.

   TContext    — the exercise's typed per-frame context (e.g. Squat RepContext)
   TState      — the exercise's phase enum (e.g. SquatState)
   TCompletion — the exercise's typed rep/attempt-completion context

   The base owns the fault mechanics form metrics used to re-declare:
   per-instance storage, read-only exposure, count-on-completed-rep, and the
   clear/reset lifecycle. A concrete metric owns only its detection logic,
   the identity rule for the fault it measures, and genuinely metric-specific
   temporal state (debouncers, windows, per-rep extrema, durations).

   Credit-validity (anti-cheat) metrics share this exact lifecycle — same
   hooks, same FaultRecord store, same priority rule. The one difference is
   composition: the exercise registers them in a SEPARATE collection, so
   their faults gate credit at the attempt boundary instead of feeding
   coaching and logs.

   Channel semantics: the anti channel answers "is this even the exercise?"
   — completely broken form, like a plank on the floor or squat micro-pumps
   that never leave standing — never "is this good form?". A
   marginal-but-real attempt is COUNTED and COACHED by the form channel:
   guide, never block. When a cheating state is detectable PER FRAME, anti
   metrics gate the form channel live — form metrics do not coach a
   non-attempt. A boundary-only signal needs no live gate; the rep-exercise
   gating mechanism is built with the first exercise that needs it, not
   speculatively.
   ========================================================================= */
abstract class MetricBase<TContext, TState, TCompletion> {
  /// Human-readable name for debug/logging.
  String get name;

  final List<FaultRecord> _faults = [];

  /// Completed reps on which this metric recorded at least one fault.
  int faultsCount = 0;

  /// Faults accumulated for the attempt in progress. Read-only view; only the
  /// base mutates the store.
  List<FaultRecord> get faults => UnmodifiableListView(_faults);

  /// Called every frame while the exercise processes an active attempt.
  void update(TContext ctx);

  /// Record a fault. The concrete metric supplies its identity rule via
  /// [duplicateOf]; a fault matching an already-recorded one is dropped so
  /// a condition persisting across frames yields one record per attempt.
  void recordFault(
    FaultRecord fault, {
    bool Function(FaultRecord existing)? duplicateOf,
  }) {
    if (duplicateOf != null && _faults.any(duplicateOf)) return;
    _faults.add(fault);
  }

  /// Called on every exercise phase transition, with the typed frame context
  /// the transition was decided on. Override in metrics that track time,
  /// direction, or boundary geometry (tempo, sync, anti-cheat).
  void onStateTransition(TState from, TState to, TContext context) {}

  /// Accepted completion hook. The exercise calls this only after its
  /// anti-cheat collection recorded no rejection faults for the attempt.
  /// Completion-only form metrics (depth, tempo) override; default is a no-op.
  void onRepComplete(TCompletion completion) {}

  /// Metric-owned values copied into the accepted rep's log before reset.
  Map<String, dynamic> get repLogFields => const {};

  /// Frozen log key for this metric's completed-faulted-reps count;
  /// null (the anti-cheat default) = not logged.
  String? get failsCountKey => null;

  /// Metric-owned set summary values. Default derives from [failsCountKey];
  /// override only for a genuinely different set aggregate.
  Map<String, dynamic> get setLogFields =>
      failsCountKey == null ? const {} : {failsCountKey!: faultsCount};

  /// Metric-specific temporal state reset. The base owns fault clearing;
  /// override this instead of [reset].
  void resetMetricState() {}

  /// Aborted attempt: clear without counting.
  void reset() {
    _faults.clear();
    resetMetricState();
  }

  /// Completed rep: count this rep as faulted if anything was recorded, then
  /// clear for the next attempt.
  void resetAndCountFault() {
    if (_faults.isNotEmpty) {
      faultsCount++;
    }
    reset();
  }
}
