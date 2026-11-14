//
//  OsaurusEvent.swift
//  osaurus
//
//  An Event is one trigger rule: a source that fires (a schedule, a folder
//  change, a webhook call, a channel message), an optional filter, and the
//  action it runs (an agent turn or a workflow run), plus how fires are
//  queued and whether the result is replied back to the channel.
//
//  Events replace the separate Schedules, Watchers and per-platform channel
//  inbound-routing configurations: each of those is now one source kind.
//

import Foundation

// MARK: - Source

public enum EventSourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case schedule
    case folder
    case webhook
    case rss
    case sse
    case runFailed = "run_failed"
    case app
    case email
    case channelMessage = "channel_message"

    public var id: String { rawValue }

    var descriptor: any EventSourceDescriptor { EventSourceRegistry.descriptor(for: self) }

    public var displayName: String { descriptor.displayName }

    public var icon: String { descriptor.icon }

    /// The persisted session origin for agent runs this source starts. Kept
    /// on the historical values so sidebar labels, residency policy and the
    /// `agent_runs` audit trail are unchanged by the move to events.
    public var sessionSource: SessionSource { descriptor.sessionSource }
}

public struct ScheduleSourceConfig: Codable, Equatable, Sendable {
    public var frequency: ScheduleFrequency

    public init(frequency: ScheduleFrequency) {
        self.frequency = frequency
    }
}

public struct FolderSourceConfig: Codable, Equatable, Sendable {
    /// Display path of the watched directory.
    public var path: String?
    /// Security-scoped bookmark for the watched directory.
    public var bookmark: Data?
    public var recursive: Bool
    public var responsiveness: Responsiveness
    /// Seconds to wait after a run before re-fingerprinting (FSEvents latency x2).
    public var settleSeconds: TimeInterval

    public init(
        path: String? = nil,
        bookmark: Data? = nil,
        recursive: Bool = false,
        responsiveness: Responsiveness = .balanced,
        settleSeconds: TimeInterval = 2.0
    ) {
        self.path = path
        self.bookmark = bookmark
        self.recursive = recursive
        self.responsiveness = responsiveness
        self.settleSeconds = settleSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        responsiveness = try c.decodeIfPresent(Responsiveness.self, forKey: .responsiveness) ?? .balanced
        settleSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .settleSeconds) ?? 2.0
    }

    public var displayPath: String {
        guard let path, !path.isEmpty else { return L("No folder selected") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// How a webhook caller proves it is allowed to fire the event, on top of
/// knowing the unguessable URL token.
public enum WebhookVerificationMethod: String, Codable, CaseIterable, Sendable {
    /// The URL token alone.
    case none
    /// A header carrying the event's secret verbatim.
    case sharedSecretHeader = "shared_secret_header"
    /// An HMAC-SHA256 of the raw body keyed by the event's secret.
    case hmacSHA256 = "hmac_sha256"

    public var displayName: String {
        switch self {
        case .none: L("URL token only")
        case .sharedSecretHeader: L("Shared secret header")
        case .hmacSHA256: L("HMAC-SHA256 signature")
        }
    }

    var channelMethod: AgentChannelSourceVerificationMethod {
        switch self {
        case .none: .none
        case .sharedSecretHeader: .sharedSecretHeader
        case .hmacSHA256: .hmacSHA256
        }
    }
}

public struct WebhookSourceConfig: Codable, Equatable, Sendable {
    /// Unguessable path segment of `/events/{token}`. Distinct from the event
    /// id so rotating it does not change the event's identity.
    public var token: String
    /// Who sends it. `generic` checks `verification`; a named provider
    /// checks the way that provider signs, and handles its setup handshake.
    public var provider: WebhookProvider
    public var verification: WebhookVerificationMethod
    /// Header carrying the secret or signature; nil uses the default for the method.
    public var signatureHeader: String?
    /// Prefix before the hex digest (`sha256=` when nil, GitHub style).
    public var signaturePrefix: String?
    public var maxBodyBytes: Int
    public var rateLimitPerMinute: Int
    /// An example request body (usually JSON) the sender posts. Not used to
    /// accept or reject calls: it lists the body's fields as values a
    /// workflow input can bind to, and Run Now and the test command send it.
    public var sampleBody: String?

    public static let defaultMaxBodyBytes = 256 * 1024
    public static let defaultRateLimitPerMinute = 60
    public static let defaultSecretHeader = "X-Osaurus-Event-Secret"
    public static let defaultSignatureHeader = "X-Osaurus-Signature"

    public init(
        token: String = WebhookSourceConfig.makeToken(),
        provider: WebhookProvider = .generic,
        verification: WebhookVerificationMethod = .hmacSHA256,
        signatureHeader: String? = nil,
        signaturePrefix: String? = nil,
        maxBodyBytes: Int = WebhookSourceConfig.defaultMaxBodyBytes,
        rateLimitPerMinute: Int = WebhookSourceConfig.defaultRateLimitPerMinute,
        sampleBody: String? = nil
    ) {
        self.token = token
        self.provider = provider
        self.sampleBody = sampleBody
        self.verification = verification
        self.signatureHeader = signatureHeader
        self.signaturePrefix = signaturePrefix
        self.maxBodyBytes = maxBodyBytes
        self.rateLimitPerMinute = rateLimitPerMinute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        provider = try c.decodeIfPresent(WebhookProvider.self, forKey: .provider) ?? .generic
        verification = try c.decodeIfPresent(WebhookVerificationMethod.self, forKey: .verification) ?? .none
        signatureHeader = try c.decodeIfPresent(String.self, forKey: .signatureHeader)
        signaturePrefix = try c.decodeIfPresent(String.self, forKey: .signaturePrefix)
        maxBodyBytes = try c.decodeIfPresent(Int.self, forKey: .maxBodyBytes) ?? Self.defaultMaxBodyBytes
        rateLimitPerMinute =
            try c.decodeIfPresent(Int.self, forKey: .rateLimitPerMinute) ?? Self.defaultRateLimitPerMinute
        sampleBody = try c.decodeIfPresent(String.self, forKey: .sampleBody)
    }

    /// Whether calls are checked against a secret (the generic method, or
    /// the provider's signing scheme).
    var checksSecret: Bool {
        WebhookProviderProfile.profile(for: self).verifier.checksSecret
    }

    /// The header the caller must send, resolved against the method default.
    public var effectiveHeader: String? {
        switch verification {
        case .none: return nil
        case .sharedSecretHeader: return signatureHeader?.nilIfBlank ?? Self.defaultSecretHeader
        case .hmacSHA256: return signatureHeader?.nilIfBlank ?? Self.defaultSignatureHeader
        }
    }

    /// 32 random bytes, base64url without padding.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct ChannelMessageSourceConfig: Codable, Equatable, Sendable {
    public var kind: AgentChannelKind
    /// The connection the message arrives on: the native platform id
    /// (`discord`, `slack`, …) or a custom/n8n connection id.
    public var connectionId: String
    /// Provider room/channel/chat ids this event listens in; empty = any room
    /// the connection is allowed to read.
    public var roomIds: [String]
    /// Case-insensitive leading tokens that select this event inside a room
    /// ("sales: what changed?"). An event with aliases only fires when one
    /// is used, and the alias is stripped from the message.
    public var aliases: [String]
    /// Only fire when the bot is @mentioned (platforms that support mentions).
    public var requireMention: Bool
    /// When mentions are required, still fire for follow-ups in a thread the
    /// agent already replied in.
    public var continueThreads: Bool

    public init(
        kind: AgentChannelKind,
        connectionId: String? = nil,
        roomIds: [String] = [],
        aliases: [String] = [],
        requireMention: Bool? = nil,
        continueThreads: Bool = true
    ) {
        self.kind = kind
        self.connectionId = (connectionId?.nilIfBlank ?? Self.nativeConnectionId(for: kind)) ?? kind.rawValue
        self.roomIds = Self.normalizedRooms(roomIds)
        self.aliases = AgentChannelDispatchRoute.normalizedAliases(aliases)
        self.requireMention = requireMention ?? Self.defaultRequiresMention(kind)
        self.continueThreads = continueThreads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(AgentChannelKind.self, forKey: .kind)
        self.init(
            kind: kind,
            connectionId: try c.decodeIfPresent(String.self, forKey: .connectionId),
            roomIds: try c.decodeIfPresent([String].self, forKey: .roomIds) ?? [],
            aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            requireMention: try c.decodeIfPresent(Bool.self, forKey: .requireMention),
            continueThreads: try c.decodeIfPresent(Bool.self, forKey: .continueThreads) ?? true
        )
    }

    /// The native connection id messages from `kind` arrive on; nil for
    /// kinds that are always user-created connections (n8n, custom HTTP).
    public static func nativeConnectionId(for kind: AgentChannelKind) -> String? {
        switch kind {
        case .discord: "discord"
        case .slack: "slack"
        case .telegram: "telegram"
        case .imessage: "imessage"
        case .whatsapp: "whatsapp"
        case .email: "email"
        case .n8n, .customHTTP: nil
        }
    }

    /// Mention gating is on by default only where the platform has mentions
    /// and shared rooms are the norm.
    public static func defaultRequiresMention(_ kind: AgentChannelKind) -> Bool {
        switch kind {
        case .discord, .slack: true
        case .telegram, .imessage, .whatsapp, .email, .n8n, .customHTTP: false
        }
    }

    /// Platforms that report whether a message mentions the bot (WhatsApp:
    /// in groups; a direct message is always addressed to the account).
    public static func supportsMentions(_ kind: AgentChannelKind) -> Bool {
        switch kind {
        case .discord, .slack, .whatsapp: true
        case .telegram, .imessage, .email, .n8n, .customHTTP: false
        }
    }

    static func normalizedRooms(_ rooms: [String]) -> [String] {
        var seen = Set<String>()
        return
            rooms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// New mail in one or more mailboxes of a Mail app or IMAP account.
public struct EmailSourceConfig: Codable, Equatable, Sendable {
    /// The `SourceConnection` the mail is read from.
    public var connectionId: String
    /// Mailbox paths as the account names them; empty = the inbox.
    public var mailboxes: [String]
    public var unreadOnly: Bool
    /// Put the message body in the payload (Mail reads each message once).
    public var includeBody: Bool
    public var maxBodyChars: Int
    public var pollIntervalSeconds: Int
    /// What the first check after a relaunch does with mail that arrived
    /// while the app was closed.
    public var catchUp: SourceCatchUpPolicy

    public static let inbox = "INBOX"
    public static let defaultPollIntervalSeconds = 120
    public static let pollIntervalRange = 60...3600
    public static let defaultMaxBodyChars = 20_000
    public static let maxBodyCharsRange = 500...200_000

    public init(
        connectionId: String = "",
        mailboxes: [String] = [],
        unreadOnly: Bool = false,
        includeBody: Bool = true,
        maxBodyChars: Int = EmailSourceConfig.defaultMaxBodyChars,
        pollIntervalSeconds: Int = EmailSourceConfig.defaultPollIntervalSeconds,
        catchUp: SourceCatchUpPolicy = .sinceCursor
    ) {
        self.connectionId = connectionId
        self.mailboxes = ChannelMessageSourceConfig.normalizedRooms(mailboxes)
        self.unreadOnly = unreadOnly
        self.includeBody = includeBody
        self.maxBodyChars = min(max(maxBodyChars, Self.maxBodyCharsRange.lowerBound), Self.maxBodyCharsRange.upperBound)
        self.pollIntervalSeconds = min(
            max(pollIntervalSeconds, Self.pollIntervalRange.lowerBound), Self.pollIntervalRange.upperBound)
        self.catchUp = catchUp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            connectionId: try c.decodeIfPresent(String.self, forKey: .connectionId) ?? "",
            mailboxes: try c.decodeIfPresent([String].self, forKey: .mailboxes) ?? [],
            unreadOnly: try c.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? false,
            includeBody: try c.decodeIfPresent(Bool.self, forKey: .includeBody) ?? true,
            maxBodyChars: try c.decodeIfPresent(Int.self, forKey: .maxBodyChars) ?? Self.defaultMaxBodyChars,
            pollIntervalSeconds: try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
                ?? Self.defaultPollIntervalSeconds,
            catchUp: try c.decodeIfPresent(SourceCatchUpPolicy.self, forKey: .catchUp) ?? .sinceCursor)
    }

    /// The mailboxes actually checked.
    public var effectiveMailboxes: [String] { mailboxes.isEmpty ? [Self.inbox] : mailboxes }
}

public enum EventSource: Equatable, Sendable {
    case schedule(ScheduleSourceConfig)
    case folder(FolderSourceConfig)
    case webhook(WebhookSourceConfig)
    case rss(RSSSourceConfig)
    case sse(SSESourceConfig)
    case runFailed(RunFailedSourceConfig)
    case app(AppEventsSourceConfig)
    case email(EmailSourceConfig)
    case channelMessage(ChannelMessageSourceConfig)

    public var kind: EventSourceKind {
        switch self {
        case .schedule: .schedule
        case .folder: .folder
        case .webhook: .webhook
        case .rss: .rss
        case .sse: .sse
        case .runFailed: .runFailed
        case .app: .app
        case .email: .email
        case .channelMessage: .channelMessage
        }
    }

    public var rss: RSSSourceConfig? {
        if case .rss(let c) = self { return c }
        return nil
    }

    public var sse: SSESourceConfig? {
        if case .sse(let c) = self { return c }
        return nil
    }

    public var runFailed: RunFailedSourceConfig? {
        if case .runFailed(let c) = self { return c }
        return nil
    }

    public var app: AppEventsSourceConfig? {
        if case .app(let c) = self { return c }
        return nil
    }

    public var schedule: ScheduleSourceConfig? {
        if case .schedule(let c) = self { return c }
        return nil
    }

    public var folder: FolderSourceConfig? {
        if case .folder(let c) = self { return c }
        return nil
    }

    public var webhook: WebhookSourceConfig? {
        if case .webhook(let c) = self { return c }
        return nil
    }

    public var channelMessage: ChannelMessageSourceConfig? {
        if case .channelMessage(let c) = self { return c }
        return nil
    }

    public var email: EmailSourceConfig? {
        if case .email(let c) = self { return c }
        return nil
    }

    /// The `SourceConnection` the source reads from; nil for kinds without
    /// one (channels use `AgentChannelConnection`).
    public var connectionId: String? {
        switch self {
        case .email(let config): config.connectionId.isEmpty ? nil : config.connectionId
        case .schedule, .folder, .webhook, .rss, .sse, .runFailed, .app, .channelMessage: nil
        }
    }
}

extension EventSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, schedule, folder, webhook, rss, sse, runFailed, app, email, channelMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(EventSourceKind.self, forKey: .kind) {
        case .schedule: self = .schedule(try c.decode(ScheduleSourceConfig.self, forKey: .schedule))
        case .folder: self = .folder(try c.decode(FolderSourceConfig.self, forKey: .folder))
        case .webhook: self = .webhook(try c.decode(WebhookSourceConfig.self, forKey: .webhook))
        case .rss: self = .rss(try c.decode(RSSSourceConfig.self, forKey: .rss))
        case .sse: self = .sse(try c.decode(SSESourceConfig.self, forKey: .sse))
        case .runFailed: self = .runFailed(try c.decode(RunFailedSourceConfig.self, forKey: .runFailed))
        case .app: self = .app(try c.decode(AppEventsSourceConfig.self, forKey: .app))
        case .email: self = .email(try c.decode(EmailSourceConfig.self, forKey: .email))
        case .channelMessage:
            self = .channelMessage(try c.decode(ChannelMessageSourceConfig.self, forKey: .channelMessage))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .schedule(let config): try c.encode(config, forKey: .schedule)
        case .folder(let config): try c.encode(config, forKey: .folder)
        case .webhook(let config): try c.encode(config, forKey: .webhook)
        case .rss(let config): try c.encode(config, forKey: .rss)
        case .sse(let config): try c.encode(config, forKey: .sse)
        case .runFailed(let config): try c.encode(config, forKey: .runFailed)
        case .app(let config): try c.encode(config, forKey: .app)
        case .email(let config): try c.encode(config, forKey: .email)
        case .channelMessage(let config): try c.encode(config, forKey: .channelMessage)
        }
    }
}

// MARK: - Filter

/// `path` (dot path into the event payload) must equal `equals` once
/// rendered as text.
public struct EventCondition: Codable, Equatable, Sendable, Hashable {
    public var path: String
    public var equals: String

    public init(path: String, equals: String) {
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.equals = equals
    }
}

/// Conditions an occurrence must meet to run the action. Every non-empty
/// clause must hold. An occurrence that fails is recorded as `filtered`.
public struct EventFilter: Codable, Equatable, Sendable {
    /// Channel sender ids/handles, or mail addresses and `@domain`s
    /// (case-insensitive).
    public var senderAllowlist: [String]
    /// The occurrence text contains at least one of these (case-insensitive).
    public var keywordsAny: [String]
    /// The occurrence text contains every one of these (case-insensitive).
    public var keywordsAll: [String]
    /// Folder: at least one changed path matches one of these globs
    /// (matched against the file name and the full path).
    public var pathGlobs: [String]
    /// Payload field equality checks (e.g. `webhook.body.action == opened`).
    public var conditions: [EventCondition]

    public init(
        senderAllowlist: [String] = [],
        keywordsAny: [String] = [],
        keywordsAll: [String] = [],
        pathGlobs: [String] = [],
        conditions: [EventCondition] = []
    ) {
        self.senderAllowlist = Self.normalized(senderAllowlist)
        self.keywordsAny = Self.normalized(keywordsAny)
        self.keywordsAll = Self.normalized(keywordsAll)
        self.pathGlobs = Self.normalized(pathGlobs)
        self.conditions = conditions.filter { !$0.path.isEmpty }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            senderAllowlist: try c.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            keywordsAny: try c.decodeIfPresent([String].self, forKey: .keywordsAny) ?? [],
            keywordsAll: try c.decodeIfPresent([String].self, forKey: .keywordsAll) ?? [],
            pathGlobs: try c.decodeIfPresent([String].self, forKey: .pathGlobs) ?? [],
            conditions: try c.decodeIfPresent([EventCondition].self, forKey: .conditions) ?? []
        )
    }

    public var isEmpty: Bool {
        senderAllowlist.isEmpty && keywordsAny.isEmpty && keywordsAll.isEmpty && pathGlobs.isEmpty
            && conditions.isEmpty
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return
            values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Action

public struct AgentEventAction: Codable, Equatable, Sendable {
    /// Who runs the turn: an agent hosted here or a teammate's shared
    /// workspace agent. nil = not chosen yet (the event never fires).
    public var target: AgentDispatchTarget?
    /// The instructions for the turn. Supports `{{…}}` payload bindings. For
    /// channel messages these are context placed ahead of the message.
    public var instructions: String
    /// Working folder for the run (display path + bookmark). Folder events
    /// always run in the watched folder instead.
    public var folderPath: String?
    public var folderBookmark: Data?
    /// Start a new chat on every fire instead of continuing the event's chat.
    public var freshSessionPerFire: Bool

    public init(
        target: AgentDispatchTarget? = nil,
        instructions: String = "",
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        freshSessionPerFire: Bool = true
    ) {
        self.target = target
        self.instructions = instructions
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.freshSessionPerFire = freshSessionPerFire
    }

    /// Schedules and webhooks start a new chat per fire; a folder keeps one
    /// chat (its follow-up passes build on the previous one) and a channel
    /// keeps one per conversation.
    public static func defaultFreshSession(for kind: EventSourceKind) -> Bool {
        kind.descriptor.defaultFreshSession
    }

    private enum CodingKeys: String, CodingKey {
        case target, agentId, instructions, folderPath, folderBookmark, freshSessionPerFire
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decodeAgentTarget(targetKey: .target, legacyAgentIdKey: .agentId)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        freshSessionPerFire = try c.decodeIfPresent(Bool.self, forKey: .freshSessionPerFire) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeAgentTarget(target, targetKey: .target, legacyAgentIdKey: .agentId)
        try c.encode(instructions, forKey: .instructions)
        try c.encodeIfPresent(folderPath, forKey: .folderPath)
        try c.encodeIfPresent(folderBookmark, forKey: .folderBookmark)
        try c.encode(freshSessionPerFire, forKey: .freshSessionPerFire)
    }
}

public struct WorkflowEventAction: Codable, Equatable, Sendable {
    public var workflowID: UUID
    /// Workflow input field → template. A template that is exactly one
    /// `{{path}}` binding passes the payload value through with its JSON
    /// type; anything else renders to text. Values are coerced to the type
    /// the workflow's input schema declares.
    public var inputMapping: [String: String]
    /// The agent the run uses the keys and sessions of. nil runs with the
    /// shared keys and default sessions. The person chose it, so the
    /// workflow need not be on that agent's list.
    public var runAsAgentId: UUID?

    public init(workflowID: UUID, inputMapping: [String: String] = [:], runAsAgentId: UUID? = nil) {
        self.workflowID = workflowID
        self.inputMapping = inputMapping
        self.runAsAgentId = runAsAgentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try c.decode(UUID.self, forKey: .workflowID)
        inputMapping = try c.decodeIfPresent([String: String].self, forKey: .inputMapping) ?? [:]
        runAsAgentId = try c.decodeIfPresent(UUID.self, forKey: .runAsAgentId)
    }
}

/// One answer from a model with no tools and no agent: the instructions
/// (with the trigger's content, wrapped as untrusted) go in, the text comes
/// out into the automation's chat.
public struct PromptEventAction: Codable, Equatable, Sendable {
    /// What to ask. Supports `{{…}}` payload bindings.
    public var instructions: String
    /// The model that answers. nil uses the default model for new agents.
    public var model: String?

    public init(instructions: String = "", model: String? = nil) {
        self.instructions = instructions
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

public enum EventActionKind: String, Codable, CaseIterable, Sendable {
    case agent
    case workflow
    case prompt

    public var displayName: String {
        switch self {
        case .agent: L("Run Agent")
        case .workflow: L("Run Workflow")
        case .prompt: L("Ask a Model")
        }
    }
}

public enum EventAction: Equatable, Sendable {
    case agent(AgentEventAction)
    case workflow(WorkflowEventAction)
    case prompt(PromptEventAction)

    public var kind: EventActionKind {
        switch self {
        case .agent: .agent
        case .workflow: .workflow
        case .prompt: .prompt
        }
    }

    public var prompt: PromptEventAction? {
        if case .prompt(let p) = self { return p }
        return nil
    }

    public var agent: AgentEventAction? {
        if case .agent(let a) = self { return a }
        return nil
    }

    public var workflow: WorkflowEventAction? {
        if case .workflow(let w) = self { return w }
        return nil
    }
}

extension EventAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, agent, workflow, prompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(EventActionKind.self, forKey: .kind) {
        case .agent: self = .agent(try c.decode(AgentEventAction.self, forKey: .agent))
        case .workflow: self = .workflow(try c.decode(WorkflowEventAction.self, forKey: .workflow))
        case .prompt: self = .prompt(try c.decodeIfPresent(PromptEventAction.self, forKey: .prompt) ?? .init())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .agent(let a): try c.encode(a, forKey: .agent)
        case .workflow(let w): try c.encode(w, forKey: .workflow)
        case .prompt(let p): try c.encode(p, forKey: .prompt)
        }
    }
}

// MARK: - Delivery

public enum EventDeliveryMode: String, Codable, CaseIterable, Sendable {
    /// One run at a time for the event; further fires wait in the queue.
    case serial
    /// One run at a time per conversation (channel room/thread, webhook
    /// session key); different conversations run side by side.
    case perConversation = "per_conversation"
    /// Up to `maxConcurrent` runs of the event at once.
    case parallel

    public var displayName: String {
        switch self {
        case .serial: L("One at a time")
        case .perConversation: L("One per conversation")
        case .parallel: L("In parallel")
        }
    }
}

public enum EventMissedFirePolicy: String, Codable, CaseIterable, Sendable {
    /// Run once at launch for the latest slot missed while the app was closed.
    case runOnce = "run_once"
    /// Drop missed slots; wait for the next one.
    case skip
    /// Run every slot missed while the app was closed (up to
    /// `catchUpLimit`), oldest first. A one-shot has one slot.
    case runCatchup = "run_catchup"

    /// Most missed slots a catch-up replays.
    public static let catchUpLimit = 24

    public var displayName: String {
        switch self {
        case .runOnce: L("Run once on launch")
        case .skip: L("Skip")
        case .runCatchup: L("Run every missed time")
        }
    }
}

/// How a repeated delivery id is treated.
public enum EventDedupePolicy: Equatable, Sendable {
    /// Every occurrence runs.
    case none
    /// A repeat inside this many seconds is a duplicate.
    case window(TimeInterval)
    /// A repeat is a duplicate however long ago the first one was
    /// (`event_seen_keys`).
    case durable

    public static let defaultWindowSeconds: TimeInterval = 600

    public var mode: EventDedupeMode {
        switch self {
        case .none: .none
        case .window: .window
        case .durable: .durable
        }
    }

    /// `.window(0)` is `.none`.
    static func normalized(_ policy: EventDedupePolicy) -> EventDedupePolicy {
        if case .window(let seconds) = policy, seconds <= 0 { return .none }
        return policy
    }
}

public struct EventDeliveryPolicy: Codable, Equatable, Sendable {
    public var mode: EventDeliveryMode
    /// Parallel mode only.
    public var maxConcurrent: Int
    /// Fires held while a lane is busy; past this they are suppressed. 0 =
    /// a fire while busy is skipped.
    public var maxQueued: Int
    /// Channel agent runs: a message for a conversation whose turn is still
    /// streaming joins that turn instead of waiting for a new one.
    public var steerRunningTurn: Bool
    /// How a repeated delivery id (provider event id, webhook idempotency
    /// key, schedule slot, mail Message-ID) is recorded as a duplicate.
    public var dedupe: EventDedupePolicy
    /// Schedule sources only.
    public var missedFirePolicy: EventMissedFirePolicy
    /// The task queue fires wait on; nil = Default.
    public var queueId: UUID?

    public static let maxQueuedCeiling = 100
    public static let maxConcurrentCeiling = 8

    /// The editor's **Allow overlapping runs**: off is one run at a time
    /// (per conversation for sources that have conversations), on lets
    /// fires overlap up to `maxConcurrent`.
    public var allowsOverlappingRuns: Bool {
        get { mode == .parallel }
        set {
            if newValue {
                mode = .parallel
                if maxConcurrent < 2 { maxConcurrent = 3 }
            } else if mode == .parallel {
                mode = .serial
            }
        }
    }

    /// The window of a `.window` policy; 0 otherwise. Setting it picks
    /// `.window` (or `.none` at 0).
    public var dedupeWindowSeconds: TimeInterval {
        get {
            if case .window(let seconds) = dedupe { return seconds }
            return 0
        }
        set { dedupe = EventDedupePolicy.normalized(.window(max(0, newValue))) }
    }

    /// `dedupe` wins over `dedupeWindowSeconds` when both are given.
    public init(
        mode: EventDeliveryMode = .serial,
        maxConcurrent: Int = 1,
        maxQueued: Int = 20,
        steerRunningTurn: Bool = true,
        dedupeWindowSeconds: TimeInterval = EventDedupePolicy.defaultWindowSeconds,
        dedupe: EventDedupePolicy? = nil,
        missedFirePolicy: EventMissedFirePolicy = .runOnce,
        queueId: UUID? = nil
    ) {
        self.mode = mode
        self.maxConcurrent = min(max(1, maxConcurrent), Self.maxConcurrentCeiling)
        self.maxQueued = min(max(0, maxQueued), Self.maxQueuedCeiling)
        self.steerRunningTurn = steerRunningTurn
        self.dedupe = EventDedupePolicy.normalized(dedupe ?? .window(max(0, dedupeWindowSeconds)))
        self.missedFirePolicy = missedFirePolicy
        self.queueId = queueId
    }

    private enum CodingKeys: String, CodingKey {
        case mode, maxConcurrent, maxQueued, steerRunningTurn, dedupe, dedupeWindowSeconds, missedFirePolicy, queueId
    }

    /// Files written before `dedupe` existed carry only
    /// `dedupeWindowSeconds`: > 0 is a window, 0 is none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let window =
            try c.decodeIfPresent(TimeInterval.self, forKey: .dedupeWindowSeconds)
            ?? EventDedupePolicy.defaultWindowSeconds
        let dedupe: EventDedupePolicy
        switch try c.decodeIfPresent(EventDedupeMode.self, forKey: .dedupe) {
        case .none?: dedupe = .none
        case .durable?: dedupe = .durable
        case .window?, nil: dedupe = .window(max(0, window))
        }
        self.init(
            mode: try c.decodeIfPresent(EventDeliveryMode.self, forKey: .mode) ?? .serial,
            maxConcurrent: try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 1,
            maxQueued: try c.decodeIfPresent(Int.self, forKey: .maxQueued) ?? 20,
            steerRunningTurn: try c.decodeIfPresent(Bool.self, forKey: .steerRunningTurn) ?? true,
            dedupe: dedupe,
            missedFirePolicy: try c.decodeIfPresent(EventMissedFirePolicy.self, forKey: .missedFirePolicy)
                ?? .runOnce,
            queueId: try c.decodeIfPresent(UUID.self, forKey: .queueId)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(maxConcurrent, forKey: .maxConcurrent)
        try c.encode(maxQueued, forKey: .maxQueued)
        try c.encode(steerRunningTurn, forKey: .steerRunningTurn)
        try c.encode(dedupe.mode, forKey: .dedupe)
        try c.encode(dedupeWindowSeconds, forKey: .dedupeWindowSeconds)
        try c.encode(missedFirePolicy, forKey: .missedFirePolicy)
        try c.encodeIfPresent(queueId, forKey: .queueId)
    }

    /// Defaults per source that keep the behavior each source had before
    /// events: a busy schedule skips its slot, a folder converges in one
    /// loop, a webhook queues, a channel runs one turn per conversation.
    public static func defaults(for kind: EventSourceKind) -> EventDeliveryPolicy {
        kind.descriptor.defaultDelivery
    }
}

public struct EventReplyPolicy: Codable, Equatable, Sendable {
    /// Channel sources: send the agent's reply back to the conversation.
    public var autoReply: Bool
    /// Channel sources with a workflow action: send the workflow's output
    /// back to the conversation.
    public var replyWithWorkflowOutput: Bool

    public init(autoReply: Bool = false, replyWithWorkflowOutput: Bool = false) {
        self.autoReply = autoReply
        self.replyWithWorkflowOutput = replyWithWorkflowOutput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoReply = try c.decodeIfPresent(Bool.self, forKey: .autoReply) ?? false
        replyWithWorkflowOutput = try c.decodeIfPresent(Bool.self, forKey: .replyWithWorkflowOutput) ?? false
    }

    /// Whether this action's result goes back to the conversation.
    public func replies(for action: EventActionKind) -> Bool {
        switch action {
        case .agent: autoReply
        case .workflow: replyWithWorkflowOutput
        case .prompt: false
        }
    }
}

// MARK: - Event

public struct OsaurusEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var source: EventSource
    public var filter: EventFilter
    public var action: EventAction
    public var delivery: EventDeliveryPolicy
    public var reply: EventReplyPolicy
    /// Free-form tags (e.g. `pluginId` for events a Claude plugin installed).
    public var parameters: [String: String]
    public let createdAt: Date
    public var updatedAt: Date
    /// When the event was last selected to run (schedule anchor).
    public var lastFiredAt: Date?
    /// When the last run finished.
    public var lastRunAt: Date?
    public var lastStatus: EventRunStatus?
    public var lastSessionId: UUID?
    public var lastWorkflowRunId: UUID?

    /// Key in `parameters` grouping events by the Claude plugin that
    /// installed them.
    public static let pluginIdParameterKey = "pluginId"

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        source: EventSource,
        filter: EventFilter = EventFilter(),
        action: EventAction,
        delivery: EventDeliveryPolicy? = nil,
        reply: EventReplyPolicy = EventReplyPolicy(),
        parameters: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastFiredAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: EventRunStatus? = nil,
        lastSessionId: UUID? = nil,
        lastWorkflowRunId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.source = source
        self.filter = filter
        self.action = action
        self.delivery = delivery ?? .defaults(for: source.kind)
        self.reply = reply
        self.parameters = parameters
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastFiredAt = lastFiredAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastSessionId = lastSessionId
        self.lastWorkflowRunId = lastWorkflowRunId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        source = try c.decode(EventSource.self, forKey: .source)
        filter = try c.decodeIfPresent(EventFilter.self, forKey: .filter) ?? EventFilter()
        action = try c.decode(EventAction.self, forKey: .action)
        delivery = try c.decodeIfPresent(EventDeliveryPolicy.self, forKey: .delivery) ?? .defaults(for: source.kind)
        reply = try c.decodeIfPresent(EventReplyPolicy.self, forKey: .reply) ?? EventReplyPolicy()
        parameters = try c.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastStatus = try c.decodeIfPresent(EventRunStatus.self, forKey: .lastStatus)
        lastSessionId = try c.decodeIfPresent(UUID.self, forKey: .lastSessionId)
        lastWorkflowRunId = try c.decodeIfPresent(UUID.self, forKey: .lastWorkflowRunId)
    }

    public var sourceKind: EventSourceKind { source.kind }

    /// The agent an agent action runs; nil for workflow actions.
    public var target: AgentDispatchTarget? { action.agent?.target }

    /// The local agent, for readers that only understand local agents.
    public var agentId: UUID? { target?.localId }

    /// Calendar timing for schedule sources.
    public var scheduleTiming: ScheduleTiming? {
        guard let schedule = source.schedule else { return nil }
        return ScheduleTiming(
            frequency: schedule.frequency, isEnabled: isEnabled, lastTriggeredAt: lastFiredAt, lastRunAt: lastRunAt)
    }

    /// Next calendar fire for schedule sources.
    public func nextFireDate(asOf now: Date = Date()) -> Date? {
        scheduleTiming?.nextRunDateAfterExecutionAnchor(asOf: now)
    }

    /// "Today at 9:00 AM" style text for the next schedule fire; nil when
    /// the event is not a schedule, is paused, or has no future slot.
    public var nextRunDescription: String? {
        guard isEnabled, let next = nextFireDate() else { return nil }
        return Self.relativeDescription(of: next)
    }

    static func relativeDescription(of date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return L("Today at \(time)") }
        if calendar.isDateInTomorrow(date) { return L("Tomorrow at \(time)") }
        let days = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// One-line description of what fires the event.
    public var sourceSummary: String {
        switch source {
        case .schedule(let s): return s.frequency.displayDescription
        case .folder(let f): return f.displayPath
        case .webhook(let w):
            return w.provider == .generic ? "POST /events/…" : "\(w.provider.displayName) · POST /events/…"
        case .rss(let r): return r.feedURL?.host ?? (r.url.isEmpty ? L("No feed URL") : r.url)
        case .sse(let s): return s.streamURL?.host ?? (s.url.isEmpty ? L("No stream URL") : s.url)
        case .runFailed(let f):
            let workflows: String
            switch f.workflowIDs.count {
            case 0: workflows = L("Any workflow fails")
            case 1: workflows = L("1 workflow fails")
            default: workflows = L("\(f.workflowIDs.count) workflows fail")
            }
            return f.includeAutomationRuns ? workflows + " · " + L("or an automation") : workflows
        case .app(let a):
            return a.reasons.isEmpty ? L("No app events chosen") : a.reasons.map(\.displayName).joined(separator: ", ")
        case .email(let e): return e.effectiveMailboxes.map(EmailMailboxName.display).joined(separator: ", ")
        case .channelMessage(let m):
            let platform = m.kind.displayName
            if m.roomIds.isEmpty { return platform }
            return "\(platform) · " + m.roomIds.joined(separator: ", ")
        }
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
