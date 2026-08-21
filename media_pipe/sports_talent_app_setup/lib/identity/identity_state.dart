/// Identity-verification status, independent of ExerciseType/ExerciseEngine.
enum IdentityVerificationState {
  /// No reference embedding has been captured yet for this session.
  referenceNotCaptured,

  /// A reference embedding exists; periodic checks have not started yet.
  referenceReady,

  /// A check is currently in flight.
  checking,

  /// Most recent usable check matched the reference within threshold.
  match,

  /// Most recent check could not produce a usable comparison (zero faces,
  /// multiple faces, or a too-small/low-quality face). Never counts toward
  /// [IdentitySnapshot.consecutiveMismatchCount].
  inconclusive,

  /// Most recent usable check compared below threshold, but fewer than
  /// [IdentitySnapshot.consecutiveMismatchCount] consecutive mismatches
  /// have occurred yet to confirm a mismatch.
  mismatch,

  /// Two (configurable) consecutive genuine mismatches have occurred.
  /// Sticky: once confirmed, later matches reset the mismatch counter but
  /// do not clear this state - only [reset] (session end) does.
  identityMismatchConfirmed,
}

/// Immutable snapshot of identity-verification state, exposed to the UI.
class IdentitySnapshot {
  const IdentitySnapshot({
    this.state = IdentityVerificationState.referenceNotCaptured,
    this.consecutiveMismatchCount = 0,
    this.inconclusiveCount = 0,
    this.lastSimilarity,
  });

  final IdentityVerificationState state;
  final int consecutiveMismatchCount;
  final int inconclusiveCount;
  final double? lastSimilarity;

  IdentitySnapshot copyWith({
    IdentityVerificationState? state,
    int? consecutiveMismatchCount,
    int? inconclusiveCount,
    double? lastSimilarity,
  }) {
    return IdentitySnapshot(
      state: state ?? this.state,
      consecutiveMismatchCount:
          consecutiveMismatchCount ?? this.consecutiveMismatchCount,
      inconclusiveCount: inconclusiveCount ?? this.inconclusiveCount,
      lastSimilarity: lastSimilarity ?? this.lastSimilarity,
    );
  }
}
