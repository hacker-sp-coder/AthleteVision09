import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'face_embedder.dart';
import 'face_image_utils.dart';
import 'identity_config.dart';
import 'identity_state.dart';

/// Outcome of a single enrollment attempt from one camera frame.
enum EnrollmentResult { success, noFaceDetected, multipleFacesDetected, faceTooSmall, error }

/// TEMPORARY DEBUG taxonomy for why a periodic check came back INCONCLUSIVE
/// - the production [IdentityVerificationState.inconclusive] stays a single
/// state (per spec); this is purely for [IdentityVerifier._debugLog] and
/// the physical-testing debug panel, not part of the state machine's
/// public contract. [faceQualityFailure] is reserved for a future
/// non-size quality signal - `isFaceUsable` currently only checks size, so
/// every size-based rejection logs as [faceTooSmall].
enum _InconclusiveReason {
  noFace,
  multipleFaces,
  faceTooSmall,
  // ignore: unused_field
  faceQualityFailure,
  cropFailure,
  embeddingFailure,
  other,
}

/// Session-scoped on-device identity verification.
///
/// Owns its own ML Kit [FaceDetector] and TFLite [FaceEmbedder], entirely
/// independent of ExerciseEngine/ExerciseType - the exercise engines never
/// see or affect this state. The reference embedding lives only in memory
/// for this instance's lifetime; call [reset] to discard it (e.g. when a
/// test/session ends) and [dispose] when the owning screen is disposed.
///
/// Face *detection* (ML Kit) only locates/validates a face; it never
/// performs identity matching. Identity comparison is done separately here
/// via the bundled MobileFaceNet-class embedding model + cosine similarity.
class IdentityVerifier extends ChangeNotifier {
  IdentityVerifier()
    : _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          // Required for 5-point similarity-transform face alignment - see
          // face_image_utils.dart. Without this, face.landmarks is always
          // empty and alignment falls back to the coarser bounding-box
          // crop.
          enableLandmarks: true,
        ),
      ),
      _embedder = FaceEmbedder();

  final FaceDetector _faceDetector;
  final FaceEmbedder _embedder;

  List<double>? _referenceEmbedding;
  bool _busy = false;
  DateTime? _lastCheckAt;

  /// The [InputImageRotation] computed at the moment enrollment succeeded,
  /// frozen for the rest of the session. Every later crop (all periodic
  /// verification checks) is rotated-to-upright using THIS value rather
  /// than a freshly recomputed one, so the enrollment and every
  /// verification crop share the exact same rotation transform even if the
  /// live device-orientation reading (`CameraController.value
  /// .deviceOrientation`, sensor-driven) drifts or flaps during the test -
  /// see the project report's rotation-consistency finding. ML Kit face
  /// *detection* still uses the live rotation passed into [maybeVerify]
  /// (it needs the phone's actual current tilt to find the face at all);
  /// only the embedding crop's rotation is frozen.
  InputImageRotation? _referenceRotation;

  /// Whether periodic verification has been armed for the current test.
  /// Set only by [activate] (called once the test is actually active, not
  /// merely once a reference exists) and cleared by [reset]. [isDue] can
  /// never be true while this is false - enrollment being complete is not
  /// by itself enough to permit a check.
  bool _active = false;

  /// Bumped by [reset]. A [maybeVerify] call captures the generation it
  /// started under; if [reset] (and possibly a fresh [activate] for a new
  /// test) runs while that call is still awaiting ML Kit, the generation
  /// mismatch on resume marks its result stale so it can neither write into
  /// the new test's state nor release a lock it doesn't hold - see
  /// DEBUG-log root-cause notes on the Stop/reset -> Start/activate race.
  int _generation = 0;

  IdentitySnapshot _snapshot = const IdentitySnapshot();
  IdentitySnapshot get snapshot => _snapshot;

  bool get hasReference => _referenceEmbedding != null;

  /// TEMPORARY DEBUG-only: reason for the most recent INCONCLUSIVE result
  /// (see [_InconclusiveReason]), for the physical-testing debug panel.
  /// Not part of the production state model - cleared on MATCH/MISMATCH/
  /// reset so it always reflects "why was the *last* inconclusive result
  /// inconclusive", not stale history.
  String? debugLastInconclusiveReason;

  /// TEMPORARY DEBUG instrumentation for physical-testing lifecycle audits.
  /// Strip once the identity UI is finalized. Gated on [kDebugMode] so it
  /// never fires in a release build.
  void _debugLog(String message) {
    if (kDebugMode) debugPrint('[IdentityVerifier] $message');
  }

  /// TEMPORARY DEBUG-only: saves the final 112x112 letterboxed crop as a
  /// PNG in the system temp/cache dir, so the enrollment crop and a
  /// verification crop can be pulled off the device and visually compared
  /// side by side. Never called in a release build; not part of the
  /// production flow (no persistence of the athlete's face beyond this
  /// debug artifact, which the physical tester is responsible for
  /// deleting).
  Future<void> _saveDebugCrop(img.Image crop, String label) async {
    if (!kDebugMode) return;
    try {
      final bytes = img.encodePng(crop);
      final path =
          '${Directory.systemTemp.path}/identity_debug_${label}_'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes);
      _debugLog('saved debug crop ($label): $path');
    } catch (e) {
      _debugLog('failed to save debug crop ($label): $e');
    }
  }

  Future<void> _ensureEmbedderLoaded() async {
    if (!_embedder.isLoaded) {
      await _embedder.load();
    }
  }

  /// Attempts to capture the reference embedding from one camera frame.
  /// Requires exactly one usable face; rejects zero/multiple/too-small
  /// faces per spec rather than guessing.
  Future<EnrollmentResult> tryEnrollFromFrame({
    required CameraImage image,
    required InputImageRotation rotation,
  }) async {
    if (_busy) return EnrollmentResult.error;
    _busy = true;
    try {
      await _ensureEmbedderLoaded();
      final faces = await _faceDetector.processImage(_toInputImage(image, rotation));
      if (faces.isEmpty) {
        _debugLog('enrollment attempt: noFaceDetected (separate from identity mismatch)');
        return EnrollmentResult.noFaceDetected;
      }
      if (faces.length > 1) {
        _debugLog('enrollment attempt: multipleFacesDetected (${faces.length} faces)');
        return EnrollmentResult.multipleFacesDetected;
      }

      final face = faces.single;
      if (!isFaceUsable(
        face,
        imageWidth: image.width.toDouble(),
        imageHeight: image.height.toDouble(),
      )) {
        _debugLog('enrollment attempt: faceTooSmall');
        return EnrollmentResult.faceTooSmall;
      }

      final tensor = prepareEmbeddingTensor(
        image: image,
        face: face,
        rotation: rotation,
        onDebugCrop: (info) {
          _debugLog(
            'enrollment aligned=${info.aligned} '
            'sourceRegion=(left=${info.left}, top=${info.top}, '
            'width=${info.width}, height=${info.height}) finalCrop=112x112',
          );
          unawaited(_saveDebugCrop(info.finalCrop, 'enrollment'));
        },
      );
      if (tensor == null) {
        _debugLog('enrollment attempt: error (tensor preparation failed)');
        return EnrollmentResult.error;
      }

      _referenceEmbedding = _embedder.embed(tensor);
      _referenceRotation = rotation;
      _snapshot = const IdentitySnapshot(state: IdentityVerificationState.referenceReady);
      _debugLog(
        'enrollment success - state=referenceReady, generation=$_generation, '
        'frozenRotation=$_referenceRotation',
      );
      notifyListeners();
      return EnrollmentResult.success;
    } catch (e) {
      debugPrint('Identity enrollment error: $e');
      return EnrollmentResult.error;
    } finally {
      _busy = false;
    }
  }

  /// Marks the test as actually active, arming the periodic-verification
  /// timer. Must be called exactly once, at the moment the test truly
  /// starts (not at enrollment success, and not merely because the camera
  /// stream is running) - see [isDue]. The first eligible check will not
  /// fire until a full [kIdentityVerificationInterval] after this call, not
  /// immediately.
  void activate() {
    if (_referenceEmbedding == null) return;
    _active = true;
    _lastCheckAt = DateTime.now();
    _debugLog('activate() - test active, generation=$_generation, lastCheckAt=$_lastCheckAt');
  }

  /// Whether enough time has passed since the test became active (or since
  /// the last check) to run another one (see [kIdentityVerificationInterval]).
  /// Always false until [activate] has been called - a reference embedding
  /// existing is necessary but not sufficient. Callers should gate calls to
  /// [maybeVerify] on this rather than calling it every frame.
  bool get isDue {
    if (!_active || _referenceEmbedding == null) return false;
    final last = _lastCheckAt;
    return last != null && DateTime.now().difference(last) >= kIdentityVerificationInterval;
  }

  /// Runs one identity check against the current frame if due; a no-op
  /// otherwise (including while a previous check is still in flight, or
  /// before [activate] has been called). Safe to call on every processed
  /// frame - the 7-second cadence and reentrancy guard are handled
  /// internally.
  Future<void> maybeVerify({
    required CameraImage image,
    required InputImageRotation rotation,
  }) async {
    final callTime = DateTime.now();
    final due = isDue;
    _debugLog(
      'maybeVerify() called at $callTime - frame=${image.width}x${image.height} '
      'busy=$_busy due=$due state=${_snapshot.state} hasReference=$hasReference '
      'lastCheckAtBefore=$_lastCheckAt',
    );
    if (_busy || !due) return;
    final reference = _referenceEmbedding;
    if (reference == null) return;

    // Captured under this generation so a concurrent reset()+activate()
    // (a new test starting while this call is still awaiting ML Kit below)
    // can be detected on resume - see [_generation] docs.
    final generation = _generation;
    _busy = true;
    _lastCheckAt = DateTime.now();
    _debugLog('maybeVerify() proceeding - generation=$generation lastCheckAtAfter=$_lastCheckAt');
    _snapshot = _snapshot.copyWith(state: IdentityVerificationState.checking);
    notifyListeners();
    try {
      final faces = await _faceDetector.processImage(_toInputImage(image, rotation));
      // The test may have been stopped/reset (and possibly a new one
      // started) while the above await was in flight - don't let a stale
      // result land in a different test's state.
      if (generation != _generation) {
        _debugLog(
          'maybeVerify() result discarded - stale generation '
          '(call gen=$generation, current gen=$_generation)',
        );
        return;
      }

      // --- face count -------------------------------------------------
      _debugLog(
        'maybeVerify() faceCount=${faces.length} '
        'boxes=${faces.map((f) => f.boundingBox).toList()}',
      );
      if (faces.isEmpty) {
        _recordInconclusive(_InconclusiveReason.noFace, 'no face detected in frame');
        return;
      }
      if (faces.length > 1) {
        _recordInconclusive(_InconclusiveReason.multipleFaces, '${faces.length} faces detected');
        return;
      }

      // --- face quality/size gate --------------------------------------
      final face = faces.single;
      final box = face.boundingBox;
      final shorterSide = math.min(image.width, image.height).toDouble();
      final sizeFraction = shorterSide > 0
          ? math.min(box.width, box.height) / shorterSide
          : 0.0;
      final requiredFacePx = (shorterSide * kMinFaceSizeFractionV1).toStringAsFixed(1);
      _debugLog(
        'maybeVerify() SIZE_GATE frameSize=${image.width}x${image.height} '
        'faceBox=$box faceWidthPx=${box.width.toStringAsFixed(1)} '
        'faceHeightPx=${box.height.toStringAsFixed(1)} '
        'minFaceDimensionPx=${math.min(box.width, box.height).toStringAsFixed(1)} '
        'sizeFraction=${sizeFraction.toStringAsFixed(3)} '
        'thresholdFraction=$kMinFaceSizeFractionV1 '
        'requiredMinFacePx=$requiredFacePx (= shorterSide $shorterSide * threshold)',
      );
      if (!isFaceUsable(
        face,
        imageWidth: image.width.toDouble(),
        imageHeight: image.height.toDouble(),
      )) {
        _recordInconclusive(
          _InconclusiveReason.faceTooSmall,
          'gate=isFaceUsable(face_image_utils.dart) [OUR gate, not ML Kit internal] - '
          'sizeFraction=${sizeFraction.toStringAsFixed(3)} < thresholdFraction=$kMinFaceSizeFractionV1 '
          '(face was ${math.min(box.width, box.height).toStringAsFixed(1)}px, needed $requiredFacePx px)',
        );
        return;
      }

      // --- bounding-box crop + preprocessing ---------------------------
      // Use the ROTATION FROZEN AT ENROLLMENT for the crop itself (ML Kit
      // detection above still used the live `rotation` to find the face).
      // If these two differ, the crop would otherwise be rotated
      // differently from the enrollment crop for the same physical face -
      // see [_referenceRotation] docs.
      final cropRotation = _referenceRotation ?? rotation;
      if (cropRotation != rotation) {
        _debugLog(
          'maybeVerify() rotation DRIFT detected: live=$rotation frozen(enrollment)=$_referenceRotation '
          '- using frozen rotation for crop',
        );
      }
      Float32List? tensor;
      try {
        tensor = prepareEmbeddingTensor(
          image: image,
          face: face,
          rotation: cropRotation,
          onDebugCrop: (info) {
            _debugLog(
              'verification aligned=${info.aligned} '
              'sourceRegion=(left=${info.left}, top=${info.top}, '
              'width=${info.width}, height=${info.height}) finalCrop=112x112',
            );
            unawaited(_saveDebugCrop(info.finalCrop, 'verification'));
          },
        );
      } catch (e) {
        _debugLog('maybeVerify() crop/preprocess threw: $e');
        _recordInconclusive(_InconclusiveReason.cropFailure, 'exception during crop: $e');
        return;
      }
      if (tensor == null) {
        _debugLog('maybeVerify() cropSucceeded=false (degenerate crop region)');
        _recordInconclusive(_InconclusiveReason.cropFailure, 'prepareEmbeddingTensor returned null');
        return;
      }
      _debugLog(
        'maybeVerify() cropSucceeded=true tensorLength=${tensor.length} '
        'expectedLength=${kFaceEmbeddingInputSize * kFaceEmbeddingInputSize * 3}',
      );

      // --- MobileFaceNet inference + embedding validity -----------------
      List<double> candidate;
      try {
        candidate = _embedder.embed(tensor);
      } catch (e) {
        _debugLog('maybeVerify() embedding inference threw: $e');
        _recordInconclusive(_InconclusiveReason.embeddingFailure, 'exception during inference: $e');
        return;
      }
      final hasNaN = candidate.any((v) => v.isNaN);
      final isAllZero = candidate.every((v) => v == 0);
      _debugLog(
        'maybeVerify() embeddingShape=[${candidate.length}] hasNaN=$hasNaN allZero=$isAllZero',
      );
      if (candidate.isEmpty || hasNaN || isAllZero) {
        _recordInconclusive(
          _InconclusiveReason.embeddingFailure,
          'invalid embedding (empty/NaN/all-zero)',
        );
        return;
      }

      // --- cosine similarity + MATCH/MISMATCH ---------------------------
      final similarity = FaceEmbedder.cosineSimilarity(reference, candidate);
      _debugLog(
        'maybeVerify() cosineSimilarity=${similarity.toStringAsFixed(4)} '
        'threshold=$kFaceSimilarityThresholdV1',
      );
      if (similarity >= kFaceSimilarityThresholdV1) {
        _recordMatch(similarity);
      } else {
        _recordMismatch(similarity);
      }
    } catch (e) {
      debugPrint('Identity verification error: $e');
      if (generation == _generation) {
        _recordInconclusive(_InconclusiveReason.other, 'unexpected exception: $e');
      }
    } finally {
      // Only release the lock if it's still this call's lock to release -
      // a stale (superseded-generation) call must not clear a newer test's
      // in-progress _busy flag.
      if (generation == _generation) _busy = false;
    }
  }

  void _recordMatch(double similarity) {
    // Sticky confirmation: a later match does not clear an already
    // confirmed mismatch, only [reset] does - see IdentityVerificationState
    // docs.
    final wasConfirmed = _snapshot.state == IdentityVerificationState.identityMismatchConfirmed;
    _snapshot = IdentitySnapshot(
      state: wasConfirmed
          ? IdentityVerificationState.identityMismatchConfirmed
          : IdentityVerificationState.match,
      consecutiveMismatchCount: 0,
      inconclusiveCount: _snapshot.inconclusiveCount,
      lastSimilarity: similarity,
    );
    debugLastInconclusiveReason = null;
    _debugLog(
      'result=MATCH similarity=$similarity consecutiveMismatchCount=0 '
      'identityMismatchConfirmed=$wasConfirmed lastCheckAt=$_lastCheckAt',
    );
    notifyListeners();
  }

  void _recordMismatch(double similarity) {
    final count = _snapshot.consecutiveMismatchCount + 1;
    final confirmed = count >= kConsecutiveMismatchesRequiredV1;
    _snapshot = IdentitySnapshot(
      state: confirmed
          ? IdentityVerificationState.identityMismatchConfirmed
          : IdentityVerificationState.mismatch,
      consecutiveMismatchCount: count,
      inconclusiveCount: _snapshot.inconclusiveCount,
      lastSimilarity: similarity,
    );
    debugLastInconclusiveReason = null;
    _debugLog(
      'result=MISMATCH similarity=$similarity consecutiveMismatchCount=$count '
      'identityMismatchConfirmed=$confirmed lastCheckAt=$_lastCheckAt',
    );
    notifyListeners();
  }

  void _recordInconclusive(_InconclusiveReason reason, String detail) {
    _snapshot = _snapshot.copyWith(
      state: IdentityVerificationState.inconclusive,
      inconclusiveCount: _snapshot.inconclusiveCount + 1,
    );
    debugLastInconclusiveReason = reason.name;
    _debugLog(
      'result=INCONCLUSIVE reason=${reason.name} detail=$detail '
      'inconclusiveCount=${_snapshot.inconclusiveCount} '
      'consecutiveMismatchCount=${_snapshot.consecutiveMismatchCount} lastCheckAt=$_lastCheckAt',
    );
    notifyListeners();
  }

  InputImage _toInputImage(CameraImage image, InputImageRotation rotation) {
    final plane = image.planes.first;
    final format = InputImageFormatValue.fromRawValue(image.format.raw)!;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// Clears the in-memory reference embedding and all counters. Call when
  /// a test/session ends - the embedding must not outlive the session it
  /// was captured for (no persistence, no upload).
  void reset() {
    _debugLog(
      'reset() called - previous state=${_snapshot.state} '
      'consecutiveMismatchCount=${_snapshot.consecutiveMismatchCount} busy=$_busy',
    );
    _generation++;
    _referenceEmbedding = null;
    _referenceRotation = null;
    _lastCheckAt = null;
    _active = false;
    _busy = false;
    _snapshot = const IdentitySnapshot();
    debugLastInconclusiveReason = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _faceDetector.close();
    _embedder.dispose();
    super.dispose();
  }
}
