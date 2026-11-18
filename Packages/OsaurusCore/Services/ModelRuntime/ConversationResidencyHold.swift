//
//  ConversationResidencyHold.swift
//  osaurus
//
//  Keeps a model resident while a conversation loop is mid-turn.
//

import Foundation
import os

/// A conversation loop's claim on the local models it generates with. `AgentToolLoop.run` takes one for its whole
/// run (chat, agents, the API agent loop, plugins, subagents); `ModelRuntime` registers every model a generation
/// inside the loop uses. While a model is held, its idle-unload timer does not run, so a tool call that takes longer
/// than the idle setting (default 30 s), or a permission prompt the user answers slowly, does not unload the model
/// between two steps of one turn. MiniMax-M3.1-Flash-JANGHT1.9 (95 GB) paid 13.6-14.4 s per such reload on an M5 Max,
/// plus the re-prefill. When the loop exits the hold is released and the idle timer starts THEN, so the user's
/// setting keeps its meaning for a truly idle model ("unload N seconds after the last use").
///
/// The hold affects only the idle timer. Explicit unloads, model switches, memory-pressure eviction and settings
/// changes are unchanged, and nothing is ever refused because of it.
final class ConversationResidencyHold: Sendable {
    let id = UUID()
    private let released = OSAllocatedUnfairLock(initialState: false)

    /// False once the loop has exited. A generation that starts after that (a background request spawned inside the
    /// loop that outlives it) must not re-register the hold: nothing would release it again.
    var isActive: Bool { !released.withLock { $0 } }

    func markReleased() {
        released.withLock { $0 = true }
    }
}

enum ConversationResidencyHoldContext {
    /// The hold of the conversation loop the current task runs in (nil outside one).
    @TaskLocal static var current: ConversationResidencyHold?
}

/// Which models which live holds keep resident. Mutated only on `ModelRuntime`'s actor; a value type so the tests
/// drive the exact production bookkeeping.
struct ConversationResidencyHolds: Sendable {
    private var modelsByHold: [UUID: Set<String>] = [:]
    private var holdsByModel: [String: Set<UUID>] = [:]

    /// Records that `hold`'s loop generated with `model`. Ignored once the hold was released.
    @discardableResult
    mutating func register(_ hold: ConversationResidencyHold, model: String) -> Bool {
        guard hold.isActive else { return false }
        modelsByHold[hold.id, default: []].insert(model)
        holdsByModel[model, default: []].insert(hold.id)
        return true
    }

    func holds(_ model: String) -> Bool {
        !(holdsByModel[model]?.isEmpty ?? true)
    }

    func holdCount(for model: String) -> Int {
        holdsByModel[model]?.count ?? 0
    }

    /// Ends `hold`. Returns the models no live hold keeps anymore (their idle timers may start now).
    mutating func release(_ hold: ConversationResidencyHold) -> [String] {
        hold.markReleased()
        guard let models = modelsByHold.removeValue(forKey: hold.id) else { return [] }
        var freed: [String] = []
        for model in models.sorted() {
            holdsByModel[model]?.remove(hold.id)
            if holdsByModel[model]?.isEmpty ?? true {
                holdsByModel.removeValue(forKey: model)
                freed.append(model)
            }
        }
        return freed
    }
}
