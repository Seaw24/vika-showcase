// Abridged from production source (lib/exercise/exercise_base.dart).
// Shows the template-method surface a concrete exercise implements, and the
// shared active frame loop that drives it. Elided: pause/resume lifecycle,
// side-lock resolution, voice-coach wiring, logging, debug instrumentation.

/// A frame after geometry derivation: the exercise's typed view of one
/// resolved pose sample (joint angles, normalized distances) plus provenance.
abstract interface class PreparedFrame {
  int get timestampMs;
  TrackedSide get selectedSide;
}

/// Base-owned controller for side-tracked, rep-counted exercises.
///
/// Owns the pieces that proved identical across exercises (mechanism, not
/// exercise knowledge): the personal-baseline lifecycle around
/// [SideBaselineTracker], the active frame loop ([checkingPreparedPose] — a
/// template method exercises never override), the attempt boundary
/// (accept/reject bookkeeping, rep log, no-count), and the pause discard.
/// An exercise contributes only declaration, geometry derivation, its setup
/// predicate, its state machine, metrics, and completion evidence — via the
/// hooks below.
abstract class SideTrackedPreparedExerciseBase<TFrame extends PreparedFrame,
    TState, TContext, TCompletion> extends ExerciseBase {
  late final SideBaselineTracker _baseline = SideBaselineTracker(
    signals: baselineSignals,
  );

  // --- Declaration hooks ---

  /// Which landmarks this movement needs (near-side pairs; the resolver
  /// picks the tracked anatomical side).
  Map<String, SideLandmarkPair> get requiredSideLandmarks;
  Map<String, SideLandmarkPair> get optionalSideLandmarks => const {};

  /// Signals the personal baseline calibrates during the activation hold
  /// (e.g. this user's standing knee angle before a squat set).
  Map<String, String> get baselineSignals;

  /// This frame's value for each declared baseline signal.
  Map<String, double> baselineValues(TFrame frame);

  /// True while the state machine sits in its start/rest phase — the phase
  /// attempts depart from and complete back into.
  bool get isInStartPhase;

  /// Form (coaching) metric collection. An empty collection is legal.
  MetricCollection<TContext, TState, TCompletion> get formMetrics;

  /// Anti-cheat (credit-gating) metric collection. An empty collection is
  /// legal.
  MetricCollection<TContext, TState, TCompletion> get antiMetrics;

  // --- Geometry hooks ---

  /// Raw landmarks → the exercise's typed frame (joint angles, normalized
  /// distances). Null when this frame can't produce valid geometry.
  TFrame? derivePreparedFrame(
    Map<String, PoseLandmark> landmarks, {
    required TrackedSide selectedSide,
    required double scaleFactor,
    required int timestampMs,
  });

  /// Pure setup geometry: is this frame a valid start position?
  bool isInPreparedStartPosition(TFrame frame);

  // --- Frame-loop hooks ---

  /// Signals the motion [frameBuffer] tracks on every ready frame
  /// (direction detection reads net movement over a window, never a
  /// two-frame delta).
  Map<String, double> bufferedSignals(TFrame frame);

  /// Buffered-signal name → max-delta stable gate for the drift-refresh.
  /// ALL declared signals must hold within their gate across the stability
  /// window before a baseline refresh fires. An EMPTY map is a deliberate
  /// opt-out: the applied baseline then holds from the activation freeze.
  Map<String, double> get baselineStabilityGates;

  /// Advance the exercise state machine one ready frame.
  void updateStateMachine(TFrame frame);

  /// Typed metric context for this frame. Called after state transitions so
  /// metrics always see the post-transition phase.
  TContext buildContext(TFrame frame);

  // --- Attempt-boundary hooks ---

  /// Completion evidence broadcast to form metrics on an accepted attempt.
  TCompletion buildCompletion(TFrame finalFrame);

  /// Force the state machine back to its start phase (pause discard).
  void resetToStartPhase();

  /// Clear exercise-owned per-attempt stamps (phase-exit tracking, hold
  /// clocks). Runs at every attempt boundary and pause discard.
  void resetAttemptTransients() {}

  /// Clear motion-detection state (frame buffer, debouncers).
  void resetMotionDetection();

  // --- Base-owned drive loop (exercises never override below this line) ---

  @override
  @protected
  bool advanceFrame(
    Map<PoseLandmarkType, PoseLandmark> smoothedLandmarks,
  ) {
    final input = _resolveSideLandmarks(
      smoothedLandmarks,
      requiredLandmarks: requiredSideLandmarks,
      optionalLandmarks: optionalSideLandmarks,
    );
    final safetySignal = input.safetySignal;
    if (safetySignal != null || input.landmarks == null || input.side == null) {
      publishGuidanceSignal(
        safetySignal ?? const GuidanceSignal.bodyInFrame(),
      );
      return false;
    }

    _applyScaleFactorMeasurement(_sideTorsoScale(input.landmarks!));
    final frame = derivePreparedFrame(
      input.landmarks!,
      selectedSide: input.side!,
      scaleFactor: scaleFactor,
      timestampMs: frameTimestampMs,
    );
    if (frame == null) {
      publishGuidanceSignal(const GuidanceSignal.bodyInFrame());
      return false;
    }
    _advanceActivation(() => _observeSetupFrame(frame));
    if (exerciseState == ExerciseState.activated) {
      checkingPreparedPose(frame);
    }
    return true;
  }

  /// Setup predicate + activation baseline sampling: a passing setup frame
  /// feeds the sample window, a failing one restarts it. The baseline that
  /// every threshold is measured against is this user's own start position,
  /// sampled during the 3-second activation hold and frozen per set.
  bool _observeSetupFrame(TFrame frame) {
    final inPosition = isInPreparedStartPosition(frame);
    if (inPosition) {
      _baseline.observe(frame.selectedSide, baselineValues(frame));
    } else {
      _baseline.clearSamples();
    }
    return inPosition;
  }

  /// The shared active frame loop — a template method; exercises implement
  /// the hooks, never override this. Order matters: baseline prep →
  /// ready-gated motion tracking + state machine → post-transition context →
  /// anti channel → completion edge → form channel while mid-attempt.
  ///
  /// The anti channel deliberately updates on pre-ready frames too:
  /// per-frame anti metrics keep their debounce state live from the first
  /// active frame.
  void checkingPreparedPose(TFrame frame) {
    _prepareBaselineForActiveFrame(frame);

    final wasInStartPhase = isInStartPhase;
    if (_baseline.ready) {
      frameBuffer.addFrame(FrameSnapshot(
        log: bufferedSignals(frame),
        timeStamp: frame.timestampMs,
      ));
      // Calibration-strict gate: baselines may only learn from frames that
      // pass the full setup predicate, pre-transition, between attempts. The
      // setup band bounds WHERE the baseline may drift; the stability window
      // (all gates calm across consecutive frames — a freshly cleared buffer
      // is NOT stable) bounds WHEN we sample it. Slow in-band drift under
      // the gate IS followed on purpose: bounded follow is the design and
      // the setup band is the bound.
      if (isInStartPhase && isInPreparedStartPosition(frame)) {
        _maybeRefreshBaselines(frame);
      }
      updateStateMachine(frame);
    }

    // Context is intentionally created after state transitions.
    final context = buildContext(frame);
    antiMetrics.update(context);

    if (!wasInStartPhase && isInStartPhase) {
      _completeAttempt(frame);
      return;
    }

    if (!isInStartPhase) {
      formMetrics.update(context);
    }
  }

  // _completeAttempt (elided): if the anti collection recorded any rejection
  // fault, the attempt is a no-count — metrics reset without counting and
  // the user is told why. Otherwise the rep is accepted: completion evidence
  // is broadcast to form metrics, the rep log is written from metric-owned
  // fields, and every metric counts-and-clears for the next attempt.
}
