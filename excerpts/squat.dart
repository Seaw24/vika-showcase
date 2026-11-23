// Abridged from production source (lib/exercise/reps/squat/squat.dart).
// A whole rep exercise, as a leaf of the shared base: it declares its signal,
// its phase plan and its metrics, and derives its geometry. It never touches
// the camera, smoothing, presence, side selection or the phase machine.
// Elided: setup pose binding, the heel/toe metric rows, set aggregates.

class Squat extends SideTrackedRepExerciseBase<SquatFrameSample, SquatState,
    SquatMetricContext, SquatAttemptCompletion> {
  Squat({int maxRep = SquatConfig.MAX_REP, super.gate, super.clock, super.env})
      : super(targetReps: maxRep);

  SquatState squatState = SquatState.standing;
  SquatState previousSquatState = SquatState.standing;
  bool _reachedBottomThisRep = false;

  final DepthMetric depthMetric = DepthMetric();
  final TempoMetric tempoMetric = TempoMetric();
  final HipShoulderSyncMetric hipShoulderSyncMetric = HipShoulderSyncMetric();
  final LegFoldMetric legFoldMetric = LegFoldMetric(); // credit channel

  /// Trunk lean, both directions, as one live fault with one voice line.
  late final trunkLeanMetric = LiveCheckMetric.bankRows(
    rows: [
      BankLiveCheckRow(
        reading: FrameReading<SquatFrameSample>(
            read: (frame) => frame.trunkLeanDeg,
            readable: (frame) => frame.readings!.trunkTilt.readable),
        check: TrunkLeanSignedCheck.atMost(SquatConfig.TRUNK_FORWARD_LIMIT),
        priority: SquatFaultVoicePriority.trunkLean,
        confirmFrames: SquatConfig.TRUNK_FORWARD_CONFIRM_FRAMES,
      ),
      BankLiveCheckRow(
        reading: FrameReading<SquatFrameSample>(
            read: (frame) => frame.trunkLeanDeg,
            readable: (frame) => frame.readings!.trunkTilt.readable),
        check: TrunkLeanSignedCheck.atLeast(-SquatConfig.TRUNK_BACKWARD_LIMIT),
        priority: SquatFaultVoicePriority.trunkLeanBackward,
        confirmFrames: SquatConfig.TRUNK_BACKWARD_CONFIRM_FRAMES,
      ),
    ],
    faultId: 'trunk',
    phaseLabelOf: _phaseLabel,
    affectsForm: true,
    logKey: 'trunk_lean_fails_count',
    dedupScope: FaultDedupScope.phaseAndType,
  );

  static String _phaseLabel(SquatMetricContext context) =>
      context.squatState.name.toUpperCase();

  /// The cheat line, resolved once at the attempt boundary against the knee's
  /// peak flexion from its own rest. A shallow bob is refused out loud, never
  /// counted.
  @override
  final List<BoundaryBinding> boundaryBindings = const [
    BoundaryBinding(
      check: BoundaryCheck.creditedAmplitude,
      bound: CheckBound.atLeast,
      threshold: SquatConfig.CHEAT_LINE_KNEE_DEG,
      faultId: 'aborted_depth',
      priority: 0,
    ),
  ];

  @override
  late final metrics = MetricCollection([
    depthMetric,
    trunkLeanMetric,
    tempoMetric,
    hipShoulderSyncMetric,
    for (final binding in boundaryBindings)
      BoundaryCheckMetric(binding: binding),
    legFoldMetric,
  ]);

  // The knee CLOSES into the squat. "Did this attempt come back" and "has it
  // stopped" are both asked of this one axis.
  @override
  ReturnSignal get returnSignal => const ReturnSignal(
        bufferedKey: 'kneeAngle',
        fold: AttemptFold.closes,
        noiseFloor: SquatConfig.REST_STABLE_DELTA_DEG,
        directionRate: SquatConfig.DIRECTION_RATE_DEG_PER_SEC,
        apexDirectionRate: SquatConfig.APEX_DIRECTION_RATE_DEG_PER_SEC,
        drift: BaselineDrift.follows,
      );

  // Apex depth is measured from THIS user's standing knee angle, calibrated
  // during the activation hold, not from a fixed number.
  @override
  PhasePlan get phasePlan => PhasePlan(
        apex: ApexSpec(
          threshold:
              (driverRestValue ?? SquatConfig.SETUP_STANDING_KNEE_ANGLE_MIN) -
                  SquatConfig.GOOD_DEPTH_KNEE_ANGLE_RANGE[1],
        ),
        returnTolerance: SquatConfig.STANDING_RETURN_TOLERANCE,
      );

  @override
  SquatFrameSample? deriveRepFrame(
    Map<String, PoseLandmark> landmarks, {
    required TrackedSide selectedSide,
    required double scaleFactor,
    required int timestampMs,
  }) {
    final hip = landmarks['hip']!;
    final knee = landmarks['knee']!;
    final ankle = landmarks['ankle']!;
    final shoulder = landmarks['shoulder']!;

    final kneeAngle = interiorAngle(hip, knee, ankle);
    final trunkClockAngle = segmentClock(hip, shoulder);
    // Signed geometry follows the side that supplied the landmarks. The live
    // facing classifier can flip mid-rep and would invert the lean's sign, so
    // the locked side is used instead.
    return SquatFrameSample(
      timestampMs: timestampMs,
      selectedSide: selectedSide,
      scalePx: scaleFactor,
      kneeAngleDeg: kneeAngle,
      thighDeviationDeg: deviationFromDown(hip, knee),
      trunkClockAngleDeg: trunkClockAngle,
      trunkLeanDeg: convertClockAngleToTrunkLean(
          trunkClockAngle,
          selectedSide == TrackedSide.right
              ? CameraFacing.right
              : CameraFacing.left),
      // ... readings, heel line, setup verdict
    );
  }

  @override
  Map<String, double> bufferedSignals(SquatFrameSample frame) => {
        'kneeAngle': frame.kneeAngleDeg,
        'thighDeviation': frame.thighDeviationDeg,
        'trunkLean': frame.trunkLeanDeg,
        'heelDistance': frame.heelDistancePx,
      };

  @override
  SquatMetricContext buildContext(SquatFrameSample frame, PoseView view) =>
      SquatMetricContext(frame: frame, view: view, phase: squatState);

  @override
  SquatAttemptCompletion buildCompletion(SquatFrameSample finalFrame) =>
      SquatAttemptCompletion(
        phaseExitedBeforeStanding: previousSquatState,
        reachedBottom: _reachedBottomThisRep,
      );

  @override
  void resetToStartPhase() => squatState = SquatState.standing;

  /// The generic phase is authoritative. Squat only projects it onto its own
  /// names for metrics and log labels.
  @override
  void onFrameHook(SquatFrameSample frame, PoseView view) {
    final newState = switch (attemptPhase) {
      AttemptPhase.rest => SquatState.standing,
      AttemptPhase.outbound => SquatState.descending,
      AttemptPhase.apex => SquatState.bottom,
      AttemptPhase.inbound => SquatState.ascending,
    };
    if (newState == squatState) return;

    final from = squatState;
    previousSquatState = from;
    squatState = newState;
    if (newState == SquatState.bottom) _reachedBottomThisRep = true;
    // Metrics receive the same frame the transition was decided on.
    metrics.onStateTransition(from, newState,
        SquatMetricContext(frame: frame, view: view, phase: newState));
  }
}
