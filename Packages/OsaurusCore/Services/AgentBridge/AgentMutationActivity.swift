//
//  AgentMutationActivity.swift
//  osaurus
//
//  Tiny MainActor-isolated registry of how many serialized
//  mutations are currently in flight per agent (spec §16 Q1). The
//  Schema and Data tabs read this to show a small spinner whenever
//  a write is queued or executing on the bridge's serial queue —
//  useful feedback when a long migration is running or when a
//  remote agent is doing background reconciliation.
//
//  Counts are best-effort: a crash in the body of `serialized`
//  could leave a count stranded. We track increments/decrements
//  symmetrically inside `LocalAgentBridge.serialized`, but the UI
//  is read-only so a stale count just leaves the spinner spinning
//  until the next agent action — easier-to-recover failure mode
//  than a deadlock would be.
//

import Combine
import Foundation

@MainActor
public final class AgentMutationActivity: ObservableObject {
    public static let shared = AgentMutationActivity()

    /// Per-agent count of mutations currently inside
    /// `LocalAgentBridge.serialized(_:body:)`. Zero / absent
    /// entries mean "no in-flight writes".
    @Published public private(set) var inFlight: [UUID: Int] = [:]

    private init() {}

    /// Convenience accessor for SwiftUI: `activity[agentId]` reads
    /// 0 when there's no entry.
    public subscript(agentId: UUID) -> Int {
        inFlight[agentId] ?? 0
    }

    /// Bump the counter for `agentId`. Called from the bridge's
    /// MainActor hop before it enters the agent's serial queue.
    public func begin(_ agentId: UUID) {
        inFlight[agentId, default: 0] += 1
    }

    /// Decrement and prune. We delete the entry once it hits zero
    /// so the dictionary doesn't grow unbounded across the
    /// lifetime of the app.
    public func end(_ agentId: UUID) {
        let current = inFlight[agentId] ?? 0
        let next = max(0, current - 1)
        if next == 0 {
            inFlight.removeValue(forKey: agentId)
        } else {
            inFlight[agentId] = next
        }
    }
}
