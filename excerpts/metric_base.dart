// Abridged from production source (lib/exercise/core/metric/metric_base.dart).
// Every form aspect and every anti-cheat rule is a small metric object with this
// lifecycle. Elided: movement-end span measurement, set-log aggregation.

/// Which machinery a metric's faults feed.
///
/// A [coach] fault becomes coaching and the rep log; a [credit] fault refuses
/// the attempt at its boundary. The credit channel answers "is this even the
/// exercise?", never "is this good form?". A marginal-but-real attempt is
/// COUNTED and COACHED: guide, never block.
enum MetricChannel { coach, credit }

/* MetricBase: lifecycle contract for every exercise metric.

   TContext    the exercise's typed per-frame context (e.g. SquatMetricContext)
   TState      the exercise's phase enum (e.g. SquatState)
   TCompletion the exercise's typed rep/attempt-completion context

   The base owns fault mechanics (per-instance store, read-only exposure,
   count-on-completed-rep, reset). A concrete metric owns only its detection
   logic, its fault identity rule, its routing facts ([channel], [samplesRest])
   and its own temporal state (debouncers, windows, per-rep extrema).

   Anti-cheat metrics share this exact lifecycle. They differ only in the
   declared [channel], which MetricCollection derives every routing, halting
   and counting rule from. */
abstract class MetricBase<TContext, TState, TCompletion> {
  final List<FaultRecord> _faults = [];

  /// Fault routing. Only a credit-gating metric declares otherwise.
  MetricChannel get channel => MetricChannel.coach;

  /// Rest frames are WITHHELD by default, so an unguarded peak/min tracker can
  /// never silently eat rest posture. Nothing may fire from a rest frame: rest
  /// is recovery, not a lapse.
  bool get samplesRest => false;

  /// Completed reps on which this metric recorded at least one fault.
  int faultsCount = 0;

  /// Completed reps this metric actually JUDGED, the denominator of
  /// [faultsCount]. Only meaningful when [canDeclineToJudge].
  int judgedCount = 0;

  /// Faults for the attempt in progress. Read-only; only the base mutates.
  List<FaultRecord> get faults => UnmodifiableListView(_faults);

  /// Called every frame while the exercise processes an active attempt.
  void update(TContext ctx);

  /// Record a fault. A fault matching an already-recorded one is dropped, so a
  /// condition persisting across frames yields one record per attempt.
  void recordFault(
    FaultRecord fault, {
    bool Function(FaultRecord existing)? duplicateOf,
  }) {
    if (duplicateOf != null && _faults.any(duplicateOf)) return;
    _faults.add(fault);
  }

  /// Every phase transition, with the frame the transition was decided on.
  void onStateTransition(TState from, TState to, TContext context) {}

  /// Broadcast at the completion edge BEFORE the credit scan reads the
  /// collection, so a fault recorded here still gates credit. [value] is the
  /// attempt's peak driver excursion; the base owns the reading.
  void onAttemptBoundary(double value) {}

  /// Broadcast only on an attempt no credit metric refused, and only to coach
  /// metrics (depth, tempo).
  void onRepComplete(TCompletion completion) {}

  /// True when this metric can DECLINE to judge a rep (no span measured, the
  /// milestone never reached). A fault-count-only score cannot tell "no rep
  /// had this fault" from "this metric never got to judge a rep". The second
  /// reads as a clean 1.0 and becomes praise for something nobody measured.
  /// Publishing the denominator is what keeps coaching honest.
  bool get canDeclineToJudge => false;

  /// Whether THIS attempt gave the metric enough evidence for a verdict.
  bool get judgedThisAttempt => true;

  /// Metric-specific temporal state reset. Override this, not [reset].
  void resetMetricState() {}

  /// Aborted or refused attempt: clear without counting. A no-counted attempt
  /// enters neither [faultsCount] nor [judgedCount].
  void reset() {
    _faults.clear();
    resetMetricState();
  }

  /// Completed rep: count it as judged, and as faulted if anything was
  /// recorded, then clear for the next attempt.
  void resetAndCountFault() {
    if (canDeclineToJudge && judgedThisAttempt) judgedCount++;
    if (_faults.isNotEmpty) faultsCount++;
    reset();
  }
}
