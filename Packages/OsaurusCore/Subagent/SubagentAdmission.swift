//
//  SubagentAdmission.swift
//  OsaurusCore — Subagent framework
//
//  Process-wide admission control for subagent runs. The TaskLocal recursion
//  guard in `SubagentSession` only protects one task tree; a parallel tool
//  batch (or chat + HTTP surfaces racing) can start two subagent runs
//  CONCURRENTLY. Two concurrent local runs are exactly the historical
//  concurrent-GPU crash class (BUG G: MLX async tails racing the next Metal
//  producer), and two concurrent residency handoffs can strand the
//  orchestrator (A unloads chat → B snapshots "nothing resident" → A restores
//  while B loads).
//
//  Rules, by residency class:
//    - `.remote`         — no local GPU involvement; always admitted, any
//                          number run concurrently (parallel remote fan-out).
//    - `.localInPlace`   — drives a local model with no unload (same-model
//                          computer_use, coexistence spawns); admitted unless
//                          an exclusive run holds the GPU.
//    - `.localExclusive` — performs a residency handoff (unload → run →
//                          restore) or otherwise owns the GPU alone; admitted
//                          only when NO other local run is active.
//
//  Blocked runs WAIT (bounded) rather than refuse: a parallel batch of two
//  local spawns serializes here — second run starts when the first releases —
//  which matches what the model expects from issuing two tool calls. The wait
//  is polled so cancellation of the waiting task exits promptly; on timeout
//  the caller returns a typed retryable envelope instead of crashing into a
//  concurrent handoff.
//

import Foundation

/// Residency class of one subagent run, derived by the kind AFTER model
/// resolution (so it reflects the live residency plan, not static config).
public enum SubagentAdmissionClass: String, Sendable {
    /// Remote/router model — no local GPU residency involvement.
    case remote
    /// Local model driven in place (no unload of resident chat models).
    case localInPlace = "local_in_place"
    /// Local run that unloads/loads models (residency handoff) and must own
    /// the GPU exclusively.
    case localExclusive = "local_exclusive"
}

/// Process-wide gate that serializes local subagent runs while letting remote
/// runs fan out. An actor: admission checks and counter updates are atomic;
/// waiting is a poll loop so the actor is never held across a suspension.
public actor SubagentAdmission {
    public static let shared = SubagentAdmission()

    /// How long a blocked run waits for the GPU before returning the typed
    /// busy envelope. Generous: a local handoff (unload + run + restore) on
    /// big bundles legitimately takes minutes.
    public static let defaultWaitTimeoutSeconds: TimeInterval = 300

    private var exclusiveActive = 0
    /// Active in-place runs keyed by canonical local model identity. Runs for
    /// the SAME model may overlap (the shared BatchEngine/load-coalescing
    /// path); a different local model waits so two cold local loads can never
    /// race from an initially empty residency snapshot.
    private var inPlaceByModel: [String: Int] = [:]
    private var remoteActive = 0

    /// Test seam: poll interval for blocked waiters.
    private let pollNanoseconds: UInt64

    public init(pollNanoseconds: UInt64 = 100_000_000) {
        self.pollNanoseconds = pollNanoseconds
    }

    /// Outcome of an admission attempt.
    public enum Outcome: Sendable, Equatable {
        case admitted
        /// Wait budget elapsed while another local run held the GPU.
        case timedOut(activeDescription: String)
        /// The waiting task itself was cancelled.
        case cancelled
    }

    /// Admit a run of `admissionClass`, waiting (bounded) while conflicting
    /// runs hold the GPU. `onWait` fires once, only if the run actually has
    /// to queue (feed "waiting" row). Every `.admitted` return MUST be paired
    /// with exactly one `release(_:)`.
    public func admit(
        _ admissionClass: SubagentAdmissionClass,
        modelKey: String? = nil,
        timeoutSeconds: TimeInterval = SubagentAdmission.defaultWaitTimeoutSeconds,
        onWait: (@Sendable (_ activeDescription: String) -> Void)? = nil
    ) async -> Outcome {
        let normalizedModelKey = Self.normalizedModelKey(modelKey)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var signaledWait = false
        while !canAdmit(admissionClass, modelKey: normalizedModelKey) {
            if !signaledWait {
                signaledWait = true
                onWait?(activeDescription)
            }
            if Task.isCancelled { return .cancelled }
            if Date() >= deadline { return .timedOut(activeDescription: activeDescription) }
            // Suspending releases the actor so concurrent release()/admit()
            // proceed; wake-up order between multiple waiters is unfair but
            // the population is tiny (one tool batch).
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        take(admissionClass, modelKey: normalizedModelKey)
        return .admitted
    }

    /// Release a previously admitted run.
    public func release(_ admissionClass: SubagentAdmissionClass, modelKey: String? = nil) {
        switch admissionClass {
        case .remote: remoteActive = max(0, remoteActive - 1)
        case .localInPlace:
            let key = Self.normalizedModelKey(modelKey)
            let remaining = max(0, (inPlaceByModel[key] ?? 0) - 1)
            if remaining == 0 {
                inPlaceByModel.removeValue(forKey: key)
            } else {
                inPlaceByModel[key] = remaining
            }
        case .localExclusive: exclusiveActive = max(0, exclusiveActive - 1)
        }
    }

    /// Live counters (tests + diagnostics).
    public func snapshot() -> (exclusive: Int, inPlace: Int, remote: Int) {
        (exclusiveActive, inPlaceByModel.values.reduce(0, +), remoteActive)
    }

    // MARK: - Internals

    private func canAdmit(
        _ admissionClass: SubagentAdmissionClass,
        modelKey: String
    ) -> Bool {
        switch admissionClass {
        case .remote:
            // Remote never touches the local GPU; even an exclusive handoff
            // in flight is irrelevant.
            return true
        case .localInPlace:
            guard exclusiveActive == 0 else { return false }
            return inPlaceByModel.isEmpty
                || (inPlaceByModel.count == 1 && inPlaceByModel[modelKey] != nil)
        case .localExclusive:
            return exclusiveActive == 0 && inPlaceByModel.isEmpty
        }
    }

    private func take(_ admissionClass: SubagentAdmissionClass, modelKey: String) {
        switch admissionClass {
        case .remote: remoteActive += 1
        case .localInPlace: inPlaceByModel[modelKey, default: 0] += 1
        case .localExclusive: exclusiveActive += 1
        }
    }

    private var activeDescription: String {
        var parts: [String] = []
        if exclusiveActive > 0 { parts.append("\(exclusiveActive) local handoff") }
        let inPlaceActive = inPlaceByModel.values.reduce(0, +)
        if inPlaceActive > 0 {
            let models = inPlaceByModel.keys.sorted().joined(separator: ", ")
            parts.append("\(inPlaceActive) local run [\(models)]")
        }
        return parts.isEmpty ? "another subagent" : parts.joined(separator: " + ")
    }

    private static func normalizedModelKey(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "<unspecified-local-model>" : trimmed.lowercased()
    }
}
