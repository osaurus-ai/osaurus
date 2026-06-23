//
//  InsightsService.swift
//  osaurus
//
//  In-memory request/response logging service for debugging and analytics.
//  Uses a ring buffer to limit memory usage.
//

import Combine
import Foundation

@MainActor
final class InsightsService: ObservableObject {
    static let shared = InsightsService()

    // MARK: - Configuration

    /// Maximum number of logs to retain in memory
    private let maxLogCount: Int = 500

    // MARK: - Published State

    /// All logged requests (most recent first).
    ///
    /// Intentionally NOT `@Published`: it's appended synchronously on every
    /// request, but publishing per insert fired `objectWillChange` per request
    /// and stalled the main actor under sustained traffic. The observable
    /// surface the UI binds to (`filteredLogs`, `stats`, `totalRequestCount`,
    /// `hasLogs`) is refreshed off this buffer by the debounced pipeline below.
    /// Direct reads stay correct because the buffer is the synchronous source
    /// of truth.
    private(set) var logs: [RequestLog] = []

    /// Cumulative request count (may exceed `logs.count` due to the ring
    /// buffer). Incremented synchronously; the published mirror trails it.
    private var totalRequestCountRaw: Int = 0

    /// Debounced, published mirror of `totalRequestCountRaw` for the UI.
    @Published private(set) var totalRequestCount: Int = 0

    /// Published flag mirroring `!logs.isEmpty` so the Clear button stays
    /// reactive without `logs` itself being published. `clear()` resets it
    /// synchronously; otherwise the pipeline updates it.
    @Published private(set) var hasLogs: Bool = false

    /// Active filter for path/model search
    @Published var searchFilter: String = ""

    /// Active filter for source
    @Published var sourceFilter: SourceFilter = .all

    /// Active filter for HTTP method
    @Published var methodFilter: MethodFilter = .all

    // MARK: - Derived Snapshots

    /// Filtered logs based on current filter settings.
    ///
    /// Previously this was a computed property that re-ran a filter over
    /// the (up to 500-entry) ring buffer on every body evaluation of
    /// `InsightsView` — including the body recomputation triggered by
    /// each new logged request. With heavy traffic, the cost of fuzzy
    /// search across `path / model / shortModelName / pluginId` for
    /// every entry, every time, was visible. The pipeline below
    /// recomputes the filter + stats off the synchronous body path,
    /// debounced ~200 ms.
    @Published public private(set) var filteredLogs: [RequestLog] = []

    /// Summary statistics. Recomputed alongside `filteredLogs`.
    @Published public private(set) var stats: InsightsStats = .empty

    /// Log entry that another part of the app asked the Insights tab to
    /// reveal (e.g. the per-message "Insights" button in chat). `InsightsView`
    /// observes this, pushes the matching log into its detail pane, then
    /// clears it back to nil. Nil means no pending request.
    @Published var pendingFocusLogId: UUID?

    private var pipelineCancellable: AnyCancellable?

    /// Carries (snapshot, cumulative count) on each `logs` mutation so the
    /// debounced pipeline can refresh derived state without `logs` being
    /// `@Published`. Passing values (not `self`) keeps the Combine closures off
    /// the main-actor isolation boundary.
    private let logsChanged = PassthroughSubject<([RequestLog], Int), Never>()

    // MARK: - Initialization

    private init() {
        // Seed the snapshots with current (empty) state so the first
        // render of InsightsView has something to show before the
        // pipeline's debounced emission lands.
        stats = Self.computeStats(logs: logs)
        filteredLogs = Self.computeFilteredLogs(
            logs: logs,
            search: searchFilter,
            source: sourceFilter,
            method: methodFilter
        )

        pipelineCancellable = Publishers.CombineLatest4(
            logsChanged.prepend(([RequestLog](), 0)),
            $searchFilter,
            $sourceFilter,
            $methodFilter
        )
        // Drop the synthetic initial emission — we already seeded
        // snapshots above. Without this, `removeDuplicates` would
        // miss the very first user keystroke when it lands inside
        // the debounce window.
        .dropFirst()
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .map { logsAndCount, search, source, method in
            let (snapshot, totalCount) = logsAndCount
            let filtered = Self.computeFilteredLogs(
                logs: snapshot,
                search: search,
                source: source,
                method: method
            )
            let stats = Self.computeStats(logs: snapshot)
            return (filtered, stats, totalCount, !snapshot.isEmpty)
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] filtered, stats, totalCount, hasLogs in
            guard let self else { return }
            self.filteredLogs = filtered
            self.stats = stats
            self.totalRequestCount = totalCount
            self.hasLogs = hasLogs
        }
    }

    private static func computeFilteredLogs(
        logs: [RequestLog],
        search: String,
        source: SourceFilter,
        method: MethodFilter
    ) -> [RequestLog] {
        logs.filter { log in
            if !search.isEmpty {
                let matchesPath = SearchService.matches(query: search, in: log.path)
                let matchesModel = log.model.map { SearchService.matches(query: search, in: $0) } ?? false
                let matchesShortModel = SearchService.matches(query: search, in: log.shortModelName)
                let matchesPlugin = log.pluginId.map { SearchService.matches(query: search, in: $0) } ?? false
                if !matchesPath && !matchesModel && !matchesShortModel && !matchesPlugin {
                    return false
                }
            }

            switch source {
            case .all:
                break
            case .chatUI:
                if log.source != .chatUI { return false }
            case .httpAPI:
                if log.source != .httpAPI { return false }
            case .plugin:
                if log.source != .plugin { return false }
            case .p2p:
                if log.source != .p2p { return false }
            }

            switch method {
            case .all:
                break
            case .get:
                if log.method != "GET" { return false }
            case .post:
                if log.method != "POST" { return false }
            }

            return true
        }
    }

    private static func computeStats(logs: [RequestLog]) -> InsightsStats {
        let total = logs.count
        let successCount = logs.filter { $0.isSuccess }.count
        let successRate = total > 0 ? Double(successCount) / Double(total) * 100 : 0
        let errors = logs.filter { $0.isError }.count
        let avgDuration =
            logs.isEmpty ? 0 : logs.map(\.durationMs).reduce(0, +) / Double(logs.count)

        let inferenceLogs = logs.filter { $0.isInference }
        let totalInputTokens = inferenceLogs.reduce(0) { $0 + ($1.inputTokens ?? 0) }
        let totalOutputTokens = inferenceLogs.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let avgSpeed: Double = {
            let speeds = inferenceLogs.compactMap { $0.tokensPerSecond }
            return speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        }()

        return InsightsStats(
            totalRequests: total,
            successRate: successRate,
            errorCount: errors,
            averageDurationMs: avgDuration,
            inferenceCount: inferenceLogs.count,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            averageSpeed: avgSpeed
        )
    }

    // MARK: - Logging Methods

    /// Log a completed request
    func log(_ request: RequestLog) {
        // Insert at beginning (most recent first). `logs` is the synchronous
        // source of truth; the published UI mirrors refresh via the debounced
        // pipeline so a burst doesn't fire `objectWillChange` per request.
        logs.insert(request, at: 0)
        totalRequestCountRaw += 1

        // Enforce ring buffer limit
        if logs.count > maxLogCount {
            logs.removeLast(logs.count - maxLogCount)
        }

        logsChanged.send((logs, totalRequestCountRaw))
    }

    /// Clear all logs
    func clear() {
        logs.removeAll()
        totalRequestCountRaw = 0
        pendingFocusLogId = nil

        // Reflect the cleared state immediately — the Clear button expects an
        // instant empty list — then let the pipeline settle the rest.
        totalRequestCount = 0
        hasLogs = false
        filteredLogs = []
        stats = .empty
        logsChanged.send((logs, totalRequestCountRaw))
    }

    /// Ask the Insights tab to reveal the most recent log produced by the
    /// given chat assistant turn. Returns false when no matching log exists
    /// (e.g. it was evicted from the ring buffer or cleared), in which case
    /// the caller may still open the tab to show the full list.
    @discardableResult
    func focus(turnId: UUID) -> Bool {
        guard let match = logs.first(where: { $0.turnId == turnId }) else {
            return false
        }
        focus(log: match)
        return true
    }

    /// Ask the Insights tab to reveal the most recent log for a request-level
    /// router id. Prefer this over turn focus for Credits rows because agent
    /// loops can produce multiple request logs for the same assistant turn.
    @discardableResult
    func focus(requestId: String) -> Bool {
        let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            let match = logs.first(where: { $0.requestId == normalized })
        else {
            return false
        }
        focus(log: match)
        return true
    }

    /// True when an in-memory request log still exists for this assistant turn.
    /// Logs are intentionally ephemeral, so callers use this to decide whether
    /// to surface an Insights affordance without mutating focus state.
    func hasLog(turnId: UUID) -> Bool {
        logs.contains { $0.turnId == turnId }
    }

    /// True when an in-memory request log still exists for this request id.
    func hasLog(requestId: String) -> Bool {
        let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return logs.contains { $0.requestId == normalized }
    }

    private func focus(log: RequestLog) {
        // Reassign even if it already equals the target id so a second tap
        // re-pushes the detail pane after the user backed out of it.
        pendingFocusLogId = nil
        pendingFocusLogId = log.id
    }

    /// Clear filters
    func clearFilters() {
        searchFilter = ""
        sourceFilter = .all
        methodFilter = .all
    }

    // MARK: - Connection Activity

    /// Outbound activity for a paired remote agent, keyed by its provider id.
    /// Drives the Activity section of `RemoteAgentDetailView`.
    func activity(forProviderId providerId: UUID) -> ConnectionActivitySummary {
        summarize(logs.filter { $0.connection?.providerId == providerId })
    }

    /// Inbound activity attributed to a specific paired access key (host side).
    /// Drives per-connection usage in the Remote Connections view.
    func activity(forAccessKeyId keyId: String) -> ConnectionActivitySummary {
        let trimmed = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ConnectionActivitySummary() }
        return summarize(logs.filter { $0.connection?.accessKeyId == trimmed })
    }

    /// Inbound activity for an agent-address audience (host-side fallback for
    /// rows whose individual key id hasn't been attributed yet).
    func activity(forAudience audience: String) -> ConnectionActivitySummary {
        let trimmed = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ConnectionActivitySummary() }
        return summarize(logs.filter { $0.connection?.audience == trimmed })
    }

    private func summarize(_ matched: [RequestLog]) -> ConnectionActivitySummary {
        guard !matched.isEmpty else { return ConnectionActivitySummary() }
        let speeds = matched.compactMap { $0.tokensPerSecond }
        let avg = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        return ConnectionActivitySummary(
            requestCount: matched.count,
            lastUsed: matched.map(\.timestamp).max(),
            averageSpeed: avg,
            totalOutputTokens: matched.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        )
    }

    /// Focus the Insights tab on the most recent outbound request for a provider.
    @discardableResult
    func focus(providerId: UUID) -> Bool {
        guard let match = logs.first(where: { $0.connection?.providerId == providerId })
        else { return false }
        focus(log: match)
        return true
    }

    /// Focus the Insights tab on the most recent inbound request for an access key.
    @discardableResult
    func focus(accessKeyId: String) -> Bool {
        let trimmed = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let match = logs.first(where: { $0.connection?.accessKeyId == trimmed })
        else { return false }
        focus(log: match)
        return true
    }
}

/// Aggregate usage for a remote connection, derived from the in-memory ring
/// buffer. Used by `RemoteAgentDetailView` (outbound, by providerId) and the
/// host-side Remote Connections view (inbound, by accessKeyId / audience).
struct ConnectionActivitySummary: Equatable {
    var requestCount: Int = 0
    var lastUsed: Date?
    /// Average tok/s across matched inference rows that recorded a speed.
    var averageSpeed: Double = 0
    var totalOutputTokens: Int = 0

    var isEmpty: Bool { requestCount == 0 }

    var formattedAvgSpeed: String {
        averageSpeed > 0 ? String(format: "%.1f tok/s", averageSpeed) : "-"
    }
}

// MARK: - Supporting Types

enum SourceFilter: String, CaseIterable {
    case all = "All"
    case chatUI = "Chat"
    case httpAPI = "HTTP"
    case plugin = "Plugin"
    case p2p = "P2P"

    var displayName: String {
        switch self {
        case .all: return L("All")
        case .chatUI: return L("Chat")
        case .httpAPI: return "HTTP"
        case .plugin: return L("Plugin")
        case .p2p: return L("P2P")
        }
    }
}

enum MethodFilter: String, CaseIterable {
    case all = "All"
    case get = "GET"
    case post = "POST"

    var displayName: String {
        switch self {
        case .all: return L("All")
        case .get: return "GET"
        case .post: return "POST"
        }
    }
}

struct InsightsStats: Equatable {
    let totalRequests: Int
    let successRate: Double
    let errorCount: Int
    let averageDurationMs: Double

    // Inference-specific stats
    let inferenceCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let averageSpeed: Double

    static let empty = InsightsStats(
        totalRequests: 0,
        successRate: 0,
        errorCount: 0,
        averageDurationMs: 0,
        inferenceCount: 0,
        totalInputTokens: 0,
        totalOutputTokens: 0,
        averageSpeed: 0
    )

    var formattedSuccessRate: String {
        String(format: "%.0f%%", successRate)
    }

    var formattedAvgSpeed: String {
        if averageSpeed > 0 {
            return String(format: "%.1f tok/s", averageSpeed)
        }
        return "-"
    }

    var formattedAvgDuration: String {
        if averageDurationMs < 1000 {
            return String(format: "%.0fms", averageDurationMs)
        } else {
            return String(format: "%.1fs", averageDurationMs / 1000)
        }
    }
}

// MARK: - Nonisolated Logging Interface

extension InsightsService {
    /// Maximum stored body size (256 KB) to cap ring buffer memory usage.
    /// Sized to fit realistic chat completion requests (long system prompts,
    /// tool definitions, multi-turn history) without truncation in the
    /// common case while still bounding the 500-entry ring buffer to a few
    /// hundred MB worst-case.
    private nonisolated static let maxBodySize = 262_144

    /// Defense-in-depth credential redactors run on every logged body so a
    /// future caller that forgets to scrub a `/pair` response (or any other
    /// shape that carries an `osk-v1` token) still does not leak the key into
    /// the request log ring buffer. The regexes target the credential value
    /// itself and replace it with a marker — surrounding structure (JSON keys
    /// or header names) is preserved.
    private nonisolated static let bearerTokenRegex: NSRegularExpression? = {
        // Match the token after a `Bearer` scheme (header or stringified header).
        try? NSRegularExpression(
            pattern: #"(?i)(bearer\s+)osk-[A-Za-z0-9._-]+"#,
            options: []
        )
    }()

    private nonisolated static let oskValueRegex: NSRegularExpression? = {
        // Match osk-v1.<payload>.<sig> when it appears as a JSON string value.
        try? NSRegularExpression(
            pattern: #""osk-[A-Za-z0-9._-]+""#,
            options: []
        )
    }()

    /// Internal so tests can verify the redactor's surface independent of
    /// the ring buffer plumbing.
    nonisolated static func redactCredentials(_ body: String) -> String {
        var redacted = body
        let nsRange = { (s: String) -> NSRange in NSRange(s.startIndex ..< s.endIndex, in: s) }
        if let regex = bearerTokenRegex {
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: nsRange(redacted),
                withTemplate: "$1<redacted>"
            )
        }
        if let regex = oskValueRegex {
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: nsRange(redacted),
                withTemplate: "\"<redacted>\""
            )
        }
        return redacted
    }

    private nonisolated static func truncateBody(_ body: String?) -> String? {
        guard let body else { return nil }
        let scrubbed = redactCredentials(body)
        guard scrubbed.count > maxBodySize else { return scrubbed }
        // Surface the original size so a user looking at a clipped body in
        // the detail pane knows whether they're missing 1 KB or 1 MB.
        let originalBytes = scrubbed.utf8.count
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(originalBytes),
            countStyle: .binary
        )
        return String(scrubbed.prefix(maxBodySize)) + "\n…[truncated, original \(formatted)]"
    }

    /// Thread-safe logging from non-main-actor contexts
    nonisolated static func logRequest(
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
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil,
        wireRequestBody: Data? = nil,
        wireResponseBody: Data? = nil,
        connection: RequestConnectionInfo? = nil
    ) {
        let trimmedRequest = truncateBody(requestBody)
        let trimmedResponse = truncateBody(responseBody)
        // Wire bodies are passed as `Data` so the probe doesn't have
        // to pay an utf8 -> String cost on the stream hot path. We
        // do the decode + truncate here, on the main-actor Task
        // hop, so insights logging stays off the critical streaming
        // thread.
        let trimmedWireRequest = truncateBody(
            wireRequestBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        let trimmedWireResponse = truncateBody(
            wireResponseBody.flatMap { String(data: $0, encoding: .utf8) }
        )

        Task { @MainActor in
            let log = RequestLog(
                source: source,
                turnId: turnId,
                requestId: requestId,
                method: method,
                path: path,
                statusCode: statusCode,
                durationMs: durationMs,
                requestBody: trimmedRequest,
                responseBody: trimmedResponse,
                userAgent: userAgent,
                pluginId: pluginId,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                temperature: temperature,
                maxTokens: maxTokens,
                toolCalls: toolCalls,
                finishReason: finishReason,
                errorMessage: errorMessage,
                wireRequestBody: trimmedWireRequest,
                wireResponseBody: trimmedWireResponse,
                connection: connection
            )
            shared.log(log)
        }
    }

    /// Legacy compatibility for ChatEngine inference logging.
    /// Accepts optional `requestBody`/`responseBody` so Chat UI inferences
    /// can surface the same level of detail as HTTP API requests in the
    /// Insights detail pane (system prompt, tools, accumulated assistant
    /// text). Defaults are nil to preserve existing call-site ergonomics.
    nonisolated static func logInference(
        source: RequestSource,
        turnId: UUID? = nil,
        requestId: String? = nil,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Double,
        temperature: Float?,
        maxTokens: Int,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason = .stop,
        errorMessage: String? = nil,
        requestBody: String? = nil,
        responseBody: String? = nil,
        wireRequestBody: Data? = nil,
        wireResponseBody: Data? = nil,
        connection: RequestConnectionInfo? = nil,
        path: String = "/chat/completions"
    ) {
        logRequest(
            source: source,
            turnId: turnId,
            requestId: requestId,
            method: "POST",
            path: path,
            statusCode: errorMessage != nil ? 500 : 200,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage,
            wireRequestBody: wireRequestBody,
            wireResponseBody: wireResponseBody,
            connection: connection
        )
    }

    /// Resolve the Insights source category for an HTTP-logged request.
    /// In-app chat (`method == "CHAT"`) stays `.chatUI`. Anything that arrived
    /// over the Secure Channel is another Osaurus peer (remote chat completions
    /// or a remote agent run) and is surfaced under `.p2p`; all other
    /// local/LAN HTTP traffic remains `.httpAPI`.
    nonisolated static func inboundSource(
        method: String,
        transport: RequestTransport?
    ) -> RequestSource {
        if method == "CHAT" { return .chatUI }
        return transport == .secureChannel ? .p2p : .httpAPI
    }

    /// Logs HTTP requests with optional inference data
    nonisolated static func logAsync(
        method: String,
        path: String,
        clientIP: String = "127.0.0.1",
        userAgent: String? = nil,
        requestBody: String? = nil,
        responseBody: String? = nil,
        responseStatus: Int,
        durationMs: Double,
        model: String? = nil,
        tokensInput: Int? = nil,
        tokensOutput: Int? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil,
        connection: RequestConnectionInfo? = nil
    ) {
        let source = Self.inboundSource(method: method, transport: connection?.transport)

        logRequest(
            source: source,
            method: method == "CHAT" ? "POST" : method,
            path: path,
            statusCode: responseStatus,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            userAgent: userAgent,
            model: model,
            inputTokens: tokensInput,
            outputTokens: tokensOutput,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage,
            connection: connection
        )
    }
}
