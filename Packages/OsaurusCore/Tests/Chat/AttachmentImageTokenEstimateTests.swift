//
//  AttachmentImageTokenEstimateTests.swift
//  osaurus
//
//  Regression coverage for image context-budget estimation. Vision tokens
//  scale with image RESOLUTION, not file size; a prior byte-based estimate
//  made multi-MB photos read as hundreds of thousands of tokens and falsely
//  disabled Send (a small screenshot slipped under the gate, a large JPEG of
//  the same picture did not).
//

import Foundation
import Testing

#if canImport(CoreGraphics)
    import CoreGraphics
#endif
#if canImport(ImageIO)
    import ImageIO
    import UniformTypeIdentifiers
#endif

@testable import OsaurusCore

@Suite struct AttachmentImageTokenEstimateTests {

    @Test func tinyImageFloorsAtOneMergedTile() {
        #expect(Attachment.estimatedImageTokens(pixelWidth: 16, pixelHeight: 16) == 256)
    }

    @Test func estimateScalesWithResolutionThenSaturates() {
        let small = Attachment.estimatedImageTokens(pixelWidth: 224, pixelHeight: 224)
        let medium = Attachment.estimatedImageTokens(pixelWidth: 768, pixelHeight: 768)
        #expect(small >= 256)
        #expect(medium > small)
        // A huge image is downscaled to the processor's long-side budget before
        // patchifying, so token cost saturates (driven by the resize, not raw
        // resolution) and stays bounded — it does NOT grow with pixel count.
        let huge = Attachment.estimatedImageTokens(pixelWidth: 8000, pixelHeight: 6000)
        #expect(huge <= 4096)
        // Same 4:3 image gives the same estimate whether passed at 8000×6000 or
        // already at the 1536-px-long-side it resizes to.
        #expect(huge == Attachment.estimatedImageTokens(pixelWidth: 1536, pixelHeight: 1152))
        // And a larger image never costs more than a smaller one past the budget.
        #expect(huge >= medium)
    }

    @Test func invalidDimensionsFallBackToDefault() {
        #expect(
            Attachment.estimatedImageTokens(pixelWidth: 0, pixelHeight: 0)
                == Attachment.defaultImageTokenEstimate
        )
    }

    @Test func undecodableDataFallsBackToDefault() {
        let junk = Data(repeating: 0xAB, count: 8192)
        #expect(
            Attachment.estimatedImageTokens(forEncodedImage: junk)
                == Attachment.defaultImageTokenEstimate
        )
    }

    // The core regression: a real encoded image's estimate is bounded by its
    // resolution and capped — never proportional to byte length.
    @Test func encodedImageEstimateIsBoundedNotByteProportional() throws {
        #if canImport(CoreGraphics) && canImport(ImageIO)
            let data = try Self.makePNG(width: 1280, height: 960)
            let tokens = Attachment.image(data).estimatedTokens
            #expect(tokens >= 256)
            #expect(tokens <= 4096)
            // Sanity: the OLD byte-based formula (bytes * 4 / 3 / 4) would be a
            // different, byte-driven number. The new estimate must match the
            // dimension math instead.
            #expect(tokens == Attachment.estimatedImageTokens(pixelWidth: 1280, pixelHeight: 960))
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
        private enum TestError: Error { case failed }

        private static func makePNG(width: Int, height: Int) throws -> Data {
            let space = CGColorSpaceCreateDeviceRGB()
            guard
                let ctx = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { throw TestError.failed }
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = ctx.makeImage() else { throw TestError.failed }
            let out = NSMutableData()
            guard
                let dest = CGImageDestinationCreateWithData(
                    out,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            else { throw TestError.failed }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw TestError.failed }
            return out as Data
        }
    #endif
}
