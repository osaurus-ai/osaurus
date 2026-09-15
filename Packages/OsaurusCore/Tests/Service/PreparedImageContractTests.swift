import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PreparedImageContractTests {
    @Test func refusesTextOnlyProcessorOutputForAttachedImages() {
        let textOnly = LMInput(tokens: MLXArray([Int32(1), 2]))
        #expect(throws: NSError.self) {
            try MLXBatchAdapter.validatePreparedImages(requestedImageCount: 1, input: textOnly)
        }
    }

    @Test func refusesEmptyPixelPayload() {
        let emptyImage = LMInput(
            text: .init(tokens: MLXArray([Int32(1), 2])),
            image: .init(pixels: MLXArray([Float]())))
        #expect(throws: NSError.self) {
            try MLXBatchAdapter.validatePreparedImages(requestedImageCount: 2, input: emptyImage)
        }
    }

    @Test func acceptsPackedImagesWithoutAssumingAPixelLayout() throws {
        let packedImages = LMInput(
            text: .init(tokens: MLXArray([Int32(1), 2])),
            image: .init(pixels: MLXArray([Float(1), 0, 0, 0, 0, 1])))
        try MLXBatchAdapter.validatePreparedImages(requestedImageCount: 2, input: packedImages)
    }

    @Test func leavesTextOnlyRequestsUnchanged() throws {
        try MLXBatchAdapter.validatePreparedImages(
            requestedImageCount: 0, input: LMInput(tokens: MLXArray([Int32(1), 2])))
    }
}
