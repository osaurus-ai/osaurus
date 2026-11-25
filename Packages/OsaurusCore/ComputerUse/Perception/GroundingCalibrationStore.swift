//
//  GroundingCalibrationStore.swift
//  OsaurusCore — Computer Use
//
//  Per-bundle cache of `GroundingCalibration` outcomes, so a model is measured
//  once per bundle + config + budget rather than on every run.
//

import Foundation

public enum GroundingCalibrationOutcome: Sendable, Equatable, Codable {
    case frame(GroundingProfile.CoordinateFrame)
    /// No candidate frame scored well enough; address by mark only.
    case marksOnly
}

public final class GroundingCalibrationStore: @unchecked Sendable {

    public static let shared = GroundingCalibrationStore(fileURL: nil)

    private struct Entry: Codable {
        var outcome: GroundingCalibrationOutcome
        var hits: [String: Int]
        var trials: Int
        var calibratedAt: Date
    }

    private let explicitURL: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]?

    /// `fileURL` nil → `OsaurusPaths.cache()/computer-use-grounding.json`.
    public init(fileURL: URL?) {
        self.explicitURL = fileURL
    }

    private var fileURL: URL {
        explicitURL ?? OsaurusPaths.cache().appendingPathComponent("computer-use-grounding.json")
    }

    func outcome(for key: GroundingCalibrationKey) -> GroundingCalibrationOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return loaded()[key.storageKey]?.outcome
    }

    func record(_ result: GroundingCalibration.Result, for key: GroundingCalibrationKey) {
        lock.lock()
        defer { lock.unlock() }
        var all = loaded()
        all[key.storageKey] = Entry(
            outcome: result.outcome,
            hits: Dictionary(uniqueKeysWithValues: result.hits.map { ($0.key.rawValue, $0.value) }),
            trials: result.trials,
            calibratedAt: Date()
        )
        entries = all
        let url = fileURL
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read =
            (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([String: Entry].self, from: $0) }
            ?? [:]
        entries = read
        return read
    }
}
