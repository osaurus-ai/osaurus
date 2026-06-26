//
//  RequestLog.swift
//  osaurus
//
//  Model for in-memory request/response logging used by InsightsService.
//

import Foundation

/// Represents a logged tool call within an inference
struct ToolCallLog: Identifiable, Sendable {
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
        self.arguments = arguments
        self.result = result
        self.durationMs = durationMs
        self.isError = isError
    }
}

/// Source of the request
enum RequestSource: String, Sendable, CaseIterable {
    case chatUI = "Chat UI"
    case httpAPI = "HTTP API"
    case plugin = "Plugin"
    /// Inbound traffic from another Osaurus peer over the Secure Channel
    /// (remote chat completions and remote agent runs).
    case p2p = "P2P"

    var displayName: String {
        switch self {
        case .chatUI: return L("Chat UI")
        case .httpAPI: return L("HTTP API")
        case .plugin: return L("Plugin")
        case .p2p: return L("P2P")
        }
    }
}

/// How a request reached its model — distinguishes a purely local run from
/// the two remote shapes so Insights doesn't conflate "the local Apple model
/// ran" with "a remote agent ran its own loop".
enum RequestMode: String, Sendable {
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
enum RequestTransport: String, Sendable {
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
struct RequestConnectionInfo: Sendable, Equatable {
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

/// Represents a single request log entry with optional inference data
struct RequestLog: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let source: RequestSource

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
        connection: RequestConnectionInfo? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
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
        self.connection = (connection?.isEmpty == true) ? nil : connection

        // Calculate tokens per second if we have inference data
        if let outputTokens = outputTokens, durationMs > 0 {
            self.tokensPerSecond = Double(outputTokens) / (durationMs / 1000.0)
        } else {
            self.tokensPerSecond = nil
        }
    }

    enum FinishReason: String, Sendable {
        case stop = "stop"
        case length = "length"
        case toolCalls = "tool_calls"
        case error = "error"
        case cancelled = "cancelled"
    }

    // MARK: - Computed Properties

    /// Whether this is a plugin console log entry (not an API call)
    var isPluginLog: Bool {
        method == "LOG"
    }

    /// Whether this is an inference request (chat endpoint)
    var isInference: Bool {
        path.contains("chat")
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
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
            return prettyString
        }
        return body
    }

    /// Pretty-printed response body if JSON
    var formattedResponseBody: String? {
        guard let body = responseBody, let data = body.data(using: .utf8) else { return responseBody }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
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
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
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
            let prettyString = String(data: prettyData, encoding: .utf8)
        {
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
