// Abridged from production source (lib/exercise/core/base/exercise_base.dart
// and lib/exercise/core/signal/presence_gate.dart). The two-line filter at the
// bottom is the whole fix; the comments are the reason it works.

/*
  The false-rep problem
  ---------------------
  Pose models don't return "no person". Pointed at an empty room, BlazePose
  invents a plausible skeleton in the furniture — and a rep counter that
  trusts it will happily count reps nobody performed.

  The obvious gate — per-landmark VISIBILITY — fails in both directions:

  - It under-rejects hallucinations: invented landmarks can carry mid-range
    visibility scores.
  - It over-rejects real movement: in a side-view squat the back leg is
    genuinely occluded, and its visibility hovers around ~0.5 on a perfectly
    real rep. Gate on visibility and you reject the user's actual work,
    which is the fastest way to lose their trust.

  The model actually exposes two different probabilities per landmark, and
  they answer different questions:

    presence   = P(this landmark exists in the scene at all)
    visibility = P(this landmark is unoccluded | it exists)

  Presence is the existence signal: it stays ≥0.98 on tracked landmarks —
  including legitimately occluded ones — and craters within a single frame
  when the person leaves (observed at the walkout boundary: presence fell
  0.99 → ~0.2 while visibility barely moved). Visibility is only useful as a
  weak secondary filter against fully extrapolated landmarks.

  Gating on presence, with visibility kept permissive, drove false rep
  counts to zero on empty-room validation captures while side-view tracking
  kept working through occlusion.

  Defense in depth: a selfie-segmentation person detector independently
  rechecks the scene on a slow cadence, triggered faster when frame-level
  average presence dips or landmarks drift to the frame edge. Pose answers
  "is there a skeleton"; segmentation answers "is there a person" — the two
  fail differently, which is the point.
*/

abstract class ExerciseBase<TFrame extends ExerciseFrame> {
  /// Probability the landmark actually exists in the predicted skeleton.
  /// Drops cleanly when a person leaves frame; stays high for legitimately
  /// occluded landmarks such as the back leg in side-view squats.
  static const double MIN_PRESENCE = 0.7;

  /// Probability the landmark is unoccluded given that it exists. Used only as
  /// a secondary gate to reject fully extrapolated landmarks. Lowered from 0.3
  /// after replayed traces showed 0.3 refusing the occluded far-side arm on
  /// 11-12% of honest side-view readings. Fully extrapolated landmarks read
  /// ~0.015 at walkout, so 0.10 still rejects them.
  static const double _MIN_VISIBILITY = 0.10;

  static bool isLandmarkConfident(PoseLandmark landmark) {
    return landmark.presence >= MIN_PRESENCE &&
        landmark.visibility >= _MIN_VISIBILITY;
  }
}

/// Runs before any exercise logic on every frame: person confirm, auto-pause
/// and resume, and the triggers that wake the segmentation detector.
class PresenceGate {
  static const Duration _PERSON_CONFIRM_DURATION = Duration(milliseconds: 400);
  static const Duration _PERSON_LOST_GRACE = Duration(milliseconds: 400);
  static const Duration _PERSON_RESUME_CONFIRM_DURATION =
      Duration(milliseconds: 320);

  // Average landmark presence below this wakes a segmentation check. Raised
  // from 0.35 after 30 recorded walkouts showed the check firing late: the
  // average stays well above 0.35 while the model is still hallucinating a
  // half-visible body.
  static const double _AVG_LOW_PRESENCE_THRESHOLD = 0.55;

  // Frame-edge risk: a person is likely cropped when enough visible joints sit
  // at or past the frame boundary.
  static const double _FRAME_EDGE_MARGIN_RATIO = 0.04;
  static const int _FRAME_EDGE_OUTSIDE_COUNT = 2;
  static const int _FRAME_EDGE_NEAR_EDGE_COUNT = 5;

  // ... onPose / onNoPose state machine elided
}
