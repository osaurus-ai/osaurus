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

/// A processing failure is different from successfully recognizing no text.
public enum FrameScrubError: Error, LocalizedError, Sendable, Equatable {
    case imageDecodeFailed
    case recognitionFailed(domain: String, code: Int)
    case recognitionResultsUnavailable
    case paintingFailed
    case imageEncodeFailed

    public var errorDescription: String? {
        switch self {
        case .imageDecodeFailed: return "The screenshot could not be decoded."
        case .recognitionFailed: return "Text recognition failed, so the screenshot was not shared."
        case .recognitionResultsUnavailable:
            return "Text recognition returned no result, so the screenshot was not shared."
        case .paintingFailed: return "Screenshot redaction failed, so the screenshot was not shared."
        case .imageEncodeFailed: return "The redacted screenshot could not be encoded."
        }
    }
}

/// The image-processing boundary used by the scrubber. Calls are synchronous,
/// so non-Sendable Vision observations stay on the calling executor.
protocol FrameImageProcessing: Sendable {
    func recognizeText(in image: CGImage) throws -> [VNRecognizedTextObservation]
    func paintMasks(over image: CGImage, normalizedRegions: [CGRect]) throws -> CGImage
}

struct NativeFrameImageProcessing: FrameImageProcessing {
    func recognizeText(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observations = request.results else {
            throw FrameScrubError.recognitionResultsUnavailable
        }
        return observations
    }

    func paintMasks(over image: CGImage, normalizedRegions: [CGRect]) throws -> CGImage {
        guard let masked = FrameScrubber.paintMasks(over: image, normalizedRegions: normalizedRegions) else {
            throw FrameScrubError.paintingFailed
        }
        return masked
    }
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

    /// Upper bound on how many OCR'd text regions get an on-device model pass
    /// in `.pii` mode. The model forward pass runs once per region, so this
    /// caps the latency of the (opt-in, non-default) precise-PII scrub on a
    /// text-dense screen. `.allText` mode masks everything and never needs it.
    static let maxModelObservations = 200

    /// Scrub a contract `CUImage`. Processing failures throw; a successful
    /// scan with no detected PII still returns a (visually identical) frame.
    ///
    /// - `honorUserRules`: build the regex layer from the user's configured
    ///   Privacy Filter ruleset (custom rules / presets / per-category toggles)
    ///   instead of all built-ins, so a screenshot scrub matches what the text
    ///   filter would mask. `false` keeps the all-built-ins behaviour callers
    ///   (and tests) relied on.
    /// - `useModelDetection`: in `.pii` mode, also run the on-device NER
    ///   classifier so `person` / `address` / `date` / `secret` spans — which
    ///   have no regex — are masked, not just the regex-detectable categories.
    public static func scrub(
        _ image: CUImage,
        mode: ScrubMode = .pii,
        honorUserRules: Bool = false,
        useModelDetection: Bool = false
    ) async throws -> ScrubbedFrame {
        try await scrub(
            image,
            mode: mode,
            honorUserRules: honorUserRules,
            useModelDetection: useModelDetection,
            processing: NativeFrameImageProcessing()
        )
    }

    static func scrub(
        _ image: CUImage,
        mode: ScrubMode,
        honorUserRules: Bool,
        useModelDetection: Bool,
        processing: any FrameImageProcessing
    ) async throws -> ScrubbedFrame {
        guard let cg = decode(image) else { throw FrameScrubError.imageDecodeFailed }
        let ruleset = effectiveRuleset(honorUserRules: honorUserRules)
        let (masked, report) = try await scrub(
            cgImage: cg,
            mode: mode,
            ruleset: ruleset,
            useModelDetection: useModelDetection,
            processing: processing
        )
        guard let encoded = encode(masked, width: image.width, height: image.height) else {
            throw FrameScrubError.imageEncodeFailed
        }
        return ScrubbedFrame(image: encoded, report: report)
    }

    /// Core scrub over a `CGImage` (default safety net —
    /// built-ins plus the fresh-install presets — regex only, no
    /// model). Kept for callers/tests that hold pixels and want the
    /// deterministic, engine-free behaviour.
    public static func scrub(
        cgImage: CGImage,
        mode: ScrubMode = .pii
    ) async throws -> (CGImage, ScrubReport) {
        try await scrub(
            cgImage: cgImage,
            mode: mode,
            ruleset: .defaultSafetyNet(),
            useModelDetection: false
        )
    }

    /// Core scrub over a `CGImage` with an explicit regex ruleset and optional
    /// on-device model pass. Returns the redacted image + a report.
    static func scrub(
        cgImage: CGImage,
        mode: ScrubMode,
        ruleset: RegexEntityDetector.EffectiveRuleSet,
        useModelDetection: Bool,
        processing: any FrameImageProcessing = NativeFrameImageProcessing()
    ) async throws -> (CGImage, ScrubReport) {
        let scan = try recognizeAndDetect(in: cgImage, mode: mode, ruleset: ruleset, processing: processing)
        var regions = scan.regions
        var categories = scan.categories
        // The regex pass (inside `recognizeAndDetect`) masks the precise spans it
        // can. The model owns `person`/`address`/`date`/`secret`, which have no
        // regex — run it per OCR region and mask the whole region on a hit
        // (recall over precision, the same philosophy the regex line-fallback
        // uses). `.allText` already masks every region, so the model adds nothing.
        if mode == .pii, useModelDetection, !scan.observations.isEmpty {
            let candidates = scan.observations.prefix(maxModelObservations)
            for obs in candidates where obs.text.count >= 2 {
                let spans = await PrivacyFilterEngine.shared.modelSpans(in: obs.text)
                guard !spans.isEmpty else { continue }
                regions.append(obs.box)
                for span in spans { categories[categoryToken(span.category), default: 0] += 1 }
            }
        }
        let masked: CGImage
        do {
            masked = try processing.paintMasks(over: cgImage, normalizedRegions: regions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FrameScrubError.paintingFailed
        }
        let report = ScrubReport(
            textRegions: scan.textRegions,
            maskedRegions: regions.count,
            categories: categories
        )
        return (masked, report)
    }

    /// The regex ruleset to run over OCR'd text: the user's configured set when
    /// `honorUserRules`, else the default safety net (built-ins + the
    /// fresh-install presets, so national IDs such as US SSN stay covered).
    private static func effectiveRuleset(
        honorUserRules: Bool
    ) -> RegexEntityDetector.EffectiveRuleSet {
        honorUserRules ? .build(from: PrivacyFilterStore.snapshot()) : .defaultSafetyNet()
    }

    // MARK: - Vision OCR

    /// Everything that touches the non-`Sendable` Vision objects stays local to
    /// `recognizeAndDetect`; only the distilled, `Sendable` geometry leaves it
    /// (Swift 6 strict-concurrency safe).
    private struct OCRScan: Sendable {
        /// Regions to mask, in normalized (0…1, bottom-left) coordinates.
        let regions: [CGRect]
        let categories: [String: Int]
        let textRegions: Int
        /// One per recognized line: its text + normalized bounding box. Used by
        /// the `.pii` model pass, which runs the NER classifier per region and
        /// masks the whole region on a hit. Empty in `.allText` (every region
        /// is already masked, so the model pass is skipped).
        let observations: [OCRObservation]
    }

    /// A single recognized text region carried out of the Vision handler as
    /// `Sendable` geometry, so an async (`@MainActor`) model pass can run after
    /// the non-`Sendable` Vision objects are gone.
    private struct OCRObservation: Sendable {
        let text: String
        /// Normalized (0…1, bottom-left) bounding box.
        let box: CGRect
    }

    private static func recognizeAndDetect(
        in image: CGImage,
        mode: ScrubMode,
        ruleset: RegexEntityDetector.EffectiveRuleSet,
        processing: any FrameImageProcessing
    ) throws -> OCRScan {
        let observations: [VNRecognizedTextObservation]
        do {
            observations = try processing.recognizeText(in: image)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FrameScrubError {
            throw error
        } catch {
            let error = error as NSError
            throw FrameScrubError.recognitionFailed(domain: error.domain, code: error.code)
        }

        var regions: [CGRect] = []
        var categories: [String: Int] = [:]
        var scanned: [OCRObservation] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            switch mode {
            case .allText:
                regions.append(observation.boundingBox)
            case .pii:
                let text = candidate.string
                // The detector's ranges index `candidate.string` directly, so
                // they pass straight to Vision's `boundingBox(for:)`.
                for match in RegexEntityDetector.detect(in: text, ruleset: ruleset) {
                    categories[categoryToken(match.category), default: 0] += 1
                    if let rect = (try? candidate.boundingBox(for: match.range)) ?? nil {
                        regions.append(rect.boundingBox)
                    } else {
                        // Fall back to masking the whole line when sub-range geometry
                        // isn't available — recall over precision, like PrivacyFilter.
                        regions.append(observation.boundingBox)
                    }
                }
                // Carry the region out for the optional model pass.
                scanned.append(OCRObservation(text: text, box: observation.boundingBox))
            }
        }
        return OCRScan(
            regions: regions,
            categories: categories,
            textRegions: observations.count,
            observations: scanned
        )
    }

    // MARK: - Masking

    /// Paint opaque rectangles over the given normalized (0…1, bottom-left)
    /// regions. CGContext is bottom-left origin too, so Vision boxes map
    /// directly with no y-flip.
    fileprivate static func paintMasks(over image: CGImage, normalizedRegions: [CGRect]) -> CGImage? {
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
