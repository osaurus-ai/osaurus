//
//  InFlightRunMarker.swift
//  osaurus
//
//  What local model work was in flight when the app last ended. A cold
//  load, a chat generation or a helper handoff writes an entry when it
//  starts and removes it when it ends. When `TerminationForensics` finds the
//  previous instance died without an intentional exit and an entry remains,
//  that chat gets one notice saying what was running, most likely out of
//  memory, instead of silently missing its reply.
//

import Foundation

final class InFlightRunMarker: @unchecked Sendable {
    enum Phase: String, Codable, Sendable {
        case load, generation, handoff
    }

    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let phase: Phase
        let model: String
        let sessionId: String?
        /// `ModelMemoryTelemetryBuckets.bytes` of the load's working set.
        let footprintBucket: String?
        let pressure: String
        let startedAt: Date
    }

    static let shared = InFlightRunMarker(fileURL: OsaurusPaths.root().appendingPathComponent(fileName))
    static let fileName = "in-flight-run.json"

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var interrupted: Entry?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    func begin(
        _ phase: Phase, model: String, sessionId: String?, footprintBytes: UInt64? = nil,
        pressure: SubagentMemoryPressure = .sampled(), now: Date = Date()
    ) -> UUID {
        let entry = Entry(
            id: UUID(), phase: phase, model: model, sessionId: sessionId,
            footprintBucket: footprintBytes.map(ModelMemoryTelemetryBuckets.bytes),
            pressure: pressure.rawValue, startedAt: now)
        lock.lock()
        entries[entry.id] = entry
        let snapshot = Array(entries.values)
        lock.unlock()
        write(snapshot)
        return entry.id
    }

    func end(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        let removed = entries.removeValue(forKey: id) != nil
        let snapshot = Array(entries.values)
        lock.unlock()
        if removed { write(snapshot) }
    }

    /// Read and clear what the previous instance left. Only an unattributed
    /// exit keeps an entry for a notice: a clean quit or a first launch never
    /// blames a model. Returns the entry kept.
    @discardableResult
    func evaluateAtLaunch(verdict: TerminationForensics.LaunchVerdict) -> Entry? {
        let previous = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder.marker.decode([Entry].self, from: $0) } ?? []
        try? FileManager.default.removeItem(at: fileURL)
        let kept = verdict == .unattributed ? Self.mostSpecific(previous) : nil
        lock.lock()
        interrupted = kept
        lock.unlock()
        return kept
    }

    /// The interrupted entry for `sessionId`, once.
    func claimInterrupted(sessionId: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = interrupted, entry.sessionId == sessionId else { return nil }
        interrupted = nil
        return entry
    }

    var pendingInterrupted: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    /// The latest work that started, carrying a chat session when any entry
    /// does: a load inside a chat run names the chat it belonged to.
    static func mostSpecific(_ entries: [Entry]) -> Entry? {
        guard let latest = entries.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        guard latest.sessionId == nil,
            let session = entries.filter({ $0.sessionId != nil }).max(by: { $0.startedAt < $1.startedAt })?.sessionId
        else { return latest }
        return Entry(
            id: latest.id, phase: latest.phase, model: latest.model, sessionId: session,
            footprintBucket: latest.footprintBucket, pressure: latest.pressure, startedAt: latest.startedAt)
    }

    private func write(_ snapshot: [Entry]) {
        if snapshot.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder.marker.encode(snapshot.sorted { $0.startedAt < $1.startedAt }) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension ChatRunOutcome {
    /// The notice for work the app was doing when it ended unexpectedly.
    init(interrupted entry: InFlightRunMarker.Entry) {
        let phase: String
        switch entry.phase {
        case .load: phase = L("Loading the model")
        case .generation: phase = L("Writing a reply")
        case .handoff: phase = L("Running a helper")
        }
        self.init(
            kind: .interruptedByExit,
            facts: [Fact(label: L("Model"), value: entry.model), Fact(label: L("In progress"), value: phase)])
        memoryPressure = entry.pressure
    }
}

private extension JSONEncoder {
    static let marker: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let marker: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
