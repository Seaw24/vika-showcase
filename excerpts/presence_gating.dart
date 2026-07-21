// Abridged from production source (lib/exercise/exercise_base.dart and the
// person-detection utilities). The two-line filter at the bottom is the whole
// fix; the comments are the reason it works.

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

abstract class ExerciseBase {
  /// Probability the landmark actually exists in the predicted skeleton.
  /// Drops cleanly when a person leaves frame; stays high for legitimately
  /// occluded landmarks such as the back leg in side-view squats.
  static const double MIN_PRESENCE = 0.7;

  /// Probability the landmark is unoccluded given that it exists.
  /// Deliberately permissive — used only as a secondary gate to reject
  /// fully extrapolated landmarks, never to judge occluded-but-real ones.
  static const double MIN_VISIBILITY = 0.3;

  static bool isLandmarkConfident(PoseLandmark landmark) {
    return landmark.presence >= MIN_PRESENCE &&
        landmark.visibility >= MIN_VISIBILITY;
  }
}
