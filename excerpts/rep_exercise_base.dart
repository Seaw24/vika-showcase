// Abridged from production source (lib/exercise/core/base/rep_exercise_base.dart).
// Shows the one phase machine every rep exercise shares and the declaration
// hooks a concrete exercise implements. Elided: the baseline lifecycle, the
// kinetic stillness test, credit and retrace bookkeeping, attempt revision
// (patience / prompt / reset), pause discard, hold timing, logging.

/// Which way an exercise's primary signal moves as an attempt departs rest.
enum AttemptFold {
  /// The signal INCREASES away from rest (sit-up trunk, glute-bridge shk).
  opens,

  /// The signal DECREASES away from rest (reverse-crunch shk, V-up hinge).
  closes,
}

/// The four generic phases shared by every rep-based exercise.
enum AttemptPhase { rest, outbound, apex, inbound }

/// The driver's excursion line that marks the furthest phase of an attempt.
final class ApexSpec {
  const ApexSpec({
    required this.threshold,
    this.requiresStableApex = false,
  });

  /// Driver excursion from rest, in the driver's signal units.
  final double threshold;

  /// Requests a stable plateau for apex ENTRY only: the confirmer will not fire
  /// while the driver is still travelling.
  final bool requiresStableApex;
}

/// The only exercise-specific geometry consumed by the shared phase machine.
final class PhasePlan {
  const PhasePlan({
    required this.apex,
    required this.returnTolerance,
    this.closeRequiresStillness = false,
  });

  final ApexSpec apex;

  /// Distance from the frozen driver rest value, in driver signal units.
  final double returnTolerance;

  /// Opt-in: an attempt may close only on a frame verified STILL. Exists for
  /// a driver that crosses to the far side of rest mid-rep (a jump squat's hip
  /// passes standing height at take-off AND at touchdown). Not the default:
  /// chained reps with no pause between them would read as one attempt.
  final bool closeRequiresStillness;
}

/// The buffered signal whose retrace defines "this attempt came back", and
/// whose stillness the whole boundary layer is asked about.
class ReturnSignal {
  const ReturnSignal({
    required this.bufferedKey,
    required this.fold,
    required this.noiseFloor,
    required this.directionRate,
    required this.drift,
    this.apexDirectionRate,
  });

  /// Key into the exercise's `bufferedSignals`.
  final String bufferedKey;

  /// Direction of travel away from rest.
  final AttemptFold fold;

  /// Per-frame detector noise floor for [bufferedKey].
  final double noiseFloor;

  /// Windowed direction gate, in units PER SECOND (time-scaled, so the same
  /// number works at any frame rate).
  final double directionRate;

  /// A separate, stricter rate used only for "has it settled at the far end".
  /// A rate loose enough to catch a slow descent is too loose to call a dwell
  /// stable. Null means "use [directionRate]".
  final double? apexDirectionRate;

  /// Whether this driver's baseline may follow slow drift.
  final BaselineDrift drift;
}

/// Wall-clock hold on the windowed AWAY direction before an attempt may open.
/// Above what jitter can sustain (~5 frames at 30 fps), and strictly below the
/// fastest FAULTED descent, so a too-fast rep still opens an attempt and earns
/// its "you dropped too fast" verdict instead of silence.
const Duration ENTRY_INTENT_CONFIRM = Duration(milliseconds: 150);

/// Base-owned controller for rep exercises.
///
/// Owns the pieces identical across rep exercises (mechanism, not exercise
/// knowledge): the baseline lifecycle, the active frame loop (a template
/// method exercises never override), the attempt boundary (accept/reject
/// bookkeeping, rep log, no-count) and the pause discard. An exercise
/// contributes only declaration, geometry, setup, metrics and completion
/// evidence.
abstract class RepExerciseBase<TFrame extends ExerciseFrame, TState,
    TContext extends RepMetricContext<TFrame>, TCompletion>
    extends ExerciseBase<TFrame> {
  AttemptPhase _attemptPhase = AttemptPhase.rest;

  /// Generic read-only phase for metrics and presentation adapters.
  AttemptPhase get attemptPhase => _attemptPhase;

  /// The one reference the shared machine is allowed to retain.
  double? get driverRestValue;

  // --- Declaration hooks ---

  /// The signal whose retrace defines this exercise's return.
  ReturnSignal get returnSignal;

  /// Apex line and return tolerance for this movement.
  PhasePlan get phasePlan;

  /// Every metric this exercise declares, in one collection. Each metric
  /// carries its own routing (coach or credit channel); the engine derives
  /// the rest.
  MetricCollection<TContext, TState, TCompletion> get metrics;

  /// Checks resolved once per attempt, at the completion boundary. Credit-only.
  List<BoundaryBinding> get boundaryBindings => const [];

  // --- Frame-loop hooks ---

  /// Signals the motion frame buffer tracks on every ready frame.
  Map<String, double> bufferedSignals(TFrame frame);

  /// Per-frame bookkeeping that cannot change [attemptPhase]. Exercises use it
  /// to project the generic phase onto their own phase names.
  void onFrameHook(TFrame frame, PoseView view) {}

  /// Typed metric context for this frame, built after the phase transition so
  /// metrics always see the post-transition phase.
  TContext buildContext(TFrame frame, PoseView view);

  // --- Attempt-boundary hooks ---

  /// Completion evidence broadcast to form metrics on an accepted attempt.
  TCompletion buildCompletion(TFrame finalFrame);

  /// Reset the exercise-owned phase projection after a pause or revision.
  void resetToStartPhase();

  /// The shared phase machine (abridged). One machine runs all 17 rep
  /// exercises; each declares only its [ReturnSignal] and [PhasePlan].
  void _updateSharedPhaseMachine(TFrame frame, PhasePlan plan) {
    final signal = returnSignal;
    final rest = driverRestValue;
    if (rest == null) return;

    final current = _driverValue(frame);
    final now = DateTime.fromMillisecondsSinceEpoch(frame.timestampMs);
    final excursion =
        signal.fold == AttemptFold.closes ? rest - current : current - rest;

    // Direction comes from net movement over a short window divided by REAL
    // elapsed time, never from a 2-frame delta. It returns unknown across a
    // camera stall rather than bridging unobserved time.
    final windowDirection = frameBuffer.directionOverWindow(
      signal.bufferedKey,
      signal.directionRate,
      frames: DIRECTION_WINDOW_FRAMES,
      maximumFrameGapMs: KINETIC_MAX_FRAME_GAP_MS,
    );
    final atApex = excursion >= plan.apex.threshold &&
        (!plan.apex.requiresStableApex ||
            _apexDirection(signal) == ChangeState.stable);

    switch (_attemptPhase) {
      case AttemptPhase.rest:
        // Opens only after the away direction has held for
        // ENTRY_INTENT_CONFIRM. Jitter cannot open an attempt.
        if (!departureArmed || !entryIntentConfirmed) return;
        _attemptPhase = AttemptPhase.outbound;
        frameBuffer.clear();
        return;
      case AttemptPhase.outbound:
        // Apex is asked FIRST here, so a fast rep cannot close on the same
        // frame the apex would have confirmed and lose its depth milestone.
        if (_apexConfirmer.update(atApex, now)) {
          _attemptPhase = AttemptPhase.apex;
          return;
        }
        if (_confirmReturn(signal, plan, excursion, windowDirection, now)) {
          _enterRestPhase();
          return;
        }
        if (_isToward(_stickyDirection, signal)) {
          _attemptPhase = AttemptPhase.inbound;
        }
        return;
      case AttemptPhase.apex:
        if (_isToward(_apexDirection(signal), signal) ||
            excursion < plan.apex.threshold) {
          _attemptPhase = AttemptPhase.inbound;
        }
        return;
      case AttemptPhase.inbound:
        // Return first on the way back; going away again re-opens outbound.
        if (_confirmReturn(signal, plan, excursion, windowDirection, now)) {
          _enterRestPhase();
          return;
        }
        if (_isAway(_stickyDirection, signal)) {
          _attemptPhase = AttemptPhase.outbound;
        }
        return;
    }
  }

  // ... credit, retrace, kinetic stillness, revision and pause discard elided
}
