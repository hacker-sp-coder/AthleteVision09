import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'identity_config.dart';

/// Thin wrapper around the bundled MobileFaceNet-class TFLite embedding
/// model.
///
/// Model provenance: `assets/models/mobilefacenet.tflite`, sourced from
/// hugocornellier/face_detection_tflite (Apache-2.0 licensed repository;
/// README states "All models are Apache 2.0 licensed" and documents this
/// file as based on MobileFaceNets, arXiv:1804.07573). Input [1,112,112,3]
/// float32 RGB normalized to [-1,1]; output [1,192] float32. See the
/// project report for the full provenance/license note.
class FaceEmbedder {
  Interpreter? _interpreter;

  bool get isLoaded => _interpreter != null;

  /// Loads and validates the bundled model. Throws [StateError] if the
  /// model's actual tensor shapes don't match what this module expects -
  /// deliberately fails loudly rather than silently producing garbage
  /// embeddings.
  Future<void> load() async {
    if (_interpreter != null) return;
    final interpreter = await Interpreter.fromAsset(kFaceEmbeddingModelAsset);

    final inputShape = interpreter.getInputTensor(0).shape;
    final outputShape = interpreter.getOutputTensor(0).shape;
    final validInput =
        inputShape.length == 4 &&
        inputShape[1] == kFaceEmbeddingInputSize &&
        inputShape[2] == kFaceEmbeddingInputSize &&
        inputShape[3] == 3;
    final validOutput = outputShape.length == 2 && outputShape[0] == 1;
    if (!validInput || !validOutput) {
      interpreter.close();
      throw StateError(
        'Unexpected mobilefacenet.tflite tensor shapes: '
        'input=$inputShape output=$outputShape',
      );
    }
    _interpreter = interpreter;
  }

  int get embeddingDimension => _interpreter!.getOutputTensor(0).shape[1];

  /// Runs inference on a pre-normalized [1,112,112,3] float32 tensor (RGB,
  /// values in [-1, 1] - see `face_image_utils.dart`) and returns an
  /// L2-normalized embedding vector.
  List<double> embed(Float32List inputTensor) {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('FaceEmbedder.load() must complete before embed().');
    }
    final input = inputTensor.reshape([
      1,
      kFaceEmbeddingInputSize,
      kFaceEmbeddingInputSize,
      3,
    ]);
    final output = List.generate(1, (_) => List.filled(embeddingDimension, 0.0));
    interpreter.run(input, output);
    final raw = output[0];
    final rawNorm = math.sqrt(raw.fold<double>(0.0, (sum, x) => sum + x * x));
    // TEMPORARY DEBUG: the pre-normalization magnitude - a near-zero raw
    // norm indicates a degenerate/garbled input (e.g. a corrupted crop)
    // even though L2-normalizing below always yields a unit vector that
    // would otherwise hide the problem.
    if (kDebugMode) {
      debugPrint('[FaceEmbedder] rawEmbeddingNorm=${rawNorm.toStringAsFixed(4)}');
    }
    return _l2Normalize(raw);
  }

  static List<double> _l2Normalize(List<double> v) {
    var normSq = 0.0;
    for (final x in v) {
      normSq += x * x;
    }
    final norm = math.sqrt(normSq);
    if (norm == 0) return v;
    return [for (final x in v) x / norm];
  }

  /// Cosine similarity between two embeddings. Both [a] and [b] are assumed
  /// L2-normalized (as returned by [embed]), so this is just their dot
  /// product.
  static double cosineSimilarity(List<double> a, List<double> b) {
    var dot = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
