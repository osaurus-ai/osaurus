//
//  ConfigEvents.swift
//  osaurus
//
//  The `automations` section: one entry per schedule, folder watcher,
//  webhook, feed, event stream, run-failed handler or app event (source +
//  filter + action + delivery), matched to existing
//  automations by name. Channel rules (`channels.<platform>.routing`) are
//  the same events and go through the same `ConfigEvents.build`, scoped
//  to their channel (see ConfigChannelRouting.swift), so a document is
//  validated exactly the way it will be stored.
//
//  Legacy input is still accepted: `schedules:` and `watchers:` entries
//  become `automations` entries, and `channels.<platform>.inbound_*` keys
//  and `channel_message` automations become `channels.<platform>.routing`
//  rules (each with a deprecation note in the plan) before validation.
//
//  Webhook URL tokens and secrets never appear in a document: a created
//  webhook automation gets a fresh token (and secret), shown in the
//  Automations tab.
//

import Foundation

// MARK: - Document entries

public struct EventSourceEntry: Codable, Equatable, Sendable {
    /// One of: schedule, folder, webhook, rss, sse, run_failed, app, email,
    /// channel_message.
    public var kind: String?
    // schedule
    public var frequency: String?
    public var frequencyValue: String?
    public var frequencyTimeOfDay: String?
    // folder
    public var path: String?
    public var recursive: Bool?
    public var responsiveness: String?
    // webhook
    /// generic (default) or a known sender: github, stripe, slack, shopify,
    /// twilio, microsoft_graph, facebook, sns. A known sender is checked
    /// its own way, so `verification` and the signature keys do not apply.
    public var provider: String?
    public var verification: String?
    public var signatureHeader: String?
    public var signaturePrefix: String?
    public var maxBodyBytes: Int?
    public var rateLimitPerMinute: Int?
    /// An example of what the sender posts. Its fields become trigger values
    /// (`{{webhook.body.<field>}}`); Run Now sends it.
    public var sampleBody: String?
    // email (retired: such entries are ignored with a note pointing at
    // `channels.email`; still decoded so old documents parse)
    public var mailboxes: [String]?
    public var unreadOnly: Bool?
    public var includeBody: Bool?
    public var maxBodyChars: Int?
    /// email, rss.
    public var pollIntervalSeconds: Int?
    /// since_cursor | latest_only | skip (email, rss)
    public var catchUp: String?
    // rss, sse
    public var url: String?
    // rss
    public var maxItemsPerTick: Int?
    // sse
    public var headers: [String: String]?
    public var eventNames: [String]?
    /// 0 turns the heartbeat check off.
    public var heartbeatTimeoutSeconds: Int?
    // run_failed
    /// Installed workflow names; absent or empty = any workflow.
    public var workflows: [String]?
    public var includeAutomationRuns: Bool?
    // app
    /// app_launched | automation_enabled | automation_updated
    public var reasons: [String]?
    // channel_message
    public var platform: String?
    /// channel_message: n8n / custom HTTP connection; email: the mail
    /// account. A name or id; native platforms omit it.
    public var connection: String?
    public var rooms: [String]?
    public var aliases: [String]?
    public var requireMention: Bool?
    public var continueThreads: Bool?

    public init(kind: String? = nil) {
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case kind, frequency
        case frequencyValue = "frequency_value"
        case frequencyTimeOfDay = "frequency_time_of_day"
        case path, recursive, responsiveness, provider, verification
        case signatureHeader = "signature_header"
        case signaturePrefix = "signature_prefix"
        case maxBodyBytes = "max_body_bytes"
        case rateLimitPerMinute = "rate_limit_per_minute"
        case sampleBody = "sample_body"
        case mailboxes
        case unreadOnly = "unread_only"
        case includeBody = "include_body"
        case maxBodyChars = "max_body_chars"
        case pollIntervalSeconds = "poll_interval_seconds"
        case catchUp = "catch_up"
        case url
        case maxItemsPerTick = "max_items_per_tick"
        case headers
        case eventNames = "event_names"
        case heartbeatTimeoutSeconds = "heartbeat_timeout_seconds"
        case workflows
        case includeAutomationRuns = "include_automation_runs"
        case reasons
        case platform, connection, rooms, aliases
        case requireMention = "require_mention"
        case continueThreads = "continue_threads"
    }
}

public struct EventFilterEntry: Codable, Equatable, Sendable {
    public var senders: [String]?
    public var keywordsAny: [String]?
    public var keywordsAll: [String]?
    public var pathGlobs: [String]?
    /// Payload dot path → required value (`webhook.body.action: opened`).
    public var conditions: [String: String]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case senders
        case keywordsAny = "keywords_any"
        case keywordsAll = "keywords_all"
        case pathGlobs = "path_globs"
        case conditions
    }
}

public struct EventDeliveryEntry: Codable, Equatable, Sendable {
    /// The task queue fires wait on: a queue slug or name; `default` (or
    /// absent) is the Default queue.
    public var queue: String?
    /// The editor's **Allow overlapping runs**. Wins over `mode` when both
    /// are given: true overlaps (ordered per conversation for sources that
    /// have conversations), false runs one at a time.
    public var allowOverlappingRuns: Bool?
    /// One of: serial, per_conversation, parallel.
    public var mode: String?
    public var maxConcurrent: Int?
    public var maxQueued: Int?
    public var steerRunningTurn: Bool?
    /// One of: none, window, durable. Absent keeps the stored mode.
    public var dedupe: String?
    /// Only for `window`.
    public var dedupeWindowSeconds: Int?
    /// Schedules: run_once | skip.
    public var missedFire: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case queue
        case allowOverlappingRuns = "allow_overlapping_runs"
        case mode
        case maxConcurrent = "max_concurrent"
        case maxQueued = "max_queued"
        case steerRunningTurn = "steer_running_turn"
        case dedupe
        case dedupeWindowSeconds = "dedupe_window_seconds"
        case missedFire = "missed_fire"
    }
}

public struct EventReplyEntry: Codable, Equatable, Sendable {
    public var autoReply: Bool?
    public var workflowOutput: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case autoReply = "auto_reply"
        case workflowOutput = "workflow_output"
    }
}

/// One event. Matched by `name` (case-insensitive). Exactly one of
/// `agent` / `workflow` names the action.
public struct EventEntry: Codable, Equatable, Sendable {
    public var name: String
    public var enabled: Bool?
    public var source: EventSourceEntry?
    public var filter: EventFilterEntry?
    /// Custom agent name (never "default"), or a shared workspace agent as
    /// `<workspaceId>:<0x-address>`.
    public var agent: String?
    public var instructions: String?
    /// Working folder path for agent runs (hint; a bookmark is minted on
    /// apply when the folder is reachable).
    public var workingFolder: String?
    public var freshSession: Bool?
    /// Installed workflow name.
    public var workflow: String?
    /// Workflow input field → template (`{{message.text}}`).
    public var input: [String: String]?
    /// With `instructions` and no agent or workflow: the model that
    /// answers. Omitted = the default model for new agents.
    public var model: String?
    public var delivery: EventDeliveryEntry?
    public var reply: EventReplyEntry?
    /// Routing rules' `replies` (automatic | approval | none). Not a document
    /// key here: it is mapped onto `reply` once the action is known.
    var replies: String?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, enabled, source, filter, agent, instructions
        case workingFolder = "working_folder"
        case freshSession = "fresh_session"
        case workflow, input, model, delivery, reply
    }
}

// MARK: - Build / export

@MainActor
enum ConfigEvents {
    /// Resolves an `agent` value; nil = unknown.
    typealias AgentResolver = (String) -> AgentDispatchTarget?
    /// Resolves a `workflow` value (name or id); nil = unknown.
    typealias WorkflowResolver = (String) -> UUID?

    static let section = "automations"

    // MARK: Export

    /// Every automation but channel rules, which export under
    /// `channels` (`ConfigChannelRouting.export`).
    static func export(_ events: [OsaurusEvent] = EventManager.shared.events) -> [EventEntry] {
        events.filter(ConfigEventScope.automations.owns)
            .sorted { $0.name.lowercased() < $1.name.lowercased() }.map(export)
    }

    static func export(_ event: OsaurusEvent) -> EventEntry {
        var entry = EventEntry(name: event.name)
        entry.enabled = event.isEnabled
        var source = EventSourceEntry(kind: event.sourceKind.rawValue)
        switch event.source {
        case .schedule(let s):
            let parts = ConfigScheduleFrequency.components(of: s.frequency)
            source.frequency = parts.frequency
            source.frequencyValue = parts.value
            source.frequencyTimeOfDay = parts.timeOfDay
        case .folder(let f):
            source.path = f.path
            source.recursive = f.recursive
            source.responsiveness = f.responsiveness.rawValue
        case .webhook(let w):
            if w.provider == .generic {
                source.verification = w.verification.rawValue
                source.signatureHeader = w.signatureHeader
                source.signaturePrefix = w.signaturePrefix
            } else {
                source.provider = w.provider.rawValue
            }
            source.maxBodyBytes = w.maxBodyBytes
            source.rateLimitPerMinute = w.rateLimitPerMinute
            source.sampleBody = w.sampleBody
        case .email(let e):
            source.connection = SourceConnectionStore.shared.connection(id: e.connectionId)?.displayName ?? e.connectionId
            source.mailboxes = e.effectiveMailboxes
            source.unreadOnly = e.unreadOnly
            source.includeBody = e.includeBody
            source.maxBodyChars = e.maxBodyChars
            source.pollIntervalSeconds = e.pollIntervalSeconds
            source.catchUp = e.catchUp.rawValue
        case .rss(let r):
            source.url = r.url
            source.pollIntervalSeconds = r.pollIntervalSeconds
            source.catchUp = r.catchUp.rawValue
            source.maxItemsPerTick = r.maxItemsPerTick
        case .sse(let s):
            source.url = s.url
            source.headers = s.headers.isEmpty ? nil : s.headers
            source.eventNames = s.eventNames.nilIfEmpty
            source.heartbeatTimeoutSeconds = s.heartbeatTimeoutSeconds
        case .runFailed(let f):
            source.workflows = f.workflowIDs.map {
                InstalledWorkflowStore.shared.workflow(id: $0)?.name ?? $0.uuidString
            }.nilIfEmpty
            source.includeAutomationRuns = f.includeAutomationRuns
        case .app(let a):
            source.reasons = a.reasons.map(\.rawValue)
        case .channelMessage(let m):
            source.platform = m.kind.rawValue
            if let native = ChannelMessageSourceConfig.nativeConnectionId(for: m.kind) {
                if AgentChannelConnection.normalizedId(m.connectionId) != native { source.connection = m.connectionId }
            } else {
                source.connection = connectionName(m.connectionId)
            }
            source.rooms = m.roomIds
            source.aliases = m.aliases
            source.requireMention = m.requireMention
            source.continueThreads = m.continueThreads
        }
        entry.source = source

        if !event.filter.isEmpty {
            var filter = EventFilterEntry()
            filter.senders = event.filter.senderAllowlist.nilIfEmpty
            filter.keywordsAny = event.filter.keywordsAny.nilIfEmpty
            filter.keywordsAll = event.filter.keywordsAll.nilIfEmpty
            filter.pathGlobs = event.filter.pathGlobs.nilIfEmpty
            if !event.filter.conditions.isEmpty {
                filter.conditions = Dictionary(
                    event.filter.conditions.map { ($0.path, $0.equals) }, uniquingKeysWith: { first, _ in first })
            }
            entry.filter = filter
        }

        switch event.action {
        case .agent(let a):
            entry.agent = ConfigAgentTargetReference.export(a.target)
            entry.instructions = a.instructions
            entry.workingFolder = a.folderPath
            entry.freshSession = a.freshSessionPerFire
        case .workflow(let w):
            entry.workflow =
                InstalledWorkflowStore.shared.workflow(id: w.workflowID)?.name ?? w.workflowID.uuidString
            entry.input = w.inputMapping.isEmpty ? nil : w.inputMapping
        case .prompt(let p):
            entry.instructions = p.instructions
            entry.model = p.model
        }

        var delivery = EventDeliveryEntry()
        if let queueId = event.delivery.queueId, queueId != TaskQueue.defaultID,
            let queue = TaskStore.shared.queue(id: queueId)
        {
            delivery.queue = queue.slug
        }
        delivery.mode = event.delivery.mode.rawValue
        delivery.maxConcurrent = event.delivery.maxConcurrent
        delivery.maxQueued = event.delivery.maxQueued
        delivery.steerRunningTurn = event.delivery.steerRunningTurn
        delivery.dedupe = event.delivery.dedupe.mode.rawValue
        if case .window(let seconds) = event.delivery.dedupe { delivery.dedupeWindowSeconds = Int(seconds) }
        if event.sourceKind == .schedule { delivery.missedFire = event.delivery.missedFirePolicy.rawValue }
        entry.delivery = delivery

        if event.sourceKind == .channelMessage {
            var reply = EventReplyEntry()
            reply.autoReply = event.reply.autoReply
            reply.workflowOutput = event.reply.replyWithWorkflowOutput
            entry.reply = reply
        }
        return entry
    }

    // MARK: Build

    static func retiredEmailNote(names: [String]) -> String {
        "`automations` entries with `source.kind: email` are retired and were ignored ("
            + names.map { "`\($0)`" }.joined(separator: ", ")
            + "). Mail now reaches agents through the Email channel: list mailboxes in "
            + "`channels.email.read_allowlist` (`<mail account id>/<mailbox>`), senders in "
            + "`channels.email.sender_allowlist`, and who answers in `channels.email.routing`."
    }

    struct BuildOutcome {
        var event: OsaurusEvent
        /// Non-fatal notes for the apply result (folder access, new webhook).
        var notes: [String] = []
        var needsUserAction = false
    }

    /// The event `entry` describes, patched over `existing` (absent keys
    /// keep the stored value). A different source kind replaces the source.
    static func build(
        _ entry: EventEntry,
        existing: OsaurusEvent?,
        resolveAgent: AgentResolver,
        resolveWorkflow: WorkflowResolver,
        workflowInputSchema: ((UUID) -> JSONValue?)? = nil,
        resolveModel: ((String) -> ConfigModelReference.Resolution)? = nil,
        mintBookmarks: Bool,
        path: String = "automations"
    ) -> Result<BuildOutcome, ConfigEventError> {
        let label = "\(path)[\(entry.name)]"
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.init("automations[]: every automation needs a non-empty name.")) }
        var notes: [String] = []
        var needsUserAction = false

        // Source
        let source: EventSource
        let rawKind = entry.source?.kind?.lowercased()
        let kind: EventSourceKind
        if let rawKind {
            guard let parsed = EventSourceKind(rawValue: rawKind) else {
                return .failure(
                    .init(
                        "\(label).source.kind: must be one of: "
                            + EventSourceKind.allCases.map(\.rawValue).joined(separator: ", ") + "."))
            }
            kind = parsed
        } else if let existing {
            kind = existing.sourceKind
        } else {
            return .failure(.init("\(label): `source.kind` is required to create an automation."))
        }
        let base = existing?.sourceKind == kind ? existing?.source : nil
        let sourceEntry = entry.source ?? EventSourceEntry()
        switch kind {
        case .schedule:
            var config = base?.schedule
            if let frequency = sourceEntry.frequency {
                switch ConfigScheduleFrequency.parse(
                    frequency: frequency, value: sourceEntry.frequencyValue, timeOfDay: sourceEntry.frequencyTimeOfDay)
                {
                case .success(let parsed): config = ScheduleSourceConfig(frequency: parsed)
                case .failure(let error): return .failure(.init("\(label).source: \(error.message)"))
                }
            }
            guard let config else {
                return .failure(.init("\(label).source: `frequency` is required for a schedule automation."))
            }
            source = .schedule(config)
        case .folder:
            var config = base?.folder ?? FolderSourceConfig()
            if let raw = sourceEntry.path {
                let expanded = (raw as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                // Existence gates a new path only, so an export whose folder
                // went missing still re-applies.
                if config.path != expanded,
                    !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
                        || !isDirectory.boolValue
                {
                    return .failure(.init("\(label).source.path: `\(expanded)` is not an existing directory."))
                }
                if config.path != expanded || config.bookmark == nil {
                    config.path = expanded
                    config.bookmark =
                        mintBookmarks
                        ? FolderContextService.makeSecurityScopedBookmark(
                            for: URL(fileURLWithPath: expanded, isDirectory: true))
                        : nil
                    if mintBookmarks, config.bookmark == nil {
                        notes.append(
                            "Uses a plain folder path — if macOS blocks access, re-pick the folder in the Automations tab.")
                    }
                }
            }
            guard config.path != nil else {
                return .failure(.init("\(label).source: `path` is required for a folder automation."))
            }
            if let v = sourceEntry.recursive { config.recursive = v }
            if let raw = sourceEntry.responsiveness {
                guard let value = Responsiveness(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init(
                            "\(label).source.responsiveness: must be one of: "
                                + Responsiveness.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                }
                config.responsiveness = value
            }
            source = .folder(config)
        case .webhook:
            var config = base?.webhook ?? WebhookSourceConfig()
            if let raw = sourceEntry.provider {
                guard let value = WebhookProvider(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init(
                            "\(label).source.provider: must be one of: "
                                + WebhookProvider.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                }
                config.provider = value
            }
            if config.provider != .generic,
                sourceEntry.verification != nil || sourceEntry.signatureHeader != nil
                    || sourceEntry.signaturePrefix != nil
            {
                return .failure(
                    .init(
                        "\(label).source: \(config.provider.displayName) webhooks are checked the provider's way — "
                            + "remove `verification`, `signature_header` and `signature_prefix`."))
            }
            if let raw = sourceEntry.verification {
                guard let value = WebhookVerificationMethod(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init("\(label).source.verification: must be one of: none, shared_secret_header, hmac_sha256."))
                }
                config.verification = value
            }
            if let v = sourceEntry.signatureHeader { config.signatureHeader = v.isEmpty ? nil : v }
            if let v = sourceEntry.signaturePrefix { config.signaturePrefix = v }
            if let v = sourceEntry.maxBodyBytes {
                guard (1 ... 10 * 1024 * 1024).contains(v) else {
                    return .failure(.init("\(label).source.max_body_bytes: must be in 1...10485760."))
                }
                config.maxBodyBytes = v
            }
            if let v = sourceEntry.rateLimitPerMinute {
                guard (1 ... 600).contains(v) else {
                    return .failure(.init("\(label).source.rate_limit_per_minute: must be in 1...600."))
                }
                config.rateLimitPerMinute = v
            }
            if let v = sourceEntry.sampleBody {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.utf8.count <= config.maxBodyBytes else {
                    return .failure(.init("\(label).source.sample_body: longer than max_body_bytes."))
                }
                config.sampleBody = trimmed.isEmpty ? nil : trimmed
            }
            let profile = WebhookProviderProfile.profile(for: config)
            if profile.secretIssuedByProvider, existing?.source.webhook?.provider != config.provider {
                notes.append(
                    "Copy the webhook URL into \(config.provider.displayName), then paste the signing secret it shows "
                        + "into this automation in the Automations tab.")
                needsUserAction = true
            } else if existing?.source.webhook == nil {
                notes.append("Copy the webhook URL\(profile.verifier.checksSecret ? " and secret" : "") from the Automations tab.")
            }
            source = .webhook(config)
        case .rss:
            var config = base?.rss ?? RSSSourceConfig()
            if let raw = sourceEntry.url {
                guard TriggerSourceURL.parse(raw) != nil else {
                    return .failure(.init("\(label).source.url: must be an http(s) feed URL."))
                }
                config.url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard config.feedURL != nil else {
                return .failure(.init("\(label).source: `url` is required for an rss automation."))
            }
            if let v = sourceEntry.pollIntervalSeconds {
                let range = RSSSourceConfig.pollIntervalRange
                guard range.contains(v) else {
                    return .failure(
                        .init("\(label).source.poll_interval_seconds: must be in \(range.lowerBound)...\(range.upperBound)."))
                }
                config.pollIntervalSeconds = v
            }
            if let raw = sourceEntry.catchUp {
                guard let value = SourceCatchUpPolicy(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init(
                            "\(label).source.catch_up: must be one of: "
                                + SourceCatchUpPolicy.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                }
                config.catchUp = value
            }
            if let v = sourceEntry.maxItemsPerTick {
                let range = RSSSourceConfig.maxItemsPerTickRange
                guard range.contains(v) else {
                    return .failure(
                        .init("\(label).source.max_items_per_tick: must be in \(range.lowerBound)...\(range.upperBound)."))
                }
                config.maxItemsPerTick = v
            }
            source = .rss(config)
        case .sse:
            var config = base?.sse ?? SSESourceConfig()
            if let raw = sourceEntry.url {
                guard TriggerSourceURL.parse(raw) != nil else {
                    return .failure(.init("\(label).source.url: must be an http(s) URL."))
                }
                config.url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard config.streamURL != nil else {
                return .failure(.init("\(label).source: `url` is required for an sse automation."))
            }
            if let v = sourceEntry.heartbeatTimeoutSeconds {
                let range = SSESourceConfig.heartbeatTimeoutRange
                guard v == 0 || range.contains(v) else {
                    return .failure(
                        .init(
                            "\(label).source.heartbeat_timeout_seconds: must be 0 (off) or in "
                                + "\(range.lowerBound)...\(range.upperBound)."))
                }
                config.heartbeatTimeoutSeconds = v == 0 ? nil : v
            }
            config = SSESourceConfig(
                url: config.url, headers: sourceEntry.headers ?? config.headers,
                eventNames: sourceEntry.eventNames ?? config.eventNames,
                heartbeatTimeoutSeconds: config.heartbeatTimeoutSeconds)
            source = .sse(config)
        case .runFailed:
            var config = base?.runFailed ?? RunFailedSourceConfig()
            if let names = sourceEntry.workflows {
                var ids: [UUID] = []
                for raw in names {
                    guard let id = resolveWorkflow(raw) else {
                        return .failure(
                            .init(
                                "\(label).source.workflows: "
                                    + (AgentWrapperCatalog.configRefusal(raw)
                                        ?? "no installed workflow named `\(raw)`.")))
                    }
                    ids.append(id)
                }
                config = RunFailedSourceConfig(workflowIDs: ids, includeAutomationRuns: config.includeAutomationRuns)
            }
            if let v = sourceEntry.includeAutomationRuns { config.includeAutomationRuns = v }
            source = .runFailed(config)
        case .app:
            var config = base?.app ?? AppEventsSourceConfig()
            if let raws = sourceEntry.reasons {
                var reasons: [AppEventReason] = []
                for raw in raws {
                    guard let reason = AppEventReason(rawValue: raw.lowercased()) else {
                        return .failure(
                            .init(
                                "\(label).source.reasons: `\(raw)` is not one of: "
                                    + AppEventReason.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                    }
                    reasons.append(reason)
                }
                guard !reasons.isEmpty else {
                    return .failure(.init("\(label).source.reasons: pick at least one."))
                }
                config = AppEventsSourceConfig(reasons: reasons)
            }
            source = .app(config)
        case .email:
            return .failure(.init("\(label).source: \(retiredEmailNote(names: [entry.name]))"))
        case .channelMessage:
            let current = base?.channelMessage
            let platform: AgentChannelKind
            if let raw = sourceEntry.platform {
                guard let value = AgentChannelKind(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init(
                            "\(label).source.platform: must be one of: "
                                + AgentChannelKind.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                }
                platform = value
            } else if let current {
                platform = current.kind
            } else {
                return .failure(.init("\(label).source: `platform` is required for a channel_message automation."))
            }
            var connectionId = current?.kind == platform ? current?.connectionId : nil
            if let native = ChannelMessageSourceConfig.nativeConnectionId(for: platform) {
                if let raw = sourceEntry.connection {
                    guard let id = resolveAccountId(named: raw, kind: platform, primary: native) else {
                        return .failure(
                            .init(
                                "\(label).source.connection: no \(platform.displayName) account `\(raw)` — "
                                    + "agent_channel_list_connections lists the account ids."))
                    }
                    connectionId = id
                } else if connectionId.flatMap({ ChannelAccounts.account(connectionId: $0) })?.kind != platform {
                    connectionId = native
                }
            } else if let raw = sourceEntry.connection {
                guard let id = resolveConnectionId(named: raw, kind: platform) else {
                    return .failure(
                        .init("\(label).source.connection: no \(platform.displayName) connection named `\(raw)`."))
                }
                connectionId = id
            }
            guard let connectionId else {
                return .failure(
                    .init("\(label).source: `connection` is required for a \(platform.displayName) automation."))
            }
            let keep = current?.kind == platform ? current : nil
            source = .channelMessage(
                ChannelMessageSourceConfig(
                    kind: platform,
                    connectionId: connectionId,
                    roomIds: sourceEntry.rooms ?? keep?.roomIds ?? [],
                    aliases: sourceEntry.aliases ?? keep?.aliases ?? [],
                    requireMention: (sourceEntry.requireMention ?? keep?.requireMention)
                        .map { $0 && ChannelMessageSourceConfig.supportsMentions(platform) },
                    continueThreads: sourceEntry.continueThreads ?? keep?.continueThreads ?? true
                ))
        }

        // Action
        if entry.agent != nil && entry.workflow != nil {
            return .failure(.init("\(label): set `agent` or `workflow`, not both."))
        }
        if entry.model != nil, entry.agent != nil || entry.workflow != nil {
            return .failure(
                .init(
                    "\(label).model: only an automation with `instructions` alone (no agent or workflow) takes "
                        + "`model`; an agent uses its own model."))
        }
        // `instructions` alone (or with `model`) asks a model with no tools,
        // unless it edits an existing agent automation's instructions.
        let asksModel =
            entry.agent == nil && entry.workflow == nil
            && (entry.model != nil || (entry.instructions != nil && existing?.action.agent == nil)
                || existing?.action.prompt != nil)
        let action: EventAction
        if asksModel {
            guard kind != .channelMessage else {
                return .failure(
                    .init(
                        "\(label): a channel rule runs an agent or a workflow; set `agent` or `workflow` "
                            + "(channels.<platform>.routing)."))
            }
            for (key, present) in [
                ("input", entry.input != nil), ("working_folder", entry.workingFolder != nil),
                ("fresh_session", entry.freshSession != nil),
            ] where present {
                return .failure(
                    .init("\(label).\(key): an `instructions`-only automation takes `instructions` and `model` only."))
            }
            var prompt = existing?.action.prompt ?? PromptEventAction()
            if let v = entry.instructions { prompt.instructions = v }
            if let raw = entry.model {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    prompt.model = nil
                } else if trimmed.caseInsensitiveCompare(prompt.model ?? "") != .orderedSame {
                    let resolution =
                        resolveModel?(trimmed)
                        ?? ConfigModelReference.resolve(trimmed, catalog: ConfigModelReference.liveCatalog())
                    switch resolution {
                    case .resolved(let canonical): prompt.model = canonical
                    case .invalid(let message): return .failure(.init("\(label).model: \(message)"))
                    }
                }
            }
            if prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.init("\(label): `instructions` is required: what to ask the model."))
            }
            action = .prompt(prompt)
        } else if let raw = entry.workflow {
            guard let id = resolveWorkflow(raw) else {
                return .failure(
                    .init(
                        "\(label).workflow: "
                            + (AgentWrapperCatalog.configRefusal(raw) ?? "no installed workflow named `\(raw)`.")))
            }
            let previous = existing?.action.workflow
            let kept = previous?.workflowID == id ? previous?.inputMapping : nil
            let schema = workflowInputSchema?(id) ?? liveWorkflowInputSchema(id)
            // A new binding starts from the same prefill the editor offers:
            // the trigger's natural values and required defaults.
            var mapping = entry.input ?? kept ?? [:]
            if entry.input == nil, kept == nil, let schema {
                mapping = WorkflowInputBinding.prefill(schema: schema, sourceKind: kind)
            } else if entry.input != nil, let schema {
                // Like the editor: a required input the document leaves out
                // takes its schema default.
                mapping.merge(WorkflowInputBinding.requiredDefaults(schema: schema)) { kept, _ in kept }
            }
            // The executor applies no defaults, so an unbound required input
            // fails every run. Checked when the binding changes, so an
            // export of an older automation still re-applies.
            if let schema, entry.input != nil || kept == nil {
                let missing = WorkflowInputBinding.missingRequired(
                    fields: WorkflowFormFields.fields(fromInputSchema: schema), mapping: mapping)
                if !missing.isEmpty {
                    let values = EventTriggerValues.catalog(for: kind).prefix(3).map { "\"\($0.template)\"" }
                    return .failure(
                        .init(
                            "\(label).input: workflow `\(raw)` needs "
                                + missing.map { "`\($0.key)`" }.joined(separator: ", ")
                                + " — bind each to a trigger value (\(values.joined(separator: ", "))) or a fixed value."))
                }
            }
            action = .workflow(
                WorkflowEventAction(workflowID: id, inputMapping: mapping, runAsAgentId: previous?.runAsAgentId))
        } else if entry.agent != nil || entry.instructions != nil || entry.workingFolder != nil
            || entry.freshSession != nil || existing?.action.agent != nil || existing == nil
        {
            guard entry.input == nil else {
                return .failure(.init("\(label).input: only workflow automations take `input`."))
            }
            var agentAction = existing?.action.agent ?? AgentEventAction(freshSessionPerFire: AgentEventAction.defaultFreshSession(for: kind))
            if let raw = entry.agent {
                if raw.lowercased() == "default" {
                    return .failure(
                        .init(
                            "\(label).agent: automations cannot run the Default agent. Leave `agent` out so "
                                + "`instructions` run as one tool-less model answer, or bind an installed `workflow`."))
                }
                guard let target = resolveAgent(raw) else {
                    return .failure(
                        .init(
                            "\(label).agent: no custom agent named `\(raw)` exists or is created by this document. "
                                + "Name an existing agent (osaurus_inspect list agents), bind an installed "
                                + "`workflow` instead, or leave `agent` out so `instructions` run as one tool-less "
                                + "model answer."))
                }
                agentAction.target = target
            }
            if agentAction.target == nil {
                return .failure(.init("\(label): \(actionRequiredMessage)"))
            }
            if let v = entry.instructions { agentAction.instructions = v }
            if let v = entry.freshSession { agentAction.freshSessionPerFire = v }
            if let raw = entry.workingFolder {
                let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
                if expanded.isEmpty {
                    agentAction.folderPath = nil
                    agentAction.folderBookmark = nil
                } else if agentAction.folderPath != expanded || agentAction.folderBookmark == nil {
                    agentAction.folderPath = expanded
                    agentAction.folderBookmark =
                        mintBookmarks
                        ? FolderContextService.makeSecurityScopedBookmark(
                            for: URL(fileURLWithPath: expanded, isDirectory: true))
                        : nil
                    if mintBookmarks, agentAction.folderBookmark == nil {
                        notes.append(
                            "working_folder: `\(raw)` is not accessible here. Pick the folder in the Automations tab.")
                        needsUserAction = true
                    }
                }
            }
            // Channel messages carry their own text; instructions are optional context.
            if kind != .channelMessage,
                agentAction.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return .failure(.init("\(label): `instructions` is required for an agent automation."))
            }
            action = .agent(agentAction)
        } else if let existing {
            action = existing.action
        } else {
            return .failure(.init("\(label): \(actionRequiredMessage)"))
        }

        // Filter
        var filter = existing?.filter ?? EventFilter()
        if let f = entry.filter {
            filter = EventFilter(
                senderAllowlist: f.senders ?? filter.senderAllowlist,
                keywordsAny: f.keywordsAny ?? filter.keywordsAny,
                keywordsAll: f.keywordsAll ?? filter.keywordsAll,
                pathGlobs: f.pathGlobs ?? filter.pathGlobs,
                conditions: f.conditions.map { map in
                    map.sorted { $0.key < $1.key }.map { EventCondition(path: $0.key, equals: $0.value) }
                } ?? filter.conditions
            )
        }

        // Delivery
        var delivery = existing?.sourceKind == kind ? existing!.delivery : EventDeliveryPolicy.defaults(for: kind)
        if let d = entry.delivery {
            var mode = delivery.mode
            if let raw = d.mode {
                guard let value = EventDeliveryMode(rawValue: raw.lowercased()) else {
                    return .failure(.init("\(label).delivery.mode: must be one of: serial, per_conversation, parallel."))
                }
                mode = value
            }
            if let overlap = d.allowOverlappingRuns {
                mode = overlap ? (kind.descriptor.usesConversationSessions ? .perConversation : .parallel) : .serial
            }
            var queueId = delivery.queueId
            if let raw = d.queue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                guard let queue = TaskStore.shared.queue(named: raw) else {
                    return .failure(
                        .init(
                            "\(label).delivery.queue: no queue named '\(raw)'. Queues: "
                                + TaskStore.shared.queues.map(\.slug).joined(separator: ", ") + "."))
                }
                queueId = queue.id == TaskQueue.defaultID ? nil : queue.id
            }
            var missed = delivery.missedFirePolicy
            if let raw = d.missedFire {
                guard let value = EventMissedFirePolicy(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init("\(label).delivery.missed_fire: must be one of: run_once, skip, run_catchup."))
                }
                missed = value
            }
            if let v = d.maxConcurrent, !(1 ... EventDeliveryPolicy.maxConcurrentCeiling).contains(v) {
                return .failure(
                    .init("\(label).delivery.max_concurrent: must be in 1...\(EventDeliveryPolicy.maxConcurrentCeiling)."))
            }
            if let v = d.maxQueued, !(0 ... EventDeliveryPolicy.maxQueuedCeiling).contains(v) {
                return .failure(
                    .init("\(label).delivery.max_queued: must be in 0...\(EventDeliveryPolicy.maxQueuedCeiling)."))
            }
            if let v = d.dedupeWindowSeconds, !(0 ... 86400).contains(v) {
                return .failure(.init("\(label).delivery.dedupe_window_seconds: must be in 0...86400."))
            }
            var dedupe = delivery.dedupe
            let window = d.dedupeWindowSeconds.map(TimeInterval.init)
            if let raw = d.dedupe {
                guard let value = EventDedupeMode(rawValue: raw.lowercased()) else {
                    return .failure(
                        .init(
                            "\(label).delivery.dedupe: must be one of: "
                                + EventDedupeMode.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                }
                if value != .window, window != nil {
                    return .failure(.init("\(label).delivery.dedupe_window_seconds: only applies with `dedupe: window`."))
                }
                switch value {
                case .none: dedupe = .none
                case .durable: dedupe = .durable
                case .window:
                    let current = delivery.dedupeWindowSeconds
                    dedupe = .window(window ?? (current > 0 ? current : EventDedupePolicy.defaultWindowSeconds))
                }
            } else if let window {
                // Documents from before `dedupe`: the window alone, 0 = none.
                dedupe = .window(window)
            }
            delivery = EventDeliveryPolicy(
                mode: mode,
                maxConcurrent: d.maxConcurrent ?? delivery.maxConcurrent,
                maxQueued: d.maxQueued ?? delivery.maxQueued,
                steerRunningTurn: d.steerRunningTurn ?? delivery.steerRunningTurn,
                dedupe: dedupe,
                missedFirePolicy: missed,
                queueId: queueId
            )
        }

        // Reply
        // A new rule holds replies for approval until the document says
        // `replies: automatic` (a flagged risk).
        var reply = existing?.reply ?? EventReplyPolicy()
        if let r = entry.reply {
            guard kind == .channelMessage else {
                return .failure(.init("\(label).reply: only channel_message automations reply."))
            }
            if let v = r.autoReply { reply.autoReply = v }
            if let v = r.workflowOutput { reply.replyWithWorkflowOutput = v }
        }
        if let raw = entry.replies?.lowercased() {
            switch (action.kind, raw) {
            case (.agent, "automatic"): reply.autoReply = true
            case (.agent, "approval"): reply.autoReply = false
            case (.workflow, "automatic"): reply.replyWithWorkflowOutput = true
            case (.workflow, "none"): reply.replyWithWorkflowOutput = false
            case (.agent, _):
                return .failure(.init("\(label).replies: an agent's reply is `automatic` or `approval`."))
            case (.workflow, _):
                return .failure(.init("\(label).replies: a workflow's output is posted (`automatic`) or not (`none`)."))
            case (.prompt, _):
                return .failure(.init("\(label).replies: only a channel rule's agent or workflow replies."))
            }
        }

        var event =
            existing
            ?? OsaurusEvent(name: name, source: source, action: action, delivery: delivery)
        event.name = name
        event.source = source
        event.action = action
        event.filter = filter
        event.delivery = delivery
        event.reply = reply
        if let v = entry.enabled { event.isEnabled = v }
        return .success(BuildOutcome(event: event, notes: notes, needsUserAction: needsUserAction))
    }

    static let actionRequiredMessage =
        "an automation needs one action: `workflow` (an installed workflow, with `input`), `instructions` alone "
        + "(one tool-less model answer, optional `model`), or `agent` + `instructions` (a custom agent, for tool work)."

    // MARK: Resolvers

    static func liveAgentResolver(_ value: String) -> AgentDispatchTarget? {
        if let ref = ConfigAgentTargetReference.workspaceRef(value) { return .workspace(ref) }
        return AgentManager.shared.agents.first {
            !$0.isBuiltIn && $0.name.caseInsensitiveCompare(value) == .orderedSame
        }.map { .local($0.id) }
    }

    /// Plan-time resolver over the agents that exist once the document is
    /// applied (`names`): agents the document creates map to a placeholder,
    /// and agents a prune deletes do not resolve.
    static func planAgentResolver(names: Set<String>) -> AgentResolver {
        { value in
            if let ref = ConfigAgentTargetReference.workspaceRef(value) { return .workspace(ref) }
            guard names.contains(value.lowercased()) else { return nil }
            return liveAgentResolver(value) ?? .local(UUID())
        }
    }

    static func liveWorkflowInputSchema(_ id: UUID) -> JSONValue? {
        InstalledWorkflowStore.shared.workflow(id: id)?.definition.inputSchema
    }

    static func liveWorkflowResolver(_ value: String) -> UUID? {
        let workflows = InstalledWorkflowStore.shared.workflows
        if let id = UUID(uuidString: value), workflows.contains(where: { $0.id == id }) { return id }
        return workflows.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.id
    }

    private static func resolveConnectionId(named value: String, kind: AgentChannelKind) -> String? {
        let connections = AgentChannelConfigurationStore.load().connections
            .filter { $0.kind == kind }
        return connections.first { $0.id == value || $0.name.caseInsensitiveCompare(value) == .orderedSame }?.id
    }

    /// A native platform's account by connection id or display name.
    static func resolveAccountId(named value: String, kind: AgentChannelKind, primary: String) -> String? {
        let key = AgentChannelConnection.normalizedId(value).lowercased()
        if key == primary { return primary }
        let accounts = ChannelAccounts.accounts(kind: kind)
        return accounts.first { $0.connectionId == key }?.connectionId
            ?? accounts.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.connectionId
            ?? (kind == .email && key.hasPrefix(ChannelAccounts.extraPrefix(.email)) ? key : nil)
    }

    private static func connectionName(_ id: String) -> String {
        AgentChannelConfigurationStore.load().connections.first { $0.id == id }?.name ?? id
    }

    // MARK: Plan

    /// Issues for `entries` in `scope`. `seen` carries names across scopes
    /// so one document never gives two automations the same name.
    static func validate(
        _ entries: [EventEntry], scope: ConfigEventScope = .automations, agentNames: Set<String>,
        seen: inout Set<String>, into issues: inout [String]
    ) {
        let resolver = planAgentResolver(names: agentNames)
        for entry in entries {
            let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, !seen.insert(key).inserted {
                issues.append("\(scope.path)[\(entry.name)]: another \(scope.noun) in the document has this name.")
                continue
            }
            let existing = existingEvent(named: entry.name, in: scope)
            if existing == nil, let other = existingEvent(named: entry.name) {
                issues.append(
                    "\(scope.path)[\(entry.name)]: the name is taken by "
                        + "\(ConfigEventScope.describe(other)) — pick another name.")
                continue
            }
            if case .failure(let error) = build(
                entry, existing: existing, resolveAgent: resolver,
                resolveWorkflow: liveWorkflowResolver, mintBookmarks: false, path: scope.path)
            {
                issues.append(error.message)
            }
        }
    }

    static func validate(
        _ entries: [EventEntry], agentNames: Set<String>, into issues: inout [String]
    ) {
        var seen = Set<String>()
        validate(entries, agentNames: agentNames, seen: &seen, into: &issues)
    }

    static func existingEvent(named name: String) -> OsaurusEvent? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return EventManager.shared.events.first { $0.name.lowercased() == key }
    }

    static func existingEvent(named name: String, in scope: ConfigEventScope) -> OsaurusEvent? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return EventManager.shared.events.first { scope.owns($0) && $0.name.lowercased() == key }
    }

    static func plan(
        _ entries: [EventEntry], scope: ConfigEventScope = .automations, agentNames: Set<String>, prune: Bool,
        into actions: inout [ConfigPlanAction]
    ) {
        let resolver = planAgentResolver(names: agentNames)
        var matched = Set<UUID>()
        for entry in entries {
            let existing = existingEvent(named: entry.name, in: scope)
            guard
                case .success(let outcome) = build(
                    entry, existing: existing, resolveAgent: resolver, resolveWorkflow: liveWorkflowResolver,
                    mintBookmarks: false, path: scope.path)
            else { continue }
            let risks = self.risks(for: outcome.event, previous: existing)
            // Agents created by this document resolve to a placeholder at
            // plan time; show the name the document asked for.
            let agentShown =
                outcome.event.action.agent == nil ? nil : entry.agent ?? existing.flatMap { export($0).agent }
            if let existing {
                matched.insert(existing.id)
                var current = scope.row(existing)
                var desired = scope.row(outcome.event)
                if let agentShown {
                    desired["agent"] = agentShown
                    if entry.agent == nil { current["agent"] = agentShown }
                }
                let changes = diffLines(current: current, desired: desired)
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: scope.section, target: scope.target(entry.name), kind: .update,
                            changes: changes, risks: risks))
                }
            } else {
                var changes = [scope.createSummary(outcome.event, agentShown)] + outcome.notes
                if let duplicate = folderDuplicate(of: outcome.event) {
                    changes.append(
                        "note: automation `\(duplicate.name)` already watches this path — if you "
                            + "meant to change it, reuse that exact name to update it instead "
                            + "of creating a duplicate.")
                }
                actions.append(
                    ConfigPlanAction(
                        section: scope.section, target: scope.target(entry.name), kind: .create,
                        changes: changes, risks: risks))
            }
        }
        if prune {
            for event in EventManager.shared.events where scope.owns(event) && !matched.contains(event.id) {
                actions.append(
                    ConfigPlanAction(
                        section: scope.section, target: scope.target(event.name), kind: .delete,
                        changes: ["delete \(scope.noun)"],
                        risks: [ConfigRisk.deleteEvent(event.name)]))
            }
        }
    }

    /// An existing folder event, under another name, on the same folder. A
    /// near-identical name ("Voice Memos Watcher" next to "Voice Memo
    /// Watcher") would otherwise yield two events on one folder. The create
    /// still proceeds: the note rides `changes`, never `risks`, because
    /// risks force approval and would turn the hint into a refusal.
    static func folderDuplicate(of event: OsaurusEvent) -> OsaurusEvent? {
        guard let path = event.source.folder?.path, !path.isEmpty else { return nil }
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        }
        let target = normalized(path)
        return EventManager.shared.events.first { candidate in
            guard let existing = candidate.source.folder?.path, !existing.isEmpty else { return false }
            return normalized(existing) == target && candidate.name.lowercased() != event.name.lowercased()
        }
    }

    static func risks(for event: OsaurusEvent, previous: OsaurusEvent?) -> [String] {
        var out: [String] = []
        if let webhook = event.source.webhook, webhook.verification == .none,
            previous?.source.webhook?.verification != WebhookVerificationMethod.none
        {
            out.append(ConfigRisk.unsignedWebhook(event.name))
        }
        if event.sourceKind == .channelMessage, event.reply.replies(for: event.action.kind),
            !(previous.map { $0.reply.replies(for: $0.action.kind) } ?? false)
        {
            out.append(ConfigRisk.channelAutoReply(event.source.channelMessage?.kind.displayName ?? "channel"))
        }
        return out
    }

    /// `key: old -> new` lines over the flattened entries.
    static func diffLines(current: EventEntry, desired: EventEntry) -> [String] {
        diffLines(current: flatten(current), desired: flatten(desired))
    }

    static func diffLines(current old: [String: String], desired new: [String: String]) -> [String] {
        Set(old.keys).union(new.keys).sorted().compactMap { key in
            let before = old[key] ?? "(unset)"
            let after = new[key] ?? "(unset)"
            return before == after ? nil : "\(key): \(truncate(before)) -> \(truncate(after))"
        }
    }

    static func flatten<T: Encodable>(_ entry: T) -> [String: String] {
        guard let data = try? JSONEncoder().encode(entry),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        func walk(_ value: Any, _ path: String) {
            if let dict = value as? [String: Any] {
                for (key, child) in dict { walk(child, path.isEmpty ? key : "\(path).\(key)") }
            } else if let list = value as? [Any] {
                out[path] = list.map { "\($0)" }.joined(separator: ", ")
            } else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                out[path] = number.boolValue ? "true" : "false"
            } else {
                out[path] = "\(value)"
            }
        }
        walk(object, "")
        out.removeValue(forKey: "name")
        return out
    }

    private static func truncate(_ value: String) -> String {
        value.count > 80 ? String(value.prefix(77)) + "…" : value
    }

    // MARK: Apply

    static func apply(
        _ entries: [EventEntry], scope: ConfigEventScope = .automations, prune: Bool
    ) -> [ConfigApplyResult] {
        var results: [ConfigApplyResult] = []
        var matched = Set<UUID>()
        let manager = EventManager.shared
        for entry in entries {
            let existing = existingEvent(named: entry.name, in: scope)
            if existing == nil, let other = existingEvent(named: entry.name) {
                results.append(
                    ConfigApplyResult(
                        section: scope.section, target: scope.target(entry.name), status: .failed,
                        message: "The name is taken by \(ConfigEventScope.describe(other)) — pick another name."))
                continue
            }
            switch build(
                entry, existing: existing, resolveAgent: liveAgentResolver, resolveWorkflow: liveWorkflowResolver,
                mintBookmarks: true, path: scope.path)
            {
            case .failure(let error):
                results.append(
                    ConfigApplyResult(
                        section: scope.section, target: scope.target(entry.name), status: .failed,
                        message: error.message))
            case .success(let outcome):
                if existing != nil {
                    manager.update(outcome.event)
                } else {
                    manager.create(outcome.event)
                }
                matched.insert(outcome.event.id)
                results.append(
                    ConfigApplyResult(
                        section: scope.section, target: scope.target(entry.name),
                        status: outcome.needsUserAction ? .needsUserAction : .done,
                        message: outcome.notes.isEmpty ? nil : outcome.notes.joined(separator: " ")))
            }
        }
        if prune {
            for event in manager.events where scope.owns(event) && !matched.contains(event.id) {
                _ = manager.delete(id: event.id)
                results.append(
                    ConfigApplyResult(section: scope.section, target: scope.target(event.name), status: .done))
            }
        }
        return results
    }

    // MARK: Agent prune integrity

    /// Prune of `agents:` must not leave an event pointing at a deleted
    /// agent: the document has to delete or reassign it too. An event is
    /// deleted by the same prune only when the list that owns it
    /// (`automations`, or its channel's `routing`) is declared and leaves it
    /// out.
    static func validatePruneAgentReferences(
        document: OsaurusConfigDocument, prunedNameById: [UUID: String], into issues: inout [String]
    ) {
        let lists: [(scope: ConfigEventScope, entries: [EventEntry])] =
            (document.automations.map { [(ConfigEventScope.automations, $0)] } ?? [])
            + ConfigChannelRouting.scopes(in: document).compactMap { scoped in
                scoped.scope.map { ($0, scoped.entries) }
            }
        for event in EventManager.shared.events {
            guard let agentId = event.agentId, let agentName = prunedNameById[agentId] else { continue }
            if let list = lists.first(where: { $0.scope.owns(event) }) {
                guard let entry = list.entries.first(where: { $0.name.lowercased() == event.name.lowercased() })
                else { continue }
                guard entry.agent == nil, entry.workflow == nil, entry.model == nil else { continue }
            }
            issues.append(
                "prune: \(ConfigEventScope.describe(event)) still runs on agent `\(agentName)`, which this prune "
                    + "would delete. Delete or reassign it in the same document.")
        }
    }
}

struct ConfigEventError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Legacy input translation

extension OsaurusConfigDocument {
    /// The document with legacy `schedules:` / `watchers:` entries folded
    /// into `automations:`, and `channels.<platform>.inbound_*` keys and
    /// `channel_message` automations moved to their channel's `routing`,
    /// plus a deprecation note per translated section. Idempotent.
    @MainActor
    func translatingLegacyEvents() -> (document: OsaurusConfigDocument, notes: [String]) {
        var doc = self
        var notes: [String] = []
        var translated: [EventEntry] = []

        if let schedules = doc.legacySchedules {
            translated += schedules.map(Self.eventEntry(fromSchedule:))
            notes.append("`schedules:` is deprecated — translated to `automations:` entries with `source.kind: schedule`.")
            doc.legacySchedules = nil
        }
        if let watchers = doc.legacyWatchers {
            translated += watchers.map(Self.eventEntry(fromWatcher:))
            notes.append("`watchers:` is deprecated — translated to `automations:` entries with `source.kind: folder`.")
            doc.legacyWatchers = nil
        }

        var routed: [(platform: ConfigChannelPlatform?, connection: String?, rule: ChannelRoutingRuleEntry)] = []
        if var channels = doc.channels {
            var touched: [String] = []
            for platform in ConfigChannelPlatform.allCases {
                guard var section = platform.section(in: channels), section.hasLegacyInbound else { continue }
                if let entry = Self.eventEntry(fromInbound: section, platform: platform) {
                    routed.append((platform, nil, ChannelRoutingRuleEntry(legacy: entry)))
                } else {
                    notes.append(
                        "`channels.\(platform.rawValue)` inbound keys were ignored: nobody answers on "
                            + "\(platform.rawValue) yet and no `inbound_agent` was given. Add a rule to "
                            + "`channels.\(platform.rawValue).routing`.")
                }
                section.clearLegacyInbound()
                platform.setSection(section, in: &channels)
                touched.append(platform.rawValue)
            }
            if !touched.isEmpty {
                notes.append(
                    "`channels.<platform>.inbound_*` is deprecated — translated to `channels.<platform>.routing` "
                        + "(\(touched.joined(separator: ", "))).")
            }
            doc.channels = channels
        }

        // Channel rules written as automations move to their channel.
        var kept: [EventEntry] = []
        var movedLabels: [String] = []
        var retiredEmail: [String] = []
        for entry in doc.automations ?? [] {
            if entry.source?.kind?.lowercased() == EventSourceKind.email.rawValue {
                retiredEmail.append(entry.name)
                continue
            }
            guard let target = Self.legacyChannelTarget(of: entry) else {
                kept.append(entry)
                continue
            }
            routed.append((target.platform, target.connection, ChannelRoutingRuleEntry(legacy: entry)))
            let label =
                target.platform.map { platform in
                    target.connection.map { "\(platform.rawValue).accounts[\($0)]" } ?? platform.rawValue
                } ?? "connections[\(target.connection ?? "?")]"
            if !movedLabels.contains(label) { movedLabels.append(label) }
        }
        if !movedLabels.isEmpty {
            notes.append(
                "`automations` entries with `source.kind: channel_message` are deprecated — moved to "
                    + movedLabels.map { "`channels.\($0).routing`" }.joined(separator: ", ")
                    + ". Write channel rules there.")
        }
        if !retiredEmail.isEmpty {
            notes.append(ConfigEvents.retiredEmailNote(names: retiredEmail))
        }
        if doc.automations != nil || !translated.isEmpty {
            var events = kept
            for entry in translated where !events.contains(where: { $0.name.lowercased() == entry.name.lowercased() }) {
                events.append(entry)
            }
            doc.automations = events
        }

        guard !routed.isEmpty else { return (doc, notes) }
        var channels = doc.channels ?? ChannelsSection()
        for item in routed {
            if let platform = item.platform {
                var section = platform.section(in: channels) ?? ChannelPlatformSection()
                func add(to target: inout ChannelPlatformSection) {
                    var rules = target.routing ?? []
                    if !rules.contains(where: { $0.name.lowercased() == item.rule.name.lowercased() }) {
                        rules.append(item.rule)
                    }
                    target.routing = rules
                }
                if let account = item.connection {
                    var accounts = section.accounts ?? []
                    let index =
                        accounts.firstIndex { $0.id.map(AgentChannelConnection.normalizedId) == account }
                        ?? {
                            var entry = ChannelPlatformSection()
                            entry.id = account
                            accounts.append(entry)
                            return accounts.count - 1
                        }()
                    add(to: &accounts[index])
                    section.accounts = accounts
                } else {
                    add(to: &section)
                }
                platform.setSection(section, in: &channels)
            } else if let connection = item.connection {
                var connections = channels.connections ?? []
                let index =
                    connections.firstIndex { $0.connection.lowercased() == connection.lowercased() }
                    ?? {
                        connections.append(ChannelConnectionEntry(connection: connection))
                        return connections.count - 1
                    }()
                var rules = connections[index].routing ?? []
                if !rules.contains(where: { $0.name.lowercased() == item.rule.name.lowercased() }) {
                    rules.append(item.rule)
                }
                connections[index].routing = rules
                channels.connections = connections
            }
        }
        doc.channels = channels
        return (doc, notes)
    }

    /// Where a legacy channel automation entry belongs: its native platform,
    /// or its n8n / custom connection. Nil for non-channel entries and for
    /// channel entries too incomplete to place (left for `build` to report).
    @MainActor
    static func legacyChannelTarget(of entry: EventEntry) -> (platform: ConfigChannelPlatform?, connection: String?)? {
        let kind = entry.source?.kind?.lowercased()
        let existing = ConfigEvents.existingEvent(named: entry.name)?.source.channelMessage
        guard kind == EventSourceKind.channelMessage.rawValue || (kind == nil && existing != nil) else { return nil }
        guard let platformRaw = (entry.source?.platform ?? existing?.kind.rawValue)?.lowercased(),
            let channelKind = AgentChannelKind(rawValue: platformRaw)
        else { return nil }
        if let native = ChannelMessageSourceConfig.nativeConnectionId(for: channelKind) {
            guard let platform = ConfigChannelPlatform(rawValue: platformRaw) else { return nil }
            let named =
                entry.source?.connection.flatMap { ConfigEvents.resolveAccountId(named: $0, kind: channelKind, primary: native) }
                ?? (existing?.kind == channelKind ? existing?.connectionId : nil)
            guard let account = named.map(AgentChannelConnection.normalizedId), account != native else {
                return (platform, nil)
            }
            return (platform, account)
        }
        let connection =
            entry.source?.connection
            ?? (existing?.kind == channelKind ? existing?.connectionId : nil)
        return connection.map { (nil, $0) }
    }

    static func eventEntry(fromSchedule schedule: ScheduleEntry) -> EventEntry {
        var entry = EventEntry(name: schedule.name)
        entry.enabled = schedule.enabled
        var source = EventSourceEntry(kind: EventSourceKind.schedule.rawValue)
        source.frequency = schedule.frequency
        source.frequencyValue = schedule.frequencyValue
        source.frequencyTimeOfDay = schedule.frequencyTimeOfDay
        entry.source = source
        entry.agent = schedule.agent
        entry.instructions = schedule.instructions
        return entry
    }

    static func eventEntry(fromWatcher watcher: WatcherEntry) -> EventEntry {
        var entry = EventEntry(name: watcher.name)
        entry.enabled = watcher.enabled
        var source = EventSourceEntry(kind: EventSourceKind.folder.rawValue)
        source.path = watcher.path
        source.recursive = watcher.recursive
        source.responsiveness = watcher.responsiveness
        entry.source = source
        entry.agent = watcher.agent
        entry.instructions = watcher.instructions
        return entry
    }

    /// The platform's default any-room event (the one migration created
    /// from `inboundDispatch.target`), patched by the legacy keys.
    @MainActor
    static func eventEntry(fromInbound section: ChannelPlatformSection, platform: ConfigChannelPlatform)
        -> EventEntry?
    {
        guard let kind = AgentChannelKind(rawValue: platform.rawValue) else { return nil }
        let existing = EventManager.shared.events.first { event in
            guard let m = event.source.channelMessage else { return false }
            return m.kind == kind && m.roomIds.isEmpty && m.aliases.isEmpty
        }
        if existing == nil, section.inboundAgent.valueOrNil == nil { return nil }
        var entry = EventEntry(name: existing?.name ?? "\(kind.displayName) messages")
        var source = EventSourceEntry(kind: EventSourceKind.channelMessage.rawValue)
        source.platform = kind.rawValue
        source.requireMention = section.requireMention
        source.continueThreads = section.continueThreads
        entry.source = source
        switch section.inboundAgent {
        case .absent: break
        case .null: entry.enabled = false
        case .value(let name): entry.agent = name
        }
        if let enabled = section.inboundEnabled { entry.enabled = enabled }
        if let autoReply = section.autoReplyEnabled {
            var reply = EventReplyEntry()
            reply.autoReply = autoReply
            entry.reply = reply
        }
        return entry
    }
}

extension ChannelPlatformSection {
    var hasLegacyInbound: Bool {
        inboundEnabled != nil || inboundAgent != .absent || requireMention != nil || continueThreads != nil
            || autoReplyEnabled != nil
    }

    mutating func clearLegacyInbound() {
        inboundEnabled = nil
        inboundAgent = .absent
        requireMention = nil
        continueThreads = nil
        autoReplyEnabled = nil
    }
}

extension Array {
    fileprivate var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
