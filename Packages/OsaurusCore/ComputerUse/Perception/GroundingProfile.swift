//
//  GroundingProfile.swift
//  OsaurusCore — Computer Use
//
//  How a model points at a screenshot: the coordinate frame its `target.point`
//  and zoom `region` are written in. It pairs with `VisionContext.frameBudget`
//  (the image size and patch multiple frames are fitted to), and both are
//  resolved per installed bundle. The frame comes from what the bundle states
//  — its own declared metadata first, then a convention its config files
//  state — and otherwise from a one-time calibration against synthetic
//  screens with known targets (`GroundingCalibration`). When nothing
//  resolves, the model addresses elements by mark and `describe` only; its
//  coordinates are never guessed.
//

import CryptoKit
import Foundation

public struct GroundingProfile: Sendable, Equatable, Codable {

    /// The space a model's coordinates are written in.
    public enum CoordinateFrame: String, Sendable, Equatable, Codable, CaseIterable {
        /// Pixels of the image the model was shown (origin top-left).
        case pixels
        /// 0–1000 of the image's width and height.
        case normalized1000
        /// 0–1 of the image's width and height.
        case normalizedUnit

        /// Upper bound of a coordinate along an axis `extent` pixels long.
        func scale(forExtent extent: Double) -> Double {
            switch self {
            case .pixels: return extent
            case .normalized1000: return 1000
            case .normalizedUnit: return 1
            }
        }

        /// How the schema, prompt, and image note describe a coordinate.
        var phrase: String {
            switch self {
            case .pixels: return "pixel coordinates"
            case .normalized1000: return "coordinates on a 0–1000 scale of the image's width and height"
            case .normalizedUnit: return "coordinates on a 0–1 scale of the image's width and height"
            }
        }

        /// Short name for activity feeds.
        var label: String {
            switch self {
            case .pixels: return "screenshot pixels"
            case .normalized1000: return "a 0–1000 scale"
            case .normalizedUnit: return "a 0–1 scale"
            }
        }

        /// The spellings a bundle may use to state its convention.
        init?(declared raw: String) {
            switch raw.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "pixels", "pixel", "absolute", "absolute_pixels", "resized_pixels":
                self = .pixels
            case "normalized1000", "normalized_1000", "relative_1000", "0_1000":
                self = .normalized1000
            case "normalizedunit", "normalized_unit", "normalized", "relative", "0_1":
                self = .normalizedUnit
            default:
                return nil
            }
        }
    }

    public enum Source: String, Sendable, Equatable, Codable {
        /// The bundle's own metadata declares the frame.
        case declared
        /// A config file in the bundle states the convention.
        case bundleConfig
        /// Measured by `GroundingCalibration` and cached for this bundle.
        case calibrated
        /// A hosted provider's model; its API takes pixels of the image sent.
        case provider
    }

    public var frame: CoordinateFrame
    public var source: Source

    public init(frame: CoordinateFrame, source: Source) {
        self.frame = frame
        self.source = source
    }

    /// Hosted models point in pixels of the image they were sent.
    public static let providerPixels = GroundingProfile(frame: .pixels, source: .provider)

    /// A point in this frame → pixels of a `width`×`height` image, or nil when
    /// it lies outside the image.
    func pixelPoint(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double)? {
        let sx = frame.scale(forExtent: width)
        let sy = frame.scale(forExtent: height)
        // A normalized scale includes its upper bound; pixels stop one short.
        let inclusive = frame != .pixels
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
            inclusive ? x <= sx : x < sx,
            inclusive ? y <= sy : y < sy
        else { return nil }
        return (min(x * width / sx, width.nextDown), min(y * height / sy, height.nextDown))
    }

    /// Pixels per coordinate unit along each axis of a `width`×`height` image.
    func pixelsPerUnit(width: Double, height: Double) -> (x: Double, y: Double) {
        (width / frame.scale(forExtent: width), height / frame.scale(forExtent: height))
    }
}

/// What the action schema, system prompt, and image notes tell the model
/// about coordinates.
enum PointingSurface: Sendable, Equatable {
    case frame(GroundingProfile.CoordinateFrame)
    /// No profile: `target.point` and `zoom` are off; address by mark or `describe`.
    case marksOnly
    /// Calibration: name no convention, so the model answers in its own.
    case unstated

    init(_ grounding: GroundingProfile?) {
        self = grounding.map { .frame($0.frame) } ?? .marksOnly
    }
}

// MARK: - Resolution

/// Where a local bundle's grounding stands before a run.
public enum GroundingResolution: Sendable, Equatable {
    case resolved(GroundingProfile)
    /// Calibration ran and found no frame the model points in consistently.
    case marksOnly
    /// Nothing states a frame and no calibration is cached for `key`.
    case needsCalibration(GroundingCalibrationKey)
}

/// Identity of one calibration: the bundle, its config files, and the budget
/// the synthetic screens are sized to. Any change calibrates again.
public struct GroundingCalibrationKey: Sendable, Equatable, Hashable, Codable {
    public var modelId: String
    public var fingerprint: String
    public var budget: FrameBudget

    public init(modelId: String, fingerprint: String, budget: FrameBudget) {
        self.modelId = modelId
        self.fingerprint = fingerprint
        self.budget = budget
    }

    var storageKey: String {
        "\(modelId)|\(fingerprint)|\(budget.maxLongEdge)x\(budget.maxPixels)/\(budget.multiple)"
    }
}

enum GroundingProfileResolver {

    /// The bundle's own Osaurus metadata; a frame here is declared.
    static let declaredFile = "jang_config.json"
    /// Upstream configs; a frame stated here counts as the bundle's convention.
    static let statedFiles = ["preprocessor_config.json", "config.json", "generation_config.json"]

    /// Resolve the frame for the local bundle at `directory`, whose frames are
    /// fitted to `budget`, consulting `store` before asking for calibration.
    static func resolve(
        modelId: String,
        directory: URL,
        budget: FrameBudget,
        store: GroundingCalibrationStore = .shared
    ) -> GroundingResolution {
        if let frame = statedFrame(in: readJSON(directory.appendingPathComponent(declaredFile))) {
            return .resolved(GroundingProfile(frame: frame, source: .declared))
        }
        for name in statedFiles {
            if let frame = statedFrame(in: readJSON(directory.appendingPathComponent(name))) {
                return .resolved(GroundingProfile(frame: frame, source: .bundleConfig))
            }
        }
        let key = GroundingCalibrationKey(
            modelId: modelId,
            fingerprint: fingerprint(directory: directory),
            budget: budget
        )
        switch store.outcome(for: key) {
        case .frame(let frame)?:
            return .resolved(GroundingProfile(frame: frame, source: .calibrated))
        case .marksOnly?:
            return .marksOnly
        case nil:
            return .needsCalibration(key)
        }
    }

    /// A grounding statement in one config object:
    /// `{"grounding": {"coordinate_frame": "…"}}`,
    /// `{"capabilities": {"grounding": {"coordinate_frame": "…"}}}`, or a
    /// top-level `"grounding_coordinate_frame"` string.
    static func statedFrame(in json: [String: Any]?) -> GroundingProfile.CoordinateFrame? {
        guard let json else { return nil }
        let candidates: [Any?] = [
            (json["grounding"] as? [String: Any])?["coordinate_frame"],
            ((json["capabilities"] as? [String: Any])?["grounding"] as? [String: Any])?["coordinate_frame"],
            json["grounding_coordinate_frame"],
        ]
        for case let raw as String in candidates {
            if let frame = GroundingProfile.CoordinateFrame(declared: raw) { return frame }
        }
        return nil
    }

    /// Hash of the files that decide how the model sees and answers, so a
    /// re-downloaded or re-quantized bundle calibrates again.
    static func fingerprint(directory: URL) -> String {
        var hasher = SHA256()
        for name in ["config.json", "preprocessor_config.json", "chat_template.jinja", "tokenizer_config.json"] {
            hasher.update(data: Data(name.utf8))
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
