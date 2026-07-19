//
//  EvalMediaFixtures.swift
//  OsaurusEvalsKit
//
//  Deterministic, generated-at-runtime media payloads for the multimodal
//  HTTP contract cases. Generated (not committed) so the fixtures stay
//  byte-stable per run without binary blobs in the repo, and so a case
//  can request the INVERTED twin of an image — the pair that proves the
//  media-salted cache never serves image A's answer for image B.
//
//  Shapes intentionally mirror the Bonsai bundle's own runtime
//  verification fixtures ("red background with centered blue square",
//  "red frames followed by blue frames") so an Osaurus-level pass/fail
//  is directly comparable to the bundle's recorded upstream proof.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum EvalMediaFixtures {

    struct RGB: Sendable {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat

        static let red = RGB(r: 1, g: 0, b: 0)
        static let blue = RGB(r: 0, g: 0, b: 1)
    }

    /// PNG of `background` with a centered square of `square`, as a
    /// `data:image/png;base64,…` URL ready for an `image_url` content part.
    /// nil only when CoreGraphics fails (treat as an infrastructure error).
    static func pngDataURL(
        background: RGB,
        square: RGB,
        size: Int = 96
    ) -> String? {
        guard let data = pngData(background: background, square: square, size: size) else {
            return nil
        }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    static func pngData(background: RGB, square: RGB, size: Int) -> Data? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.setFillColor(
            CGColor(colorSpace: colorSpace, components: [background.r, background.g, background.b, 1])!
        )
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let inset = CGFloat(size) / 3
        context.setFillColor(
            CGColor(colorSpace: colorSpace, components: [square.r, square.g, square.b, 1])!
        )
        context.fill(
            CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        )

        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Tiny H.264 MP4 — `framesPerColor` solid frames of `first`, then
    /// `framesPerColor` of `second` — as a `data:video/mp4;base64,…` URL
    /// for a `video_url` content part. The two-color temporal order is the
    /// thing a video-capable model must be able to answer about. nil when
    /// AVFoundation fails (treat as an infrastructure error).
    static func mp4DataURL(
        first: RGB,
        second: RGB,
        framesPerColor: Int = 4,
        size: Int = 64,
        fps: Int32 = 2
    ) async -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-evals-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let writer = try? AVAssetWriter(outputURL: tempURL, fileType: .mp4) else {
            return nil
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size,
                AVVideoHeightKey: size,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        func appendFrame(color: RGB, index: Int) -> Bool {
            guard let pool = adaptor.pixelBufferPool else { return false }
            var bufferOut: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
                let buffer = bufferOut
            else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let bgra: [UInt8] = [
                    UInt8(color.b * 255), UInt8(color.g * 255), UInt8(color.r * 255), 255,
                ]
                for row in 0 ..< size {
                    let rowPointer = base.advanced(by: row * bytesPerRow)
                        .assumingMemoryBound(to: UInt8.self)
                    for col in 0 ..< size {
                        rowPointer[col * 4] = bgra[0]
                        rowPointer[col * 4 + 1] = bgra[1]
                        rowPointer[col * 4 + 2] = bgra[2]
                        rowPointer[col * 4 + 3] = bgra[3]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            return adaptor.append(buffer, withPresentationTime: time)
        }

        var frameIndex = 0
        for color in [first, second] {
            for _ in 0 ..< framesPerColor {
                // Wait for the writer to accept input (tiny frames — the
                // wait is microseconds; the loop guards a slow first frame).
                while !input.isReadyForMoreMediaData {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                guard appendFrame(color: color, index: frameIndex) else { return nil }
                frameIndex += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed,
            let data = try? Data(contentsOf: tempURL)
        else { return nil }
        return "data:video/mp4;base64," + data.base64EncodedString()
    }
}
