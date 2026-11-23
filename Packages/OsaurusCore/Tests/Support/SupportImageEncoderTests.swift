//
//  SupportImageEncoderTests.swift
//  osaurusTests
//
//  Images attached to Help reports: shrunk to 2048 px, re-encoded so camera
//  and location metadata are gone, kept as PNG only when transparent, and
//  always under the router's 2 MB per image.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OsaurusCore

@Suite("Help image encoder")
struct SupportImageEncoderTests {

    /// A gradient (or noise, which barely compresses), encoded as `type`
    /// with GPS and EXIF metadata attached.
    private func sourceImage(width: Int, height: Int, alpha: Bool, type: UTType, noisy: Bool = false) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
        if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var seed: UInt32 = 2_463_534_242
            for index in 0 ..< context.bytesPerRow * height {
                if noisy {
                    seed ^= seed << 13
                    seed ^= seed >> 17
                    seed ^= seed << 5
                    pixels[index] = UInt8(truncatingIfNeeded: seed)
                } else {
                    pixels[index] = UInt8(truncatingIfNeeded: index % context.bytesPerRow / 16 + index / context.bytesPerRow)
                }
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: 122.0],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private camera note"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func largePhotoIsShrunkReencodedAndStripped() throws {
        let original = try sourceImage(width: 3000, height: 1500, alpha: false, type: .jpeg)
        #expect(try properties(original)[kCGImagePropertyGPSDictionary] != nil)

        let attachment = try SupportImageEncoder.encode(data: original)
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.width == 2048)
        #expect(attachment.height == 1024)
        #expect(attachment.byteSize <= SupportImageEncoder.maxBytes)

        let sent = try properties(attachment.data)
        #expect(sent[kCGImagePropertyGPSDictionary] == nil)
        #expect(!String(decoding: attachment.data, as: UTF8.self).contains("private camera note"))
        #expect(sent[kCGImagePropertyPixelWidth] as? Int == 2048)
    }

    /// An image that will not compress under 2 MB at full size still goes,
    /// at lower quality or smaller.
    @Test func incompressibleImageIsBroughtUnderTheCap() throws {
        let original = try sourceImage(width: 2048, height: 2048, alpha: false, type: .png, noisy: true)
        #expect(original.count > SupportImageEncoder.maxBytes)
        let attachment = try SupportImageEncoder.encode(data: original)
        #expect(attachment.byteSize <= SupportImageEncoder.maxBytes)
        #expect(attachment.width <= 2048)
        #expect(attachment.width >= SupportImageEncoder.minDimension)
    }

    /// Small images keep their size; transparency keeps PNG.
    @Test func transparentScreenshotStaysPNGAtItsOwnSize() throws {
        let original = try sourceImage(width: 300, height: 200, alpha: true, type: .png)
        let attachment = try SupportImageEncoder.encode(data: original)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 300)
        #expect(attachment.height == 200)
        #expect(attachment.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// Any format ImageIO reads goes out as one the router accepts.
    @Test func otherFormatsBecomeJPEG() throws {
        let original = try sourceImage(width: 120, height: 80, alpha: false, type: .tiff)
        let attachment = try SupportImageEncoder.encode(data: original)
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.data.starts(with: [0xFF, 0xD8]))
    }

    @Test func nonImageIsRejected() {
        #expect(throws: SupportImageEncoder.Failure.unreadable) {
            try SupportImageEncoder.encode(data: Data("not an image".utf8))
        }
        #expect(throws: SupportImageEncoder.Failure.unreadable) {
            try SupportImageEncoder.encode(fileURL: URL(fileURLWithPath: "/nonexistent/image.png"))
        }
    }

    /// The upload is the encoded bytes, base64, with their type.
    @Test func uploadCarriesTheEncodedBytes() throws {
        let attachment = try SupportImageEncoder.encode(
            data: try sourceImage(width: 64, height: 64, alpha: false, type: .png))
        #expect(attachment.upload.mimeType == attachment.mimeType)
        #expect(Data(base64Encoded: attachment.upload.dataBase64) == attachment.data)
    }
}
