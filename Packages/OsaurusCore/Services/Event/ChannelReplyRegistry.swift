//
//  ChannelReplyRegistry.swift
//  osaurus
//
//  The live reply closures of channel-triggered workflow runs. A platform
//  hands the event layer a closure that posts into the conversation a
//  message came from; it cannot be stored, so it lives here for as long as
//  the run does. Runs are found by id, and failing that by the
//  conversation they were started from, so a sub-workflow (which has the
//  parent's `channelReply` on its caller but its own run id) reaches the
//  same room. The registry also remembers which runs already posted from a
//  `reply` step, so the rule's automatic final post can stand down.
//

import Foundation

@MainActor
final class ChannelReplyRegistry {
    static let shared = ChannelReplyRegistry()

    struct Entry: Sendable {
        var sink: ChannelReplySink
        var target: WorkflowChannelReplyTarget
    }

    struct Resolved: Sendable {
        var sink: ChannelReplySink
        /// The run the sink was registered for; the run asked about when
        /// found by id, else the live run of the same conversation.
        var ownerRunID: UUID
        /// The owner is the run itself or one of its parents, so a reply
        /// speaks for it. False when borrowed from another run of the
        /// same conversation.
        var speaksForOwner: Bool = true
    }

    private var entries: [UUID: Entry] = [:]
    /// Replies counted this launch, including runs with no record yet.
    private var replyCounts: [UUID: Int] = [:]
    /// Counts a reply on the run's record; nil when it has none.
    private let persistReply: (UUID) -> Int?
    /// The count on the run's record.
    private let persistedCount: (UUID) -> Int

    init(
        persistReply: @escaping (UUID) -> Int? = { WorkflowRunStore.shared.noteChannelReply(runID: $0) },
        persistedCount: @escaping (UUID) -> Int = { WorkflowRunStore.shared.run(id: $0)?.channelReplyCount ?? 0 }
    ) {
        self.persistReply = persistReply
        self.persistedCount = persistedCount
    }

    func register(runID: UUID, target: WorkflowChannelReplyTarget, sink: ChannelReplySink) {
        entries[runID] = Entry(sink: sink, target: target)
    }

    /// Forgets the run's live sink. Its reply count stays on the record.
    func unregister(runID: UUID) {
        entries.removeValue(forKey: runID)
        replyCounts.removeValue(forKey: runID)
    }

    /// The live sink for `runID`, else for the run up its `parentRunID`
    /// chain that registered one, else one registered for the same
    /// conversation as `target`.
    func resolve(
        runID: UUID, target: WorkflowChannelReplyTarget?, parentRunID: UUID? = nil,
        parentOf: (UUID) -> UUID? = { WorkflowRunStore.shared.run(id: $0)?.caller.parentRunID }
    ) -> Resolved? {
        if let entry = entries[runID] { return Resolved(sink: entry.sink, ownerRunID: runID) }
        var ancestor = parentRunID
        var hops = 0
        while let id = ancestor, hops < 16 {
            if let entry = entries[id] { return Resolved(sink: entry.sink, ownerRunID: id) }
            ancestor = parentOf(id)
            hops += 1
        }
        guard let target else { return nil }
        let key = target.conversationKey
        guard let match = entries.first(where: { $0.value.target.conversationKey == key }) else { return nil }
        return Resolved(sink: match.value.sink, ownerRunID: match.key, speaksForOwner: false)
    }

    func target(for runID: UUID) -> WorkflowChannelReplyTarget? { entries[runID]?.target }

    /// Notes that a `reply` step of `runID` (or of a run started on its
    /// behalf) posted into the conversation.
    func markReplied(runID: UUID) {
        let persisted = persistReply(runID)
        replyCounts[runID] = max(persisted ?? 0, (replyCounts[runID] ?? 0) + 1)
    }

    /// Replies `runID` posted, this launch or before it.
    func replyCount(runID: UUID) -> Int {
        max(replyCounts[runID] ?? 0, persistedCount(runID))
    }

    func hasStepReplied(runID: UUID) -> Bool { replyCount(runID: runID) > 0 }

    var liveRunIDs: [UUID] { Array(entries.keys) }

    func resetForTesting() {
        entries.removeAll()
        replyCounts.removeAll()
    }
}
