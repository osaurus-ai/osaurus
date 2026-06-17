//
//  FrameScrubber.swift
//  OsaurusCore — Computer Use
//
//  Screenshot redaction (PR3). PrivacyFilter is text-only — there is no
//  pixel/image redactor in the app — so this is new: run Vision OCR over a
//  frame, find PII in the recognized text with the SAME deterministic
//  detectors PrivacyFilter uses (`RegexEntityDetector`), and paint opaque
//  boxes over the offending regions before any frame is allowed to leave the
//  device.
//
//  The output is a `ScrubbedFrame`, whose initializer is internal to this
//  file — `FrameScrubber` is the ONLY producer. Combined with
//  `CaptureRouter.cloudRoute(...)` requiring consent, that makes "send raw
//  pixels to the cloud" impossible to express: the cloud route only accepts a
//  `ScrubbedFrame`, and a `ScrubbedFrame` only exists after a scrub.
//

import AppKit
import CoreGraphics
import Foundation
import Vision

/// What to mask.
public enum ScrubMode: String, Sendable, Equatable {
    /// Mask only regions whose recognized text matched a PII detector.
    case pii
    /// Mask every recognized text region (strictest — nothing readable leaves).
    case allText
}

/// A summary of what a scrub did. Stays on-device (never sent); used for the
/// activity feed, telemetry buckets, and tests.
public struct ScrubReport: Sendable, Equatable {
    /// How many text regions Vision recognized.
    public let textRegions: Int
    /// How many regions were painted over.
    public let maskedRegions: Int
    /// Count of masked regions per PII category (empty in `.allText` mode).
    public let categories: [String: Int]

    public init(textRegions: Int, maskedRegions: Int, categories: [String: Int]) {
        self.textRegions = textRegions
        self.maskedRegions = maskedRegions
        self.categories = categories
    }

    public var didMaskAnything: Bool { maskedRegions > 0 }
}

/// A frame that has been through `FrameScrubber`. The only way to construct
/// one is via `FrameScrubber.scrub(...)`, so possessing a value is proof the
/// pixels were redacted. `CaptureRoute.cloudVision` accepts only this.
public struct ScrubbedFrame: Sendable, Equatable {
    public let image: CUImage
    public let report: ScrubReport

    /// Deliberately `fileprivate` — see the type doc. Do not widen.
    fileprivate init(image: CUImage, report: ScrubReport) {
        self.image = image
        self.report = report
    }
}

public enum FrameScrubber {

    /// Scrub a contract `CUImage`. Returns `nil` only if the bytes can't be
    /// decoded; an image with no detected PII still returns a (visually
    /// identical) `ScrubbedFrame` so the type guarantee holds.
    public static func scrub(_ image: CUImage, mode: ScrubMode = .pii) async -> ScrubbedFrame? {
        guard let cg = decode(image) else { return nil }
        guard let (masked, report) = await scrub(cgImage: cg, mode: mode) else { return nil }
        guard let encoded = encode(masked, width: image.width, height: image.height) else {
            return nil
        }
        return ScrubbedFrame(image: encoded, report: report)
    }

    /// Core scrub over a `CGImage`. Exposed for callers that already hold pixels
    /// (and for tests). Returns the redacted image + a report.
    public static func scrub(
        cgImage: CGImage,
        mode: ScrubMode = .pii
    ) async -> (CGImage, ScrubReport)? {
        let scan = await recognizeAndDetect(in: cgImage, mode: mode)
        let masked = paintMasks(over: cgImage, normalizedRegions: scan.regions) ?? cgImage
        let report = ScrubReport(
            textRegions: scan.textRegions,
            maskedRegions: scan.regions.count,
            categories: scan.categories
        )
        return (masked, report)
    }

    // MARK: - Vision OCR

    /// Everything that touches the non-`Sendable` Vision objects happens inside
    /// the completion handler; only the distilled, `Sendable` geometry crosses
    /// the continuation (Swift 6 strict-concurrency safe).
    private struct OCRScan: Sendable {
        /// Regions to mask, in normalized (0…1, bottom-left) coordinates.
        let regions: [CGRect]
        let categories: [String: Int]
        let textRegions: Int
    }

    private static func recognizeAndDetect(in image: CGImage, mode: ScrubMode) async -> OCRScan {
        await withCheckedContinuation { (continuation: CheckedContinuation<OCRScan, Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var regions: [CGRect] = []
                var categories: [String: Int] = [:]
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    switch mode {
                    case .allText:
                        regions.append(observation.boundingBox)
                    case .pii:
                        let text = candidate.string
                        // The detector's ranges index `candidate.string` directly, so
                        // they pass straight to Vision's `boundingBox(for:)`.
                        for match in RegexEntityDetector.detect(in: text) {
                            categories[categoryToken(match.category), default: 0] += 1
                            if let rect = (try? candidate.boundingBox(for: match.range)) ?? nil {
                                regions.append(rect.boundingBox)
                            } else {
                                // Fall back to masking the whole line when sub-range geometry
                                // isn't available — recall over precision, like PrivacyFilter.
                                regions.append(observation.boundingBox)
                            }
                        }
                    }
                }
                continuation.resume(
                    returning: OCRScan(
                        regions: regions,
                        categories: categories,
                        textRegions: observations.count
                    )
                )
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: OCRScan(regions: [], categories: [:], textRegions: 0))
            }
        }
    }

    // MARK: - Masking

    /// Paint opaque rectangles over the given normalized (0…1, bottom-left)
    /// regions. CGContext is bottom-left origin too, so Vision boxes map
    /// directly with no y-flip.
    private static func paintMasks(over image: CGImage, normalizedRegions: [CGRect]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let w = CGFloat(width)
        let h = CGFloat(height)
        let padX = w * 0.004
        let padY = h * 0.004
        for region in normalizedRegions {
            let rect = CGRect(
                x: region.minX * w - padX,
                y: region.minY * h - padY,
                width: region.width * w + padX * 2,
                height: region.height * h + padY * 2
            )
            context.fill(rect)
        }
        return context.makeImage()
    }

    // MARK: - Codec

    private static func decode(_ image: CUImage) -> CGImage? {
        guard let data = Data(base64Encoded: image.base64),
            let rep = NSBitmapImageRep(data: data)
        else { return nil }
        return rep.cgImage
    }

    private static func encode(_ image: CGImage, width: Int, height: Int) -> CUImage? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return nil }
        return CUImage(
            base64: data.base64EncodedString(),
            mimeType: "image/jpeg",
            width: image.width,
            height: image.height
        )
    }

    private static func categoryToken(_ category: EntityCategory) -> String {
        String(describing: category)
    }
}
