import MLX
import Testing
@testable import OsaurusCore

struct PrivacyFilterClassificationHeadTests {
    private func evaluate(
        hiddenStates: MLXArray, weight: MLXArray, bias: MLXArray
    ) throws -> [Float] {
        try withError { error in
            try PrivacyFilterClassificationHead.evaluate(
                hiddenStates: hiddenStates, weight: weight, bias: bias,
                expectedShape: [hiddenStates.shape[0], 2], error: error
            )
        }
    }

    @Test func pendingGraphErrorIsNotReplacedByHeadFailure() {
        Device.withDefaultDevice(.cpu) {
            do {
                _ = try withError { error in
                    let invalid = matmul(MLXArray([Float(1), 2], [1, 2]), MLXArray([Float(1), 2, 3], [3, 1]))
                    return try PrivacyFilterClassificationHead.evaluate(
                        hiddenStates: invalid,
                        weight: MLXArray([Float(1), 2, 3]),
                        bias: MLXArray([Float(1)]), expectedShape: [1, 2], error: error
                    )
                }
                Issue.record("Expected prior graph error")
            } catch MLXError.caught(let message) {
                #expect(message.contains("[matmul]"))
                #expect(message.contains("(1,2)"))
                #expect(message.contains("(3,1)"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func validProjectionPreservesValues() throws {
        try Device.withDefaultDevice(.cpu) {
            let values = try evaluate(
                hiddenStates: MLXArray([Float(1), 2, 3, 4, 5, 6], [2, 3]),
                weight: MLXArray([Float(1), 1, 1, 2, 2, 2], [2, 3]),
                bias: MLXArray([Float(1), -1])
            )
            #expect(values == [7, 11, 16, 29])
        }
    }

    @Test func projectionFailurePreservesOriginalMatmulError() {
        Device.withDefaultDevice(.cpu) {
            do {
                _ = try evaluate(
                    hiddenStates: MLXArray([Float(1), 2, 3, 4, 5, 6], [2, 3]),
                    weight: MLXArray([Float](repeating: 1, count: 8), [2, 4]),
                    bias: MLXArray([Float(1), -1])
                )
                Issue.record("Expected incompatible classifier projection to throw")
            } catch MLXError.caught(let message) {
                #expect(message.contains("[matmul]"))
                #expect(message.contains("(2,3)"))
                #expect(message.contains("(4,2)"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func invalidWeightRankThrowsBeforeProjection() {
        Device.withDefaultDevice(.cpu) {
            #expect(throws: MLXError.self) {
                try evaluate(
                    hiddenStates: MLXArray([Float(1), 2, 3], [1, 3]),
                    weight: MLXArray([Float(1), 2, 3]),
                    bias: MLXArray([Float(1), -1])
                )
            }
        }
    }

    @Test func broadcastLeadingBiasDimensionThrowsShapeError() {
        Device.withDefaultDevice(.cpu) {
            #expect(throws: ModelLoaderError.self) {
                try evaluate(
                    hiddenStates: MLXArray([Float(1), 2, 3, 4, 5, 6], [2, 3]),
                    weight: MLXArray([Float(1), 1, 1, 2, 2, 2], [2, 3]),
                    bias: MLXArray([Float(1), -1, 2, -2], [2, 1, 2])
                )
            }
        }
    }

    @Test func wrongLabelCountThrowsShapeError() {
        Device.withDefaultDevice(.cpu) {
            #expect(throws: ModelLoaderError.self) {
                try evaluate(
                    hiddenStates: MLXArray([Float(1), 2, 3], [1, 3]),
                    weight: MLXArray([Float](repeating: 1, count: 9), [3, 3]),
                    bias: MLXArray([Float(1), -1, 2])
                )
            }
        }
    }

    @Test func incompatibleBiasThrowsBeforeCastAndRead() {
        Device.withDefaultDevice(.cpu) {
            #expect(throws: MLXError.self) {
                try evaluate(
                    hiddenStates: MLXArray([Float(1), 2, 3], [1, 3]),
                    weight: MLXArray([Float(1), 1, 1, 2, 2, 2], [2, 3]),
                    bias: MLXArray([Float(1), 2, 3])
                )
            }
        }
    }
}
