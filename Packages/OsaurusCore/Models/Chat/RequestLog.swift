//
//  RequestLog.swift
//  osaurus
//
//  Model for the persisted activity / audit log surfaced by Insights
//  (`InsightsService` + `ActivityLogStore`). Every interaction that this
//  device runs or sends — local inference, cloud inference, web search,
//  URL extraction, MCP tool calls, channel deliveries, Router control
//  calls, inbound API traffic and plugin activity — is one `RequestLog`.
//

import Foundation

/// Represents a logged tool call within an inference
struct ToolCallLog: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let name: String
    let arguments: String
    let result: String?
    let durationMs: Double?
    let isError: Bool

    init(
        id: UUID = UUID(),
        name: String,
        arguments: String,
        result: String? = nil,
        durationMs: Double? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.arguments = Self.redactedArguments(toolName: name, arguments: arguments)
        self.result = Self.redactedResult(toolName: name, result: result)
        self.durationMs = durationMs
        self.isError = isError
    }

    /// Decoding bypasses the redactors: persisted rows were redacted when
    /// they were first recorded and must round-trip byte-for-byte so the
    /// hash chain verifies.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        result = try c.decodeIfPresent(String.self, forKey: .result)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }

    private init(
        rawId: UUID, rawName: String, rawArguments: String, rawResult: String?,
        rawDurationMs: Double?, rawIsError: Bool
    ) {
        id = rawId
        name = rawName
        arguments = rawArguments
        result = rawResult
        durationMs = rawDurationMs
        isError = rawIsError
    }

    /// Copy with every free-text field replaced by a marker. Used when the
    /// user has turned off "store message content in activity log".
    func withoutContent() -> ToolCallLog {
        ToolCallLog(
            rawId: id,
            rawName: name,
            rawArguments: RequestLog.contentWithheldMarker,
            rawResult: result == nil ? nil : RequestLog.contentWithheldMarker,
            rawDurationMs: durationMs,
            rawIsError: isError
        )
    }

    private static func redactedArguments(toolName: String, arguments: String) -> String {
        guard ToolRegistry.agentChannelToolNames.contains(toolName) else {
            return arguments
        }
        guard let data = arguments.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return #"{ "redaction": "agent_channel_arguments_redacted" }"#
        }

        // Keep this in sync with any future Agent Channel free-text tool fields.
        let sensitiveKeys: Set<String> = [
            "body",
            "content",
            "message",
            "query",
            "reply",
            "text",
        ]
        for key in Array(object.keys) where sensitiveKeys.contains(key.lowercased()) {
            object[key] = "[REDACTED:AGENT_CHANNEL_MESSAGE_CONTENT]"
        }
        guard let redactedData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ),
            let redacted = String(data: redactedData, encoding: .utf8)
        else {
            return #"{ "redaction": "agent_channel_arguments_redacted" }"#
        }
        return redacted
    }

    private static func redactedResult(toolName: String, result: String?) -> String? {
        guard ToolRegistry.agentChannelToolNames.contains(toolName) else {
            return result
        }
        guard result != nil else { return nil }
        return "[REDACTED:AGENT_CHANNEL_TOOL_RESULT]"
    }
}

/// Source of the request
enum RequestSource: String, Sendable, CaseIterable, Codable {
    case chatUI = "Chat UI"
    /// A local agent or delegated subagent model step.
    case agent = "Agent"
    case httpAPI = "HTTP API"
    case plugin = "Plugin"
    /// Inbound traffic from another Osaurus peer over the Secure Channel
    /// (remote chat completions and remote agent runs).
    case p2p = "P2P"
    /// Autonomous, headless runs that nobody is waiting on: cron schedules,
    /// file-system watchers, agent self-wakes.
    ///
    /// These used to be flattened into `.chatUI` on the way to the model,
    /// because `ChatSession` built its engine as `ChatEngine(source: .chatUI)`
    /// unconditionally and dropped its own `SessionSource`. That mislabel had
    /// teeth: `accelerateIdleUnloadAfterChatClose` only shortens residency for
    /// `.chatUI`-sourced models, so closing an unrelated chat window could
    /// accelerate the unload of the model a scheduled job was mid-run with.
    case scheduled = "Scheduled"
    /// Inbound work from a configured Agent Channel.
    case channel = "Channel"
    /// User-authored recurring schedule.
    case schedule = "Schedule"
    /// File-system watcher trigger.
    case watcher = "Watcher"
    /// Agent-authored wake-up.
    case selfSchedule = "Self-scheduled"
    /// Egress performed by a tool on behalf of whatever run invoked it
    /// (web search, URL fetch, MCP call, channel delivery, Router call).
    case tool = "Tool"
    /// Store-level bookkeeping rows (e.g. "log cleared").
    case system = "System"

    var displayName: String {
        switch self {
        case .chatUI: return L("Chat UI")
        case .agent: return L("Agent")
        case .httpAPI: return L("HTTP API")
        case .plugin: return L("Plugin")
        case .p2p: return L("P2P")
        case .scheduled: return L("Scheduled")
        case .channel: return L("Channel")
        case .schedule: return L("Schedule")
        case .watcher: return L("Watcher")
        case .selfSchedule: return L("Self-scheduled")
        case .tool: return L("Tool")
        case .system: return L("System")
        }
    }

    var shortName: String {
        switch self {
        case .chatUI: return "Chat"
        case .agent: return "Agent"
        case .httpAPI: return "HTTP"
        case .plugin: return "Plugin"
        case .p2p: return "P2P"
        case .scheduled: return "Scheduled"
        case .channel: return "Channel"
        case .schedule: return "Schedule"
        case .watcher: return "Watcher"
        case .selfSchedule: return "Self-scheduled"
        case .tool: return "Tool"
        case .system: return "System"
        }
    }

    var icon: String {
        switch self {
        case .chatUI: return "bubble.left.fill"
        case .agent: return "person.crop.circle.fill"
        case .httpAPI: return "network"
        case .plugin: return "puzzlepiece.extension.fill"
        case .p2p: return "antenna.radiowaves.left.and.right"
        case .scheduled: return "clock.fill"
        case .channel: return "bubble.left.and.bubble.right.fill"
        case .schedule: return "calendar.badge.clock"
        case .watcher: return "eye.fill"
        case .selfSchedule: return "clock.badge.checkmark.fill"
        case .tool: return "wrench.and.screwdriver.fill"
        case .system: return "gearshape.fill"
        }
    }
}

/// How a request reached its model — distinguishes a purely local run from
/// the two remote shapes so Insights doesn't conflate "the local Apple model
/// ran" with "a remote agent ran its own loop".
enum RequestMode: String, Sendable, Codable {
    /// Ran on this device (MLX / Foundation / etc.).
    case local
    /// Mode 1: a remote peer used as a plain inference backend (`/chat/completions`).
    case remoteInference
    /// Mode 2: a remote agent run (`/agents/{address}/run`) where the peer
    /// runs its own tool loop + generation config.
    case remoteAgentRun

    var displayName: String {
        switch self {
        case .local: return L("Local")
        case .remoteInference: return L("Remote inference")
        case .remoteAgentRun: return L("Remote agent run")
        }
    }
}

/// Transport security for a request that crossed the network.
enum RequestTransport: String, Sendable, Codable {
    /// Never left the device.
    case local
    /// Osaurus Secure Channel (forward-secret, mutually authenticated E2E).
    case secureChannel
    /// Direct request (TLS to a third-party provider, or plaintext LAN).
    case direct

    var displayName: String {
        switch self {
        case .local: return L("Local")
        case .secureChannel: return L("Secure Channel")
        case .direct: return L("Direct")
        }
    }
}

/// Connection + attribution metadata for a logged request. Lets Insights show
/// where a remote run actually went (relay/host + real endpoint + mode) instead
/// of a bare model badge, and — for inbound host traffic — which paired access
/// key it authenticated with so per-connection usage can be tallied.
struct RequestConnectionInfo: Sendable, Equatable, Codable {
    /// The `RemoteProvider.id` for an outbound remote request (client side).
    var providerId: UUID?
    /// Human-readable host/relay + the real path used, e.g.
    /// `https://0xabc….agent.osaurus.ai/agents/0xabc…/run`.
    var remoteEndpoint: String?
    var transport: RequestTransport?
    var mode: RequestMode?
    /// (inbound / host only) Access-key id (`AccessKeyInfo.id`) the request
    /// authenticated with, so the host's Remote Connections view can attribute
    /// usage to a specific paired peer. nil for loopback / master-scoped.
    var accessKeyId: String?
    /// (inbound / host only) The agent-address audience the key is scoped to.
    var audience: String?

    init(
        providerId: UUID? = nil,
        remoteEndpoint: String? = nil,
        transport: RequestTransport? = nil,
        mode: RequestMode? = nil,
        accessKeyId: String? = nil,
        audience: String? = nil
    ) {
        self.providerId = providerId
        self.remoteEndpoint = remoteEndpoint
        self.transport = transport
        self.mode = mode
        self.accessKeyId = accessKeyId
        self.audience = audience
    }

    /// True when no field carries information (used to avoid storing an empty
    /// struct that would clutter the Insights detail pane).
    var isEmpty: Bool {
        providerId == nil && remoteEndpoint == nil && transport == nil
            && mode == nil && accessKeyId == nil && audience == nil
    }
}

/// What kind of interaction a log row describes. Raw values are the on-disk
/// `category` column and the export field — keep them stable.
enum ActivityCategory: String, Sendable, Codable, CaseIterable {
    /// A model generation (local or remote), including tool-call steps.
    case inference
    /// Hidden context-compaction generation.
    case compaction
    /// `web_search` tool: the query left the device to one or more providers.
    case webSearch = "web_search"
    /// `search_and_extract` / readability fetch of one or more URLs.
    case urlExtract = "url_extract"
    /// A tool call forwarded to an MCP server.
    case mcpToolCall = "mcp_tool_call"
    /// A message delivered to an Agent Channel (Slack, Discord, webhook…).
    case channelDelivery = "channel_delivery"
    /// Osaurus Router control-plane call (workspaces, credits, identity…).
    case routerControl = "router_control"
    /// Inbound request to the local HTTP server (API clients, MCP, peers).
    case inboundAPI = "inbound_api"
    /// Plugin host API call made by an installed plugin.
    case pluginCall = "plugin_call"
    /// Plugin console log line.
    case pluginLog = "plugin_log"
    /// Text → vector embedding (memory, knowledge, tool/skill search, `/v1/embeddings`).
    case embedding
    /// Speech → text (voice input, `/v1/audio/transcriptions`).
    case audioTranscription = "audio_transcription"
    /// Text → speech (read-aloud, `speak` tool, remote TTS providers).
    case speechSynthesis = "speech_synthesis"
    /// Image / video generation, editing or upscaling (local or cloud).
    case mediaGeneration = "media_generation"
    /// Store-level events (cleared, pruned, verified, exported, settings
    /// changed, recovered). Chain-of-custody rows for reviewers.
    case system

    var displayName: String {
        switch self {
        case .inference: return L("Inference")
        case .compaction: return L("Compaction")
        case .webSearch: return L("Web search")
        case .urlExtract: return L("URL fetch")
        case .mcpToolCall: return L("MCP tool")
        case .channelDelivery: return L("Channel")
        case .routerControl: return L("Router")
        case .inboundAPI: return L("API")
        case .pluginCall: return L("Plugin call")
        case .pluginLog: return L("Plugin log")
        case .embedding: return L("Embedding")
        case .audioTranscription: return L("Transcription")
        case .speechSynthesis: return L("Speech")
        case .mediaGeneration: return L("Media")
        case .system: return L("System")
        }
    }

    var icon: String {
        switch self {
        case .inference: return "cpu"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .webSearch: return "magnifyingglass"
        case .urlExtract: return "doc.text.magnifyingglass"
        case .mcpToolCall: return "wrench.and.screwdriver"
        case .channelDelivery: return "paperplane"
        case .routerControl: return "network"
        case .inboundAPI: return "arrow.down.left.circle"
        case .pluginCall: return "puzzlepiece.extension"
        case .pluginLog: return "text.alignleft"
        case .embedding: return "point.3.connected.trianglepath.dotted"
        case .audioTranscription: return "waveform"
        case .speechSynthesis: return "speaker.wave.2"
        case .mediaGeneration: return "photo.on.rectangle.angled"
        case .system: return "gearshape"
        }
    }

    /// True for categories that run a model (local or remote) rather than
    /// moving data or bookkeeping.
    var isModelWork: Bool {
        switch self {
        case .inference, .compaction, .embedding, .audioTranscription, .speechSynthesis, .mediaGeneration:
            return true
        default:
            return false
        }
    }
}

/// Whether the interaction's data stayed on this Mac or crossed the network.
enum DataLocality: String, Sendable, Codable, CaseIterable {
    case local
    case remote

    var displayName: String {
        switch self {
        case .local: return L("Local")
        case .remote: return L("Cloud")
        }
    }
}

/// Describes what left the device and where it went. Present on every
/// `.remote` row; absent for purely local work.
struct EgressInfo: Sendable, Equatable, Codable {
    /// Human-readable destination: "OpenAI", "Tavily", "Osaurus Router",
    /// "slack.com", a peer's relay host…
    var destinationLabel: String?
    /// Bare host of the destination endpoint.
    var destinationHost: String?
    var bytesSent: Int?
    var bytesReceived: Int?
    /// Coarse classes of data in the outbound payload: `prompt`, `tools`,
    /// `search_query`, `urls`, `tool_arguments`, `channel_message`,
    /// `attachments`, `account`.
    var dataClasses: [String]
    /// True when the Privacy Filter rewrote spans before send.
    var privacyFilterApplied: Bool
    /// Number of spans the Privacy Filter replaced with placeholders.
    var redactedSpanCount: Int?
    /// Category-specific facts (search query, providers tried, URLs,
    /// MCP server name, channel kind…). Small string bag; values clipped
    /// by the store.
    var details: [String: String]

    init(
        destinationLabel: String? = nil,
        destinationHost: String? = nil,
        bytesSent: Int? = nil,
        bytesReceived: Int? = nil,
        dataClasses: [String] = [],
        privacyFilterApplied: Bool = false,
        redactedSpanCount: Int? = nil,
        details: [String: String] = [:]
    ) {
        self.destinationLabel = destinationLabel
        self.destinationHost = destinationHost
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.dataClasses = dataClasses
        self.privacyFilterApplied = privacyFilterApplied
        self.redactedSpanCount = redactedSpanCount
        self.details = details
    }

    /// `details` keys that carry user content (as opposed to metadata) and
    /// are withheld when content storage is disabled.
    static let contentDetailKeys: Set<String> = ["query", "urls", "arguments", "result_preview", "message"]

    /// Host component of an endpoint string, or the string itself when it
    /// is not a URL.
    static func host(from endpoint: String?) -> String? {
        guard let endpoint, !endpoint.isEmpty else { return nil }
        if let url = URL(string: endpoint), let host = url.host, !host.isEmpty {
            return host
        }
        // "host/path" without scheme
        if let slash = endpoint.firstIndex(of: "/") {
            let head = String(endpoint[..<slash])
            return head.isEmpty ? nil : head
        }
        return endpoint
    }
}

/// Represents a single request log entry with optional inference data
struct RequestLog: Identifiable, Sendable, Codable {
    /// Placeholder written in place of bodies when the user has disabled
    /// content storage for the activity log.
    /// Placeholder written in place of prompts, responses, tool arguments and
    /// wire payloads when content is withheld — either because Privacy ›
    /// Activity Log › Store Prompts and Responses is off, or because an export
    /// was made with "Include message content" unchecked.
    static let contentWithheldMarker = "[content withheld — metadata only]"

    let id: UUID
    let timestamp: Date
    let source: RequestSource

    /// What kind of interaction this row is.
    let category: ActivityCategory
    /// Whether data stayed on this Mac or crossed the network.
    let locality: DataLocality
    /// What was sent where. nil for purely local rows.
    let egress: EgressInfo?

    /// Attribution: the agent / session that produced this row, when known.
    let agentId: UUID?
    let agentName: String?
    let sessionId: UUID?
    /// (inbound only) Remote client address that made the request.
    let clientIP: String?

    /// Hash-chain position, assigned by `ActivityLogStore` on append. nil
    /// until persisted.
    var seq: Int?
    var prevHash: String?
    var hash: String?

    /// Local-only correlation back to the chat assistant turn that produced
    /// this log (chatUI source only). Lets the per-message "Insights" button
    /// open this exact entry. Nil for HTTP/plugin requests.
    let turnId: UUID?

    /// Request-level correlation for router-backed chat calls. For Osaurus
    /// Router this is the signed idempotency key / request_id used by billing,
    /// so account usage rows can focus the exact Insights log for an iteration.
    let requestId: String?

    // HTTP request/response fields
    let method: String
    let path: String
    let statusCode: Int
    let durationMs: Double
    let requestBody: String?
    let responseBody: String?
    let userAgent: String?

    // Plugin attribution (nil for non-plugin requests)
    let pluginId: String?

    // Optional inference fields (only for chat endpoints)
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let tokensPerSecond: Double?
    let temperature: Float?
    let maxTokens: Int?
    let toolCalls: [ToolCallLog]?
    let finishReason: FinishReason?
    let errorMessage: String?

    /// Verbatim HTTP request body the remote provider actually saw,
    /// AFTER `PrivacyFilterPipeline.applyOutbound` (re)wrote any
    /// approved spans to placeholders. Nil when the request never
    /// went out on the wire (MLX / Foundation routes, or a privacy-
    /// cancel before send). Used by the Insights "Wire Request" tab
    /// so users can verify the cloud body matches what they
    /// approved in the review sheet — `requestBody` above is the
    /// pre-scrub local copy and is intentionally NOT used here.
    let wireRequestBody: String?
    /// Raw bytes received from the network, captured BEFORE the
    /// unscrubber rewrote placeholders back to originals. Nil for
    /// non-chatUI sources and local routes. Lossy-truncated at
    /// `WireTransportProbe.maxResponseBytes` (1 MiB); the truncated
    /// marker is implicit in the size.
    let wireResponseBody: String?

    /// Connection + attribution metadata (relay/host, transport, mode, and —
    /// for inbound host traffic — the paired access key). nil for plain local
    /// runs with nothing remote to describe.
    let connection: RequestConnectionInfo?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: RequestSource,
        turnId: UUID? = nil,
        requestId: String? = nil,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        requestBody: String? = nil,
        responseBody: String? = nil,
        userAgent: String? = nil,
        pluginId: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: FinishReason? = nil,
        errorMessage: String? = nil,
        wireRequestBody: String? = nil,
        wireResponseBody: String? = nil,
        connection: RequestConnectionInfo? = nil,
        category: ActivityCategory? = nil,
        locality: DataLocality? = nil,
        egress: EgressInfo? = nil,
        agentId: UUID? = nil,
        agentName: String? = nil,
        sessionId: UUID? = nil,
        clientIP: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        let resolvedConnection = (connection?.isEmpty == true) ? nil : connection
        self.category =
            category
            ?? Self.inferCategory(method: method, path: path, pluginId: pluginId)
        self.locality =
            locality
            ?? Self.inferLocality(connection: resolvedConnection, egress: egress)
        self.egress = egress
        self.agentId = agentId
        self.agentName = agentName
        self.sessionId = sessionId
        self.clientIP = clientIP
        self.seq = nil
        self.prevHash = nil
        self.hash = nil
        self.turnId = turnId
        self.requestId = requestId
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.userAgent = userAgent
        self.pluginId = pluginId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.errorMessage = errorMessage
        self.wireRequestBody = wireRequestBody
        self.wireResponseBody = wireResponseBody
        self.connection = resolvedConnection

        // Calculate tokens per second if we have inference data
        if let outputTokens = outputTokens, durationMs > 0 {
            self.tokensPerSecond = Double(outputTokens) / (durationMs / 1000.0)
        } else {
            self.tokensPerSecond = nil
        }
    }

    enum FinishReason: String, Sendable, Codable {
        case stop = "stop"
        case length = "length"
        case toolCalls = "tool_calls"
        case error = "error"
        case cancelled = "cancelled"
    }

    // MARK: - Category / locality inference

    /// Default category for legacy call sites that only know method + path.
    static func inferCategory(method: String, path: String, pluginId: String?) -> ActivityCategory {
        if method == "LOG" { return .pluginLog }
        if path.contains("compaction") { return .compaction }
        // `/internal/<purpose>` = CoreModelService one-shots (titles,
        // follow-ups, memory distillation, transcript cleanup…).
        if path.hasPrefix("/internal/") { return .inference }
        if path.contains("chat") || (path.contains("/agents/") && path.hasSuffix("/run")) {
            return .inference
        }
        if let media = mediaCategory(forPath: path) { return media }
        if pluginId != nil { return .pluginCall }
        return .inboundAPI
    }

    /// Category for the OpenAI-style media / embedding endpoints served by
    /// the local HTTP API (and mirrored by the in-process emitters).
    static func mediaCategory(forPath path: String) -> ActivityCategory? {
        let p = path.lowercased()
        if p.hasSuffix("/embeddings") || p.contains("/embeddings/") || p.hasSuffix("/embed") { return .embedding }
        if p.contains("/audio/transcriptions") || p.contains("/audio/translations")
            || p == "/internal/audio_transcription"
        {
            return .audioTranscription
        }
        if p.contains("/audio/speech") || p == "/internal/speech_synthesis" { return .speechSynthesis }
        if p.contains("/images/") || p.hasSuffix("/images") || p.contains("/videos/") || p.hasSuffix("/videos")
            || p.hasPrefix("/internal/image_") || p.hasPrefix("/internal/video_")
        {
            return .mediaGeneration
        }
        return nil
    }

    /// Default locality when the caller didn't say: anything with a remote
    /// mode, a non-local transport, or an egress destination crossed the
    /// network.
    static func inferLocality(connection: RequestConnectionInfo?, egress: EgressInfo?) -> DataLocality {
        if egress?.destinationHost != nil || egress?.destinationLabel != nil { return .remote }
        guard let connection else { return .local }
        switch connection.mode {
        case .remoteInference, .remoteAgentRun: return .remote
        case .local: return .local
        case nil: break
        }
        switch connection.transport {
        case .secureChannel, .direct: return .remote
        case .local, nil: return .local
        }
    }

    // MARK: - Content policy

    /// Copy of this row with every free-text body replaced by
    /// `contentWithheldMarker`. Metadata, sizes, tool names and egress facts
    /// are kept so the row still answers "what went where".
    func withoutContent() -> RequestLog {
        var scrubbedEgress = egress
        if var details = scrubbedEgress?.details {
            for key in EgressInfo.contentDetailKeys where details[key] != nil {
                details[key] = Self.contentWithheldMarker
            }
            scrubbedEgress?.details = details
        }
        var copy = RequestLog(
            id: id,
            timestamp: timestamp,
            source: source,
            turnId: turnId,
            requestId: requestId,
            method: method,
            path: path,
            statusCode: statusCode,
            durationMs: durationMs,
            requestBody: requestBody == nil ? nil : Self.contentWithheldMarker,
            responseBody: responseBody == nil ? nil : Self.contentWithheldMarker,
            userAgent: userAgent,
            pluginId: pluginId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls?.map { $0.withoutContent() },
            finishReason: finishReason,
            errorMessage: errorMessage,
            wireRequestBody: wireRequestBody == nil ? nil : Self.contentWithheldMarker,
            wireResponseBody: wireResponseBody == nil ? nil : Self.contentWithheldMarker,
            connection: connection,
            category: category,
            locality: locality,
            egress: scrubbedEgress,
            agentId: agentId,
            agentName: agentName,
            sessionId: sessionId,
            clientIP: clientIP
        )
        copy.seq = seq
        copy.prevHash = prevHash
        copy.hash = hash
        return copy
    }

    /// Earlier spellings of `contentWithheldMarker`. Rows written with them
    /// must keep reading as "withheld" rather than as real content.
    static let legacyContentWithheldMarkers: Set<String> = [
        "[content not stored — see Privacy › Activity Log]"
    ]

    /// True when `value` is the withheld-content placeholder (current or legacy).
    static func isWithheldContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == contentWithheldMarker || legacyContentWithheldMarkers.contains(value)
    }

    /// True when at least one body / argument field holds real content
    /// (not nil and not the withheld placeholder).
    var hasStoredContent: Bool {
        [requestBody, responseBody, wireRequestBody, wireResponseBody]
            .contains { $0 != nil && !Self.isWithheldContent($0) }
            || (toolCalls?.contains { !Self.isWithheldContent($0.arguments) } ?? false)
    }

    // MARK: - Computed Properties

    /// Short, human-readable one-liner for list rows, CSV and Markdown.
    var title: String {
        let d = egress?.details ?? [:]
        switch category {
        case .inference:
            if let purpose = internalPurposeLabel {
                return model != nil ? "\(purpose) · \(shortModelName)" : purpose
            }
            return model.map { _ in shortModelName } ?? path
        case .compaction:
            return L("Context compaction") + (model != nil ? " · \(shortModelName)" : "")
        case .webSearch:
            if let q = d["query"], !q.isEmpty { return L("Web search") + ": “\(q)”" }
            return L("Web search")
        case .urlExtract:
            if let urls = d["urls"], !urls.isEmpty {
                let list = urls.split(separator: "\n").map(String.init)
                if list.count == 1 { return list[0] }
                return String(format: L("Fetched %d URLs"), list.count)
            }
            return L("URL fetch")
        case .mcpToolCall:
            let tool = d["tool"] ?? path
            if let server = d["server"], !server.isEmpty { return "\(tool) @ \(server)" }
            return tool
        case .channelDelivery:
            let kind = d["channel_kind"] ?? L("Channel")
            if let host = egress?.destinationHost { return "\(kind) → \(host)" }
            return kind
        case .routerControl:
            return "\(method) \(path)"
        case .inboundAPI:
            return "\(method) \(path)"
        case .pluginCall:
            return path
        case .pluginLog:
            return responseBody?.split(separator: "\n").first.map(String.init) ?? path
        case .embedding:
            let count = d["texts"].flatMap(Int.init)
            let base = count.map { String(format: L("Embedded %d texts"), $0) } ?? L("Embedding")
            return model != nil ? "\(base) · \(shortModelName)" : base
        case .audioTranscription:
            var base = L("Transcribed audio")
            if let secs = d["audio_seconds"].flatMap(Double.init), secs > 0 {
                base = String(format: L("Transcribed %.0fs audio"), secs)
            }
            return model != nil ? "\(base) · \(shortModelName)" : base
        case .speechSynthesis:
            var base = L("Spoke text")
            if let chars = d["chars"].flatMap(Int.init) {
                base = String(format: L("Spoke %d chars"), chars)
            }
            return model != nil ? "\(base) · \(shortModelName)" : base
        case .mediaGeneration:
            let kind = d["media_kind"] ?? "image"
            let op = d["operation"] ?? "generate"
            let count = d["count"].flatMap(Int.init) ?? 1
            let noun = kind == "video" ? (count == 1 ? L("video") : L("videos")) : (count == 1 ? L("image") : L("images"))
            let verb: String
            switch op {
            case "edit": verb = L("Edited")
            case "upscale": verb = L("Upscaled")
            case "quote": verb = L("Quoted")
            default: verb = L("Generated")
            }
            let base = "\(verb) \(count) \(noun)"
            return model != nil ? "\(base) · \(shortModelName)" : base
        case .system:
            if let event = d["event"] {
                switch event {
                case "cleared_by_user", "cleared": return L("Activity log cleared")
                case "pruned": return L("Activity log pruned")
                case "verified": return L("Activity log verified")
                case "exported": return L("Activity log exported")
                case "settings_changed": return L("Activity log settings changed")
                case "recovered": return L("Activity log recovered")
                default: return event.replacingOccurrences(of: "_", with: " ").capitalized
                }
            }
            if let reason = d["reason"], reason.hasPrefix("cleared") { return L("Activity log cleared") }
            return errorMessage ?? path
        }
    }

    /// Plain-language sentence for a `system` chain-of-custody row.
    var systemEventSummary: String? {
        guard category == .system else { return nil }
        let d = egress?.details ?? [:]
        let event = d["event"] ?? (d["reason"]?.hasPrefix("cleared") == true ? "cleared" : nil)
        switch event {
        case "cleared", "cleared_by_user":
            let removed = d["removed_rows"] ?? "?"
            return String(format: L("The user cleared the activity log; %@ rows were removed and the chain anchor moved forward."), removed)
        case "pruned":
            let removed = d["removed_rows"] ?? "?"
            let cutoff = d["cutoff"] ?? "?"
            return String(format: L("Retention removed %@ rows older than %@; the chain anchor moved forward."), removed, cutoff)
        case "verified":
            let records = d["records"] ?? "?"
            if let problems = d["problems"], problems != "0" {
                return String(format: L("Verify ran over %@ records and found %@ problem(s)."), records, problems)
            }
            return String(format: L("Verify ran over %@ records; chain intact."), records)
        case "exported":
            let format = d["format"] ?? "?"
            let records = d["records"] ?? "?"
            let content = d["include_content"] == "true" ? L("with message content") : L("metadata only")
            return String(format: L("Exported %@ records as %@ (%@)."), records, format.uppercased(), content)
        case "settings_changed":
            let retention = d["retention_days"].map { $0 == "forever" ? L("forever") : String(format: L("%@ days"), $0) } ?? "?"
            let store = d["store_content"] == "true" ? L("on") : L("off")
            return String(format: L("Activity Log settings changed: keep %@, store prompts and responses %@."), retention, store)
        case "recovered":
            return String(
                format: L("On open the chain head (seq %@) disagreed with the database tail (seq %@); the log continues from the database."),
                d["expected_seq"] ?? "?", d["found_seq"] ?? "?"
            )
        default:
            return errorMessage
        }
    }

    /// Plain-language label for a `CoreModelService` one-shot
    /// (`/internal/<purpose>`); nil for ordinary chat turns.
    var internalPurposeLabel: String? {
        guard path.hasPrefix("/internal/") else { return nil }
        let raw = String(path.dropFirst("/internal/".count))
        switch raw {
        case "chat_title": return L("Chat title")
        case "follow_up_suggestions": return L("Follow-up suggestions")
        case "memory_distillation": return L("Memory distillation")
        case "transcription_cleanup": return L("Transcription cleanup")
        case "agent_description": return L("Agent description")
        case "compaction": return L("Context compaction")
        case "core_model": return L("Background generation")
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Destination shown in list rows: egress label, else the remote host,
    /// else "This Mac".
    var destinationDisplay: String {
        if let label = egress?.destinationLabel, !label.isEmpty { return label }
        if let host = egress?.destinationHost, !host.isEmpty { return host }
        if let endpoint = connection?.remoteEndpoint, let host = EgressInfo.host(from: endpoint) {
            return host
        }
        return locality == .local ? L("This Mac") : L("Remote")
    }

    /// Day bucket (local calendar) for grouped lists.
    var dayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: timestamp)
    }

    /// Short hash prefix for the integrity line in the detail pane.
    var shortHash: String? {
        hash.map { String($0.prefix(12)) }
    }

    /// Whether this is a plugin console log entry (not an API call)
    var isPluginLog: Bool {
        method == "LOG"
    }

    /// Whether this is an inference request (chat endpoint)
    var isInference: Bool {
        category == .inference || category == .compaction
    }

    /// Whether the request was successful (2xx status)
    var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }

    /// Is this an error state?
    var isError: Bool {
        !isSuccess || finishReason == .error || errorMessage != nil
    }

    /// Formatted timestamp for display
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    /// Formatted duration for display
    var formattedDuration: String {
        if durationMs < 1000 {
            return String(format: "%.0fms", durationMs)
        } else {
            return String(format: "%.1fs", durationMs / 1000)
        }
    }

    /// Formatted tokens per second
    var formattedSpeed: String {
        if let speed = tokensPerSecond, speed > 0 {
            return String(format: "%.1f tok/s", speed)
        }
        return "-"
    }

    /// Short model name for display
    var shortModelName: String {
        guard let model = model else { return "-" }
        if model.lowercased() == "foundation" { return "Foundation" }
        if let lastPart = model.split(separator: "/").last {
            return String(lastPart)
        }
        return model
    }

    /// Truncated request body for display (max 500 chars)
    var truncatedRequestBody: String? {
        guard let body = requestBody else { return nil }
        if body.count > 500 {
            return String(body.prefix(500)) + "..."
        }
        return body
    }

    /// Truncated response body for display (max 1000 chars)
    var truncatedResponseBody: String? {
        guard let body = responseBody else { return nil }
        if body.count > 1000 {
            return String(body.prefix(1000)) + "..."
        }
        return body
    }

    /// Pretty-printed request body if JSON
    var formattedRequestBody: String? {
        guard let body = requestBody, let data = body.data(using: .utf8) else { return requestBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        return body
    }

    /// Pretty-printed response body if JSON
    var formattedResponseBody: String? {
        guard let body = responseBody, let data = body.data(using: .utf8) else { return responseBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        return body
    }

    /// Pretty-printed wire request body if JSON. Same algorithm as
    /// `formattedRequestBody`. Wire bodies are always JSON for the
    /// providers we support (anthropic / openai / gemini / responses
    /// + osaurus-native); the SSE-framed response goes through
    /// `formattedWireResponseBody` instead.
    var formattedWireRequestBody: String? {
        guard
            let body = wireRequestBody,
            let data = body.data(using: .utf8)
        else { return wireRequestBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        return body
    }

    /// Pretty-printed wire response body. Streaming responses arrive
    /// as SSE frames (`data: {...}\n\n`), which JSONSerialization
    /// won't parse as a whole. We return the bytes verbatim in that
    /// case — that's exactly the format the user is trying to
    /// inspect ("did the cloud see the placeholder?").
    var formattedWireResponseBody: String? {
        guard
            let body = wireResponseBody,
            let data = body.data(using: .utf8)
        else { return wireResponseBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        return body
    }

    /// Number of tool definitions sent with the request, parsed on demand
    /// from `requestBody`. Returns nil for non-chat or non-JSON bodies, or
    /// when the request did not include a `tools` array. Computed lazily so
    /// the parse cost is only paid for visible rows.
    var toolDefinitionCount: Int? {
        guard isInference,
            let body = requestBody,
            let data = body.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tools = obj["tools"] as? [Any]
        else { return nil }
        return tools.isEmpty ? nil : tools.count
    }
}

/// Pending inference metadata captured at start
struct PendingInference: Sendable {
    let id: UUID
    let startTime: Date
    let source: RequestSource
    let model: String
    let inputTokens: Int
    let temperature: Float
    let maxTokens: Int

    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        source: RequestSource,
        model: String,
        inputTokens: Int,
        temperature: Float,
        maxTokens: Int
    ) {
        self.id = id
        self.startTime = startTime
        self.source = source
        self.model = model
        self.inputTokens = inputTokens
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - Legacy type alias for backward compatibility

typealias InferenceLog = RequestLog
typealias InferenceSource = RequestSource
