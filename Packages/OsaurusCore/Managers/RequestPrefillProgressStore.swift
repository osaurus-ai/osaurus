import Combine
import Foundation

/// Request-owned progress shared by the runtime mapper and session-scoped native HUD.
/// A request may mutate only its registered entry. Session selection is a read,
/// so switching windows cannot finish or overwrite another request's progress.
@MainActor
final class RequestPrefillProgressStore: ObservableObject {
    static let shared = RequestPrefillProgressStore()
    enum Channel: String, Codable, Sendable { case foreground, suppressed }

    struct Handle: Codable, Hashable, Sendable {
        let requestID: UUID
        let sessionID: String?
        let model: String
        let channel: Channel

        fileprivate init(sessionID: String?, model: String, channel: Channel) {
            requestID = UUID()
            self.sessionID = sessionID
            self.model = model
            self.channel = channel
        }
    }

    /// One producer assigns sequences before duplicating events into direct and
    /// in-band routes. A consumer must never mint a new sequence for a duplicate.
    struct Envelope: Codable, Sendable {
        let handle: Handle
        let sequence: UInt64
        let progress: PrefillProgressState
    }

    struct Snapshot: Equatable, Sendable {
        let handle: Handle
        let startedAt: Date
        var progress: PrefillProgressState
        var lastSequence: UInt64?
    }

    @Published private(set) var entries: [UUID: Snapshot] = [:]
    private var registrationOrder: [UUID] = []

    /// Only this operation creates an entry and always returns a fresh identity.
    /// Nil-session work is addressable by handle but never selected for a chat.
    func begin(sessionID: String?, model: String, channel: Channel = .foreground,
               totalUnits: Int, at date: Date = Date()) -> Handle {
        let handle = Handle(sessionID: sessionID, model: model, channel: channel)
        registrationOrder.append(handle.requestID)
        entries[handle.requestID] = Snapshot(
            handle: handle, startedAt: date,
            progress: PrefillProgressState(stage: .queued, completedUnitCount: 0,
                                          totalUnitCount: max(0, totalUnits), detail: nil),
            lastSequence: nil)
        return handle
    }

    /// Same-request queued total discovery. It preserves the start timestamp and
    /// cannot rewrite runtime counts after progress or completion has arrived.
    @discardableResult
    func updateQueuedTotal(_ total: Int, for handle: Handle) -> Bool {
        guard total >= 0, var entry = entries[handle.requestID], entry.handle == handle,
            entry.progress.stage == .queued, entry.lastSequence == nil
        else { return false }
        entry.progress = PrefillProgressState(stage: .queued, completedUnitCount: 0,
                                              totalUnitCount: total, detail: entry.progress.detail)
        entries[handle.requestID] = entry
        return true
    }

    /// Unknown/finished handles and old/duplicate frames are ignored. Received
    /// envelopes never register work, so delayed native hints cannot resurrect it.
    @discardableResult
    func receive(_ envelope: Envelope) -> Bool {
        guard var entry = entries[envelope.handle.requestID], entry.handle == envelope.handle,
            entry.lastSequence.map({ envelope.sequence > $0 }) ?? true
        else { return false }
        let progress = envelope.progress
        guard progress.completedUnitCount >= 0, progress.totalUnitCount >= 0,
            progress.completedUnitCount <= progress.totalUnitCount
        else { return false }
        if progress.stage == .complete {
            finish(envelope.handle)
        } else {
            entry.progress = progress
            entry.lastSequence = envelope.sequence
            entries[envelope.handle.requestID] = entry
        }
        return true
    }

    /// First output, error, cancellation and stream drain use the same identity.
    /// Idempotent and deliberately unable to clear any other request.
    func finish(_ handle: Handle) {
        guard entries[handle.requestID]?.handle == handle else { return }
        registrationOrder.removeAll { $0 == handle.requestID }
        entries.removeValue(forKey: handle.requestID)
    }

    func snapshot(for handle: Handle) -> Snapshot? {
        guard let entry = entries[handle.requestID], entry.handle == handle else { return nil }
        return entry
    }

    /// Selection policy: newest active foreground generation in this exact chat.
    /// No global/model/agent fallback and no implicit selection of nil-session work.
    func visibleSnapshot(sessionID: String?, from publishedEntries: [UUID: Snapshot]? = nil) -> Snapshot? {
        let entries = publishedEntries ?? self.entries
        guard let sessionID else { return nil }
        for id in registrationOrder.reversed() {
            if let entry = entries[id], entry.handle.sessionID == sessionID,
                entry.handle.channel == .foreground { return entry }
        }
        return nil
    }
}

/// Per-native-stream receiver. Old providers without ownership metadata are
/// scoped once to this stream; first output/termination closes that scope forever.
@MainActor
final class PrefillProgressStreamReceiver {
    private let store: RequestPrefillProgressStore
    private let sessionID: String?
    private var owner: RequestPrefillProgressStore.Handle?
    private var legacySequence: UInt64 = 0
    private var isLegacy = false
    private var closed = false

    init(sessionID: String?, store: RequestPrefillProgressStore? = nil) {
        self.sessionID = sessionID
        self.store = store ?? .shared
    }

    @discardableResult
    func receive(_ progress: PrefillProgressState) -> Bool {
        guard !closed, progress.completedUnitCount >= 0, progress.totalUnitCount >= 0,
            progress.completedUnitCount <= progress.totalUnitCount else { return false }
        let accepted: Bool
        if let handle = progress.requestOwner, let sequence = progress.requestSequence {
            guard handle.sessionID == sessionID, owner == nil || owner == handle else { return false }
            owner = handle
            accepted = store.receive(.init(handle: handle, sequence: sequence, progress: progress))
        } else {
            guard progress.requestOwner == nil, progress.requestSequence == nil else { return false }
            if owner == nil {
                owner = store.begin(sessionID: sessionID, model: "remote-stream", totalUnits: progress.totalUnitCount)
                isLegacy = true
            }
            guard let owner, isLegacy else { return false }
            legacySequence += 1
            accepted = store.receive(.init(handle: owner, sequence: legacySequence, progress: progress))
        }
        if progress.stage == .complete, let owner,
            accepted || store.snapshot(for: owner) == nil { closed = true }
        return accepted
    }

    func finish() {
        closed = true
        if let owner { store.finish(owner) }
    }
}
