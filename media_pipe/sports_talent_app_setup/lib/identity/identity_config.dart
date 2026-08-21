/// Configuration for the on-device identity-verification layer. Every value
/// here is a V1 starting point - see each doc comment for what still needs
/// physical-device tuning before this gates any real assessment outcome.
library;

/// How often an identity check runs while a test is active. This is a
/// wall-clock cadence, independent of the pose-detection frame-skip
/// interval - it does not run on every camera frame.
const Duration kIdentityVerificationInterval = Duration(seconds: 7);

/// V1 cosine-similarity threshold for "same person". Both embeddings are
/// L2-normalized, so cosine similarity ranges [-1, 1] and equals their dot
/// product. 0.70 is deliberately NOT assumed here - this starting value
/// instead follows the bundled mobilefacenet.tflite model's own upstream
/// integration guidance (cosine > 0.5 "suggests same person", > 0.6
/// "strongly suggests"), picked toward fewer false rejections for a first
/// pass. This MUST be re-tuned from physical test data (varying lighting,
/// distance, camera, and the crop/alignment strategy in
/// face_image_utils.dart) before it gates any real assessment outcome.
const double kFaceSimilarityThresholdV1 = 0.50;

/// Consecutive GENUINE_MISMATCH results required before an identity
/// mismatch is confirmed. A single mismatch is treated as noise (motion
/// blur, brief occlusion, a bad angle) rather than identity fraud.
const int kConsecutiveMismatchesRequiredV1 = 2;

/// Minimum face size, as a fraction of the camera frame's shorter side,
/// for a detected face to be considered usable for embedding. Smaller
/// faces (too far / too small in frame) are treated as INCONCLUSIVE rather
/// than compared.
///
/// Lowered from the original 0.15, then again from 0.08, after physical
/// testing at the real ~2.5-3m full-body exercise distance (1280x720
/// stream). At 0.08 (57.6px), the athlete's face size was observed to
/// fluctuate right around the gate frame to frame - 60x60px (passed) vs.
/// 56x57px (sizeFraction 0.078, rejected) vs. no face detected at all -
/// producing inconsistent INCONCLUSIVE/pass behavior at a distance that
/// isn't itself changing. EXPERIMENTAL DIAGNOSTIC value: 0.06 x 720 =
/// 43.2px, chosen to let this size range reach MobileFaceNet consistently
/// so alignment/similarity behavior at true native pixel counts can
/// actually be observed, not to assert 43px is a reliable embedding input.
/// Still a V1 value requiring further physical tuning - this only widens
/// the size gate, it says nothing about whether a ~50px face's resulting
/// similarity score is reliable (see [kFaceSimilarityThresholdV1],
/// intentionally not touched by this change).
const double kMinFaceSizeFractionV1 = 0.06;

/// Extra margin added around ML Kit's tight face bounding box before
/// cropping for embedding, as a fraction of the box's own width/height on
/// each side. MobileFaceNet-class models are typically trained on loosely
/// cropped faces, not a pixel-tight box.
const double kFaceCropMarginFractionV1 = 0.25;

/// Fixed input resolution expected by the bundled MobileFaceNet model.
const int kFaceEmbeddingInputSize = 112;

/// Asset path of the bundled MobileFaceNet-class TFLite embedding model.
/// Source, license, and shape provenance are documented in the project
/// report - see the identity module's top-level notes.
const String kFaceEmbeddingModelAsset = 'assets/models/mobilefacenet.tflite';
