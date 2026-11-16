//
//  AttentionItem.swift
//  osaurus
//
//  One "a person is needed" moment: an approval card, a clarifying question,
//  a workflow form, an inbound message, a shared-agent conversation starting.
//  Producers raise these on `AttentionCenter`, which routes them to the
//  notification channels (desktop, in-app, paired phone, push) and carries
//  the answer back. See docs/AGENT_ATTENTION.md.
//

import Foundation

public enum AttentionKind: String, Codable, Sendable, CaseIterable {
    /// A local `.ask` tool approval card (`ToolPermissionPromptService`).
    case toolApproval = "tool_approval"
    /// A teammate's / remote caller's tool call waiting on the owner.
    case ownerApproval = "owner_approval"
    /// The agent asked a clarifying question and stopped.
    case clarification
    /// A workflow run parked on a form.
    case workflowDialog = "workflow_dialog"
    /// An `osaurus_config` plan waiting for review.
    case configApproval = "config_approval"
    /// A Computer Use step waiting for confirmation.
    case computerUse = "computer_use"
    /// A sandbox secret the agent asked the owner to enter.
    case secretRequest = "secret_request"
    /// An MCP server's elicitation form.
    case elicitation
    /// The Privacy Filter's review of a run the user started on another
    /// device: what it found, before it goes to the provider.
    case privacyReview = "privacy_review"
    /// A message arrived from a channel or another participant.
    case inboundMessage = "inbound_message"
    /// A teammate / remote agent started a conversation with a shared agent.
    case inboundSharedRun = "inbound_shared_run"
    /// The agent's `notify` tool, or a shared run pinging the owner.
    case agentNotice = "agent_notice"

    /// Whether the item blocks a run until a person answers.
    public var isBlocking: Bool {
        switch self {
        case .toolApproval, .ownerApproval, .clarification, .workflowDialog, .configApproval, .computerUse,
            .secretRequest, .elicitation, .privacyReview:
            return true
        case .inboundMessage, .inboundSharedRun, .agentNotice:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .toolApproval: return L("Tool approval")
        case .ownerApproval: return L("Approval for a shared agent")
        case .clarification: return L("Question from an agent")
        case .workflowDialog: return L("Workflow form")
        case .configApproval: return L("Configuration change")
        case .computerUse: return L("Computer Use confirmation")
        case .secretRequest: return L("Secret request")
        case .elicitation: return L("MCP form")
        case .privacyReview: return L("Privacy review")
        case .inboundMessage: return L("Inbound message")
        case .inboundSharedRun: return L("Shared agent conversation")
        case .agentNotice: return L("Agent notification")
        }
    }
}

/// Size limits for text a person sends through the attention layer.
public enum AttentionLimits {
    /// Replies (phone, notification, owner composer). The HTTP routes answer
    /// 400 above this; the notification reply is cut.
    public static let textCharacters = 16_384
    /// What Insights keeps of a reply under `message`.
    public static let insightsMessageCharacters = 4_096
}

/// What a person can do with an item from a notification or the phone.
public enum AttentionAction: String, Codable, Sendable, CaseIterable {
    case approve
    case deny
    case allowForConversation = "allow_for_conversation"
    /// Computer Use: approve this step and the run's later ones in the same
    /// app at the same effect or lower. Answered as `allowedForConversation`.
    case approveRest = "approve_rest"
    case reply
    case open
    case dismiss
}

/// Which surface answered (or received) an item.
public enum AttentionSurface: String, Codable, Sendable, CaseIterable {
    /// A card or panel inside the app.
    case inline
    /// A macOS notification action.
    case desktop
    /// The user's iPhone, or another of their devices, through Sync.
    case phone
    /// A push notification action (transport not shipped yet).
    case push
    /// No person: the item timed out, the run ended, or policy settled it.
    case system

    var displayName: String {
        switch self {
        case .inline: return L("In the app")
        case .desktop: return L("Desktop")
        case .phone: return L("iPhone")
        case .push: return L("Push")
        case .system: return L("Automatic")
        }
    }
}

/// The answer to an item.
public struct AttentionResolution: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case approved
        case denied
        case allowedForConversation = "allowed_for_conversation"
        case replied
        case dismissed
        case timedOut = "timed_out"
        /// The run that asked ended or was cancelled before an answer.
        case abandoned
    }

    public var outcome: Outcome
    public var surface: AttentionSurface
    /// Who answered. Nil for `system` outcomes.
    public var decidedBy: Participant?
    /// Reply text (content; withheld from logs when content storage is off).
    public var replyText: String?
    /// `privacyReview`, approved: the detections to replace with their
    /// placeholders. Nil replaces every one.
    public var redact: [String]?

    public init(
        outcome: Outcome,
        surface: AttentionSurface,
        decidedBy: Participant? = nil,
        replyText: String? = nil,
        redact: [String]? = nil
    ) {
        self.outcome = outcome
        self.surface = surface
        self.decidedBy = decidedBy
        self.replyText = replyText
        self.redact = redact
    }

    public var isGrant: Bool { outcome == .approved || outcome == .allowedForConversation }
}

public enum AttentionState: Equatable, Sendable {
    case pending
    case resolved(AttentionResolution)
    /// Withdrawn by the producer (answered elsewhere, run ended).
    case retracted
}

/// Where "Open" goes. Derived from session / task ids when not set.
public enum AttentionLink: Equatable, Sendable {
    case session(UUID)
    case task(UUID)
    case workflowRun(UUID)
    case agentDetail(agentId: UUID, viewRef: String?)
}

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: AttentionKind
    /// Who asked: the caller of a shared run, a channel sender, or the agent.
    public var requester: Participant?
    /// The agent the item is about.
    public var agent: Participant?
    public var agentId: UUID?
    public var sessionId: UUID?
    public var taskId: UUID?
    public var turnId: UUID?
    public var title: String
    public var body: String
    /// Tool name for approval kinds (name only, never arguments).
    public var toolName: String?
    /// The call's arguments, shown only in this Mac's Inbox so a request
    /// answered there is as informed as the inline card. Channels (desktop
    /// notifications, other devices) never read it.
    public var argumentsPreview: String? = nil
    /// What the owner's other devices show to answer it: a JSON object per
    /// kind (docs/SYNC_MOBILE_CONTRACT.md), at most `AttentionDetail.limit`
    /// bytes. Like `argumentsPreview`, desktop notifications never read it.
    public var detail: Data? = nil
    public var actions: [AttentionAction]
    public var priority: Priority
    public var createdAt: Date
    public var expiresAt: Date?
    public var state: AttentionState
    /// When the item left `pending`.
    public var settledAt: Date?
    /// Channel ids the item was delivered to.
    public var deliveredTo: [String]
    /// When the channels were handed the item; nil when none took it.
    public var deliveredAt: Date? = nil
    /// When the producer already shows its own card on screen. Desktop
    /// notifications skip these while the app is frontmost.
    public var hasInlineCard: Bool
    public var link: AttentionLink?

    /// `link`, else the task, else the session.
    public var effectiveLink: AttentionLink? {
        if let link { return link }
        if let taskId { return .task(taskId) }
        if let sessionId { return .session(sessionId) }
        if let agentId { return .agentDetail(agentId: agentId, viewRef: nil) }
        return nil
    }

    public enum Priority: Int, Codable, Sendable, Comparable {
        case low = 0
        case normal = 1
        case high = 2

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public init(
        id: UUID = UUID(),
        kind: AttentionKind,
        requester: Participant? = nil,
        agent: Participant? = nil,
        agentId: UUID? = nil,
        sessionId: UUID? = nil,
        taskId: UUID? = nil,
        turnId: UUID? = nil,
        title: String,
        body: String = "",
        toolName: String? = nil,
        actions: [AttentionAction]? = nil,
        priority: Priority? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        hasInlineCard: Bool = true,
        link: AttentionLink? = nil
    ) {
        self.link = link
        self.id = id
        self.kind = kind
        self.requester = requester
        self.agent = agent
        self.agentId = agentId
        self.sessionId = sessionId
        self.taskId = taskId
        self.turnId = turnId
        self.title = title
        self.body = body
        self.toolName = toolName
        self.actions = actions ?? Self.defaultActions(for: kind)
        self.priority = priority ?? (kind.isBlocking ? .high : .normal)
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = .pending
        self.settledAt = nil
        self.deliveredTo = []
        self.hasInlineCard = hasInlineCard
    }

    public var isPending: Bool { state == .pending }

    /// Time a person was waited on, once settled.
    public var waitDuration: TimeInterval? {
        settledAt.map { $0.timeIntervalSince(createdAt) }
    }

    public var resolution: AttentionResolution? {
        if case .resolved(let resolution) = state { return resolution }
        return nil
    }

    static func defaultActions(for kind: AttentionKind) -> [AttentionAction] {
        switch kind {
        case .ownerApproval: return [.approve, .allowForConversation, .deny, .open]
        case .toolApproval, .configApproval, .computerUse, .privacyReview: return [.approve, .deny, .open]
        case .clarification: return [.reply, .open]
        case .inboundMessage: return [.reply, .open, .dismiss]
        case .workflowDialog, .secretRequest, .elicitation, .inboundSharedRun, .agentNotice:
            return [.open, .dismiss]
        }
    }
}

/// Builds an item's `detail`.
enum AttentionDetail {
    static let limit = 8 * 1024

    /// `object` as JSON within `limit`. When it's larger, entries are taken
    /// off the end of the array under `listKey` and `truncated` (with the
    /// list's full `total`) says so; failing that, only `truncated` is sent.
    static func encode(_ object: [String: Any], listKey: String? = nil) -> Data? {
        func serialize(_ value: [String: Any]) -> Data? {
            try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        if let bytes = serialize(object), bytes.count <= limit { return bytes }
        if let listKey, var list = object[listKey] as? [Any] {
            let total = list.count
            var trimmed = object
            trimmed["truncated"] = true
            trimmed["total"] = total
            while !list.isEmpty {
                list.removeLast()
                trimmed[listKey] = list
                if let bytes = serialize(trimmed), bytes.count <= limit { return bytes }
            }
        }
        return serialize(["truncated": true])
    }

    /// `text` cut to `characters`, and whether it was.
    static func clip(_ text: String, _ characters: Int) -> (text: String, cut: Bool) {
        text.count > characters ? (String(text.prefix(characters)), true) : (text, false)
    }
}

/// Stream events for observers (channels, the Insights logger, the phone feed).
public enum AttentionEvent: Sendable {
    case raised(AttentionItem)
    case updated(AttentionItem)
    case resolved(AttentionItem)
    case retracted(AttentionItem)

    public var item: AttentionItem {
        switch self {
        case .raised(let item), .updated(let item), .resolved(let item), .retracted(let item): return item
        }
    }

    var wireName: String {
        switch self {
        case .raised: return "raised"
        case .updated: return "updated"
        case .resolved: return "resolved"
        case .retracted: return "retracted"
        }
    }
}
