//
//  EventOccurrence.swift
//  osaurus
//
//  One thing that happened which an event may act on, as a source adapter
//  hands it to `EventManager`.
//

import Foundation

struct EventOccurrence: Sendable {
    enum Trigger: String, Sendable {
        /// The source fired on its own (timer, file change, HTTP call, message).
        case source
        /// "Fire now" from the Events screen or the orchestrator.
        case manual
    }

    var eventId: UUID
    var firedAt: Date
    var payload: JSONValue
    var trigger: Trigger
    /// Delivery id for dedupe (schedule slot, webhook idempotency key,
    /// provider event id). nil = never a duplicate.
    var dedupeKey: String?
    /// Lane key for `perConversation` delivery (channel room/thread,
    /// webhook `X-Osaurus-Conversation`).
    var conversationKey: String?
    /// The agent prompt when the source builds its own (folder runs).
    /// nil = render the action's instructions against the payload.
    var agentPrompt: String?
    /// The working folder the run must use (folder sources).
    var folderPath: String?
    var folderBookmark: Data?
    /// The caller came from outside the app (webhook, remote channel sender).
    var isExternal: Bool
    var loadIntent: ModelLoadIntent
    /// Where workflow output goes back to (channel sources).
    var replySink: ChannelReplySink?
    /// The conversation the message came from, kept on the run's caller so
    /// `reply` steps and relayed dialogs can address it later (channel
    /// sources).
    var channelReplyTarget: WorkflowChannelReplyTarget?
    /// Ledger metadata (sizes, ids) — never bodies.
    var summary: [String: String]

    init(
        eventId: UUID,
        firedAt: Date = Date(),
        payload: JSONValue,
        trigger: Trigger = .source,
        dedupeKey: String? = nil,
        conversationKey: String? = nil,
        agentPrompt: String? = nil,
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        isExternal: Bool = false,
        loadIntent: ModelLoadIntent = .background,
        replySink: ChannelReplySink? = nil,
        channelReplyTarget: WorkflowChannelReplyTarget? = nil,
        summary: [String: String] = [:]
    ) {
        self.channelReplyTarget = channelReplyTarget
        self.eventId = eventId
        self.firedAt = firedAt
        self.payload = payload
        self.trigger = trigger
        self.dedupeKey = dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.conversationKey = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.agentPrompt = agentPrompt
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.isExternal = isExternal
        self.loadIntent = loadIntent
        self.replySink = replySink
        self.summary = summary
    }
}

/// What `EventManager` did with an occurrence.
public struct EventFireResult: Sendable, Equatable {
    public var runId: UUID
    public var status: EventRunStatus
    public var reason: String?

    public var accepted: Bool {
        switch status {
        case .queued, .running, .succeeded, .awaitingUser: true
        default: false
        }
    }
}

extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
