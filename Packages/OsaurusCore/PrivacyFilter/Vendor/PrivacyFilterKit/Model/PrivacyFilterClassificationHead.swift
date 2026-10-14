import MLX

/// The classifier's projection and host-materialization boundary.
/// Errors must be checked before another operation consumes a failed array;
/// checking only when the scope exits is too late for `asArray`'s dtype cast.
enum PrivacyFilterClassificationHead {
    static func evaluate(
        hiddenStates: MLXArray, weight: MLXArray, bias: MLXArray, expectedShape: [Int], error: ErrorBox
    ) throws -> [Float] {
        // Share the forward scope so a prior graph error cannot be hidden
        // by a fresh nested handler before the projection consumes its input.
        try error.check()
        let transposedWeight = weight.transposed(axes: [1, 0])
        try error.check()
        let projected = matmul(hiddenStates, transposedWeight)
        try error.check()
        let logits = projected + bias
        try error.check()
        let actualShape = logits.shape
        try error.check()
        guard actualShape == expectedShape else {
            throw ModelLoaderError.manifestMismatch(
                "classifier logits shape \(actualShape) does not match expected \(expectedShape)"
            )
        }
        // Preserve the model's existing float32 host output contract.
        let finalLogits = logits.asType(DType.float32)
        try error.check()
        finalLogits.eval()
        try error.check()
        let values = finalLogits.asArray(Float.self)
        try error.check()
        return values
    }
}
