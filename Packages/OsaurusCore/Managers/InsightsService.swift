//
//  InsightsService.swift
//  osaurus
//
//  Facade over the persisted activity / audit log (`ActivityLogStore`).
//  Every emitter in the app (`ChatEngine`, `HTTPHandler`, search, MCP,
//  channels, Router, plugins) calls the nonisolated `logRequest` /
//  `logInference` / `logAsync` helpers below. The service:
//
//    - scrubs credentials and clips bodies,
//    - applies the user's content policy (`ActivityLogSettings`),
//    - keeps a small hot cache so synchronous callers (`hasLog`, `focus`,
//      Remote Connections activity) answer instantly for recent rows,
//    - writes through to the store off the main thread, and
//    - publishes paged, filtered rows + a summary for the Insights tab.
//

import Combine
import Foundation

@MainActor
final class InsightsService: ObservableObject {
    static let shared = InsightsService()

    // MARK: - Configuration

    /// Hot-cache size. Recent rows are kept in memory so the per-message
    /// "Insights" button and Remote Connections usage can answer
    /// synchronously; everything older is served from the store.
    private let maxLogCount: Int = 500

    /// Page size for the dashboard list.
    static let pageSize = 100

    // MARK: - Hot cache

    /// Most recent rows (most recent first). Entries are replaced with
    /// their chained copy (`seq`/`hash` set) once the store confirms the
    /// append.
    private(set) var logs: [RequestLog] = []

    /// Cumulative rows logged this process lifetime (not the store count).
    private var totalRequestCountRaw: Int = 0

    // MARK: - Published state

    /// Store row count after the current filter. Trails writes by the
    /// debounce window.
    @Published private(set) var totalRequestCount: Int = 0

    /// Whether any row exists (store or hot cache). Drives Clear/Export.
    @Published private(set) var hasLogs: Bool = false

    /// Current narrowing criteria. Changing it reloads the first page.
    @Published var filter: ActivityFilter = .empty

    /// Rows for the current filter, first `pageSize * pagesLoaded`.
    @Published private(set) var pagedLogs: [RequestLog] = []

    /// Aggregates for the current filter (egress card + stats bar).
    @Published private(set) var summary: ActivitySummary = .empty

    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false

    /// Distinct values for filter menus.
    @Published private(set) var knownDestinations: [String] = []
    @Published private(set) var knownModels: [String] = []
    @Published private(set) var knownAgents: [String] = []

    /// Last integrity check result, if the user ran one this session.
    @Published private(set) var lastVerification: ActivityLogVerification?
    @Published private(set) var isVerifying = false

    /// Non-nil when the store could not be opened; the hot cache still works.
    @Published private(set) var storeError: String?

    /// Row that another part of the app asked the Insights tab to reveal.
    @Published var pendingFocusLogId: UUID?

    /// Current retention / content policy.
    @Published private(set) var settings: ActivityLogSettings = ActivityLogSettingsStore.snapshot()

    // MARK: - Private

    private let store: ActivityLogStore
    private var storeAvailable = false
    private var pagesLoaded = 1
    private var cancellables = Set<AnyCancellable>()
    /// Fired on every append / clear so the dashboard refreshes (debounced).
    private let changed = PassthroughSubject<Void, Never>()
    private var retentionTimer: Timer?

    // MARK: - Initialization

    private convenience init() {
        self.init(store: .shared, openStore: true)
    }

    /// Designated initializer. Tests pass an in-memory store with
    /// `openStore: false` after opening it themselves.
    init(store: ActivityLogStore, openStore: Bool) {
        self.store = store
        if openStore {
            do {
                try store.open()
                storeAvailable = true
            } catch {
                storeAvailable = false
                storeError = error.localizedDescription
                NSLog("[Osaurus][Insights] activity log unavailable: %@", "\(error)")
            }
        } else {
            storeAvailable = store.isOpen
        }

        // Filter edits and new rows both funnel into one debounced reload.
        $filter
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pagesLoaded = 1
                self?.reload()
            }
            .store(in: &cancellables)

        changed
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .activityLogSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settings = ActivityLogSettingsStore.snapshot()
                self.pruneForRetention()
            }
            .store(in: &cancellables)

        if openStore {
            pruneForRetention()
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pruneForRetention() }
            }
        }
        reload()
    }

    // MARK: - Logging

    /// Record a completed interaction. Synchronous into the hot cache,
    /// asynchronous into the store.
    func log(_ request: RequestLog) {
        let record = settings.storeContent ? request : request.withoutContent()

        logs.insert(record, at: 0)
        totalRequestCountRaw += 1
        if logs.count > maxLogCount {
            logs.removeLast(logs.count - maxLogCount)
        }
        hasLogs = true

        guard storeAvailable else {
            changed.send()
            return
        }
        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            do {
                let chained = try store.append(record)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let index = self.logs.firstIndex(where: { $0.id == chained.id }) {
                        self.logs[index] = chained
                    }
                    self.changed.send()
                }
            } catch {
                NSLog("[Osaurus][Insights] append failed: %@", "\(error)")
                await MainActor.run { [weak self] in self?.storeError = error.localizedDescription }
            }
        }
    }

    /// Remove every row (store + hot cache). The store records a tombstone.
    func clear() {
        logs.removeAll()
        totalRequestCountRaw = 0
        pendingFocusLogId = nil
        pagedLogs = []
        summary = .empty
        totalRequestCount = 0
        hasLogs = false
        guard storeAvailable else { return }
        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            do {
                try store.clear()
            } catch {
                NSLog("[Osaurus][Insights] clear failed: %@", "\(error)")
            }
            await MainActor.run { [weak self] in self?.changed.send() }
        }
    }

    // MARK: - Lookup / focus

    /// Row by id: hot cache first, then the store.
    func log(id: UUID) -> RequestLog? {
        if let hit = logs.first(where: { $0.id == id }) { return hit }
        guard storeAvailable else { return nil }
        return try? store.find(id: id)
    }

    @discardableResult
    func focus(turnId: UUID) -> Bool {
        if let match = logs.first(where: { $0.turnId == turnId }) {
            focus(log: match)
            return true
        }
        guard storeAvailable, let match = try? store.find(turnId: turnId) else { return false }
        focus(log: match)
        return true
    }

    @discardableResult
    func focus(requestId: String) -> Bool {
        let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if let match = logs.first(where: { $0.requestId == normalized }) {
            focus(log: match)
            return true
        }
        guard storeAvailable, let match = try? store.find(requestId: normalized) else { return false }
        focus(log: match)
        return true
    }

    func hasLog(turnId: UUID) -> Bool {
        if logs.contains(where: { $0.turnId == turnId }) { return true }
        guard storeAvailable else { return false }
        return (try? store.exists(turnId: turnId)) ?? false
    }

    func hasLog(requestId: String) -> Bool {
        let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if logs.contains(where: { $0.requestId == normalized }) { return true }
        guard storeAvailable else { return false }
        return ((try? store.find(requestId: normalized)) ?? nil) != nil
    }

    private func focus(log: RequestLog) {
        // Reassign even if it already equals the target id so a second tap
        // re-pushes the detail pane after the user backed out of it.
        pendingFocusLogId = nil
        pendingFocusLogId = log.id
    }

    // MARK: - Filters / paging

    func clearFilters() {
        filter = .empty
    }

    /// Re-query the store for the current filter.
    func reload() {
        guard storeAvailable else {
            // Hot-cache fallback keeps the tab useful if the store is down.
            let filtered = Self.filterInMemory(logs, filter)
            pagedLogs = filtered
            totalRequestCount = filtered.count
            hasLogs = !logs.isEmpty
            canLoadMore = false
            summary = Self.summarizeInMemory(filtered)
            return
        }
        let store = self.store
        let filter = self.filter
        let limit = Self.pageSize * pagesLoaded
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let rows = (try? store.fetch(filter: filter, limit: limit)) ?? []
            let count = (try? store.count(filter: filter)) ?? rows.count
            let summary = (try? store.summary(filter: filter)) ?? .empty
            let anyRows = filter.isEmpty ? count > 0 : ((try? store.count()) ?? 0) > 0
            let hosts = (try? store.distinctValues(column: .destinationHost)) ?? []
            let models = (try? store.distinctValues(column: .model)) ?? []
            let agents = (try? store.distinctValues(column: .agentName)) ?? []
            await MainActor.run { [weak self] in
                guard let self, self.filter == filter else { return }
                self.pagedLogs = rows
                self.totalRequestCount = count
                self.summary = summary
                self.canLoadMore = rows.count < count
                self.hasLogs = anyRows || !self.logs.isEmpty
                self.knownDestinations = hosts
                self.knownModels = models
                self.knownAgents = agents
                self.isLoading = false
            }
        }
    }

    func loadMore() {
        guard canLoadMore, !isLoading else { return }
        pagesLoaded += 1
        reload()
    }

    // MARK: - Integrity / retention

    func verify() {
        guard storeAvailable, !isVerifying else { return }
        isVerifying = true
        let store = self.store
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? store.verify()
            // The check is on the record too: who verified, when, what the
            // head was, and whether anything was wrong at the time.
            if let result { _ = try? store.recordVerification(result) }
            await MainActor.run { [weak self] in
                self?.lastVerification = result
                self?.isVerifying = false
                self?.changed.send()
            }
        }
    }

    /// Another component appended to the store directly (export row); refresh.
    func noteExternalStoreChange() {
        changed.send()
    }

    /// Drop rows older than the configured retention. Safe to call often.
    func pruneForRetention() {
        guard storeAvailable, let cutoff = settings.retentionCutoff() else { return }
        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            let removed = (try? store.prune(olderThan: cutoff)) ?? 0
            if removed > 0 {
                await MainActor.run { [weak self] in self?.changed.send() }
            }
        }
    }

    /// Update and persist the policy (Privacy › Activity Log). A real change
    /// is itself recorded on the chain — a reviewer must be able to see when
    /// retention was shortened or content capture turned off.
    func updateSettings(_ newValue: ActivityLogSettings) {
        let previous = settings
        settings = newValue
        ActivityLogSettingsStore.save(newValue)
        guard previous != newValue, storeAvailable else { return }
        let store = self.store
        let details: [String: String] = [
            "retention_days": newValue.retentionDays.map(String.init) ?? "forever",
            "store_content": newValue.storeContent ? "true" : "false",
            "previous_retention_days": previous.retentionDays.map(String.init) ?? "forever",
            "previous_store_content": previous.storeContent ? "true" : "false",
        ]
        Task.detached(priority: .utility) { [weak self] in
            _ = try? store.appendSystemEvent("settings_changed", details: details)
            await MainActor.run { [weak self] in self?.changed.send() }
        }
    }

    /// Direct store access for export.
    var activityStore: ActivityLogStore? { storeAvailable ? store : nil }

    // MARK: - Connection Activity

    /// Outbound activity for a paired remote agent, keyed by its provider id.
    func activity(forProviderId providerId: UUID) -> ConnectionActivitySummary {
        richer(
            store: storeAvailable ? try? store.connectionActivity(column: "provider_id", value: providerId.uuidString) : nil,
            hot: summarize(logs.filter { $0.connection?.providerId == providerId })
        )
    }

    /// Inbound activity attributed to a specific paired access key (host side).
    func activity(forAccessKeyId keyId: String) -> ConnectionActivitySummary {
        let trimmed = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ConnectionActivitySummary() }
        return richer(
            store: storeAvailable ? try? store.connectionActivity(column: "access_key_id", value: trimmed) : nil,
            hot: summarize(logs.filter { $0.connection?.accessKeyId == trimmed })
        )
    }

    /// Inbound activity for an agent-address audience.
    func activity(forAudience audience: String) -> ConnectionActivitySummary {
        let trimmed = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ConnectionActivitySummary() }
        return richer(
            store: storeAvailable ? try? store.connectionActivity(column: "audience", value: trimmed) : nil,
            hot: summarize(logs.filter { $0.connection?.audience == trimmed })
        )
    }

    /// The persisted store is the long-term source of truth, but rows reach it
    /// asynchronously. Prefer whichever view has seen more rows so a summary
    /// read right after `log(_:)` never under-counts; ties go to the hot cache
    /// (exact timestamps, no millisecond rounding).
    private func richer(store: ConnectionActivitySummary?, hot: ConnectionActivitySummary) -> ConnectionActivitySummary {
        guard let store, store.requestCount > hot.requestCount else { return hot }
        return store
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

    @discardableResult
    func focus(providerId: UUID) -> Bool {
        if let match = logs.first(where: { $0.connection?.providerId == providerId }) {
            focus(log: match)
            return true
        }
        guard storeAvailable, let match = try? store.find(providerId: providerId) else { return false }
        focus(log: match)
        return true
    }

    @discardableResult
    func focus(accessKeyId: String) -> Bool {
        let trimmed = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let match = logs.first(where: { $0.connection?.accessKeyId == trimmed }) {
            focus(log: match)
            return true
        }
        guard storeAvailable, let match = try? store.find(accessKeyId: trimmed) else { return false }
        focus(log: match)
        return true
    }

    // MARK: - In-memory fallbacks

    nonisolated static func filterInMemory(_ logs: [RequestLog], _ f: ActivityFilter) -> [RequestLog] {
        let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bounds = f.dateRange.bounds()
        return logs.filter { log in
            if !text.isEmpty {
                let hay = [log.title, log.path, log.model ?? "", log.destinationDisplay, log.pluginId ?? "", log.agentName ?? ""]
                    .joined(separator: " ").lowercased()
                if !hay.contains(text) { return false }
            }
            if let bounds, log.timestamp < bounds.start || log.timestamp >= bounds.end { return false }
            if let locality = f.locality, log.locality != locality { return false }
            if !f.categories.isEmpty, !f.categories.contains(log.category) { return false }
            if !f.sources.isEmpty, !f.sources.contains(log.source) { return false }
            if let host = f.destinationHost, (log.egress?.destinationHost ?? EgressInfo.host(from: log.connection?.remoteEndpoint)) != host { return false }
            if let model = f.model, log.model != model { return false }
            if let agentId = f.agentId, log.agentId != agentId { return false }
            switch f.status {
            case .all: break
            case .success: if log.isError { return false }
            case .error: if !log.isError { return false }
            }
            if let pf = f.privacyFilterApplied, (log.egress?.privacyFilterApplied ?? false) != pf { return false }
            if !f.includePluginLogs, log.category == .pluginLog { return false }
            return true
        }
    }

    nonisolated static func summarizeInMemory(_ logs: [RequestLog]) -> ActivitySummary {
        var s = ActivitySummary()
        s.totalCount = logs.count
        s.localCount = logs.filter { $0.locality == .local }.count
        s.remoteCount = logs.filter { $0.locality == .remote }.count
        s.errorCount = logs.filter { $0.isError }.count
        s.averageDurationMs = logs.isEmpty ? 0 : logs.map(\.durationMs).reduce(0, +) / Double(logs.count)
        s.inferenceCount = logs.filter { $0.category == .inference }.count
        s.searchCount = logs.filter { $0.category == .webSearch }.count
        s.extractCount = logs.filter { $0.category == .urlExtract }.count
        s.mcpCount = logs.filter { $0.category == .mcpToolCall }.count
        s.totalInputTokens = logs.reduce(0) { $0 + ($1.inputTokens ?? 0) }
        s.totalOutputTokens = logs.reduce(0) { $0 + ($1.outputTokens ?? 0) }
        let speeds = logs.compactMap(\.tokensPerSecond).filter { $0 > 0 }
        s.averageSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        s.bytesSent = logs.reduce(0) { $0 + ($1.egress?.bytesSent ?? 0) }
        s.bytesReceived = logs.reduce(0) { $0 + ($1.egress?.bytesReceived ?? 0) }
        s.privacyFilteredCount = logs.filter { $0.egress?.privacyFilterApplied == true }.count
        s.redactedSpanTotal = logs.reduce(0) { $0 + ($1.egress?.redactedSpanCount ?? 0) }
        s.earliest = logs.map(\.timestamp).min()
        s.latest = logs.map(\.timestamp).max()
        var byDest: [String: ActivityDestinationSummary] = [:]
        for log in logs where log.locality == .remote {
            let host = log.egress?.destinationHost ?? EgressInfo.host(from: log.connection?.remoteEndpoint) ?? ""
            let label = log.egress?.destinationLabel ?? (host.isEmpty ? L("Unknown") : host)
            let key = host.isEmpty ? label : host
            let prev = byDest[key]
            byDest[key] = ActivityDestinationSummary(
                label: label,
                host: host,
                count: (prev?.count ?? 0) + 1,
                bytesSent: (prev?.bytesSent ?? 0) + (log.egress?.bytesSent ?? 0),
                bytesReceived: (prev?.bytesReceived ?? 0) + (log.egress?.bytesReceived ?? 0),
                errorCount: (prev?.errorCount ?? 0) + (log.isError ? 1 : 0),
                lastSeen: max(prev?.lastSeen ?? .distantPast, log.timestamp)
            )
        }
        s.destinations = byDest.values.sorted { $0.count > $1.count }
        return s
    }
}

/// Aggregate usage for a remote connection. Used by `RemoteAgentDetailView`
/// (outbound, by providerId) and the host-side Remote Connections view
/// (inbound, by accessKeyId / audience).
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

    /// Upstream-provider credential regexes. The log ring buffer can capture
    /// chat bodies forwarded to remote providers, and the request/response
    /// detail pane echoes headers, so an Authorization/x-api-key header or an
    /// `sk-`/JWT-shaped value could otherwise land in the buffer verbatim.
    /// These mirror `ProviderDiagnosticRedactor` so the local log holds to the
    /// same "no third-party secrets at rest" bar as the provider diagnostics.
    private nonisolated static let upstreamRedactors: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            // Any Bearer token (not just Osaurus `osk-`): OpenAI/Anthropic/etc.
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1<redacted>"),
            // `sk-…` / `sk-ant-…` style keys (JSON value, header, prose). The
            // lookbehind keeps this from matching *inside* other token shapes
            // — notably the `sk-` tail of Osaurus `osk-v1.…` keys, whose bare
            // prose form is deliberately left alone (see redactor contract).
            (#"(?<![A-Za-z0-9])sk-[A-Za-z0-9._-]{8,}"#, "<redacted>"),
            // JSON-Web-Token shaped values (id/access tokens).
            (#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "<redacted>"),
            // Workspaces membership attestations and wallet signatures as
            // they appear in `/pair-invite` envelopes: `"attestation": "<b64url>.<b64url>"`
            // (two segments, so the JWT rule above misses it) and
            // `"wallet_signature": "0x<130 hex>"`. Keyed on the field name
            // so ordinary two-segment strings elsewhere are left alone.
            (
                #"(?i)("(?:attestation|wallet_signature|caller_attestation)"\s*:\s*)"[^"]*""#,
                "$1\"<redacted>\""
            ),
            // Header-style secret carriers: `x-api-key: v`, `api-key=v`,
            // `x-goog-api-key: v`, and stringified `"authorization": "v"`.
            // `Bearer …` authorization values are excluded: the Bearer regex
            // above already scrubbed the token and must keep the scheme word
            // visible (`Bearer <redacted>`), so redacting the first token of
            // the value here would just eat the word "Bearer".
            (
                #"(?i)("?(?:x-api-key|x-goog-api-key|api-key|authorization)"?\s*[:=]\s*"?)(?!bearer\b)[^"\s,;}]+"#,
                "$1<redacted>"
            ),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern, options: [])).map { ($0, template) }
        }
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
        for (regex, template) in upstreamRedactors {
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: nsRange(redacted),
                withTemplate: template
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
        connection: RequestConnectionInfo? = nil,
        category: ActivityCategory? = nil,
        locality: DataLocality? = nil,
        egress: EgressInfo? = nil,
        agentId: UUID? = nil,
        agentName: String? = nil,
        sessionId: UUID? = nil,
        clientIP: String? = nil
    ) {
        let trimmedRequest = truncateBody(requestBody)
        let trimmedResponse = truncateBody(responseBody)
        // Byte counts default to the wire body sizes when the caller didn't
        // measure them; the egress card sums these per destination.
        var resolvedEgress = egress
        if resolvedEgress != nil || wireRequestBody != nil {
            var e = resolvedEgress ?? EgressInfo()
            if e.bytesSent == nil, let wireRequestBody { e.bytesSent = wireRequestBody.count }
            if e.bytesReceived == nil, let wireResponseBody { e.bytesReceived = wireResponseBody.count }
            if !e.details.isEmpty {
                e.details = e.details.mapValues { redactCredentials($0) }
            }
            resolvedEgress = e
        }
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
                connection: connection,
                category: category,
                locality: locality,
                egress: resolvedEgress,
                agentId: agentId,
                agentName: agentName,
                sessionId: sessionId,
                clientIP: clientIP
            )
            shared.log(log)
        }
    }

    /// Record an outbound, non-inference egress event (web search, URL
    /// fetch, MCP call, channel delivery, Router control call). Always
    /// `.remote`; `source` defaults to `.tool`.
    nonisolated static func logEgress(
        category: ActivityCategory,
        source: RequestSource = .tool,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        egress: EgressInfo,
        locality: DataLocality = .remote,
        requestBody: String? = nil,
        responseBody: String? = nil,
        errorMessage: String? = nil,
        toolCalls: [ToolCallLog]? = nil,
        attribution: ActivityAttribution = .none,
        turnId: UUID? = nil
    ) {
        logRequest(
            source: source,
            turnId: turnId,
            method: method,
            path: path,
            statusCode: statusCode,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            toolCalls: toolCalls,
            finishReason: errorMessage == nil ? nil : .error,
            errorMessage: errorMessage,
            category: category,
            locality: locality,
            egress: egress,
            agentId: attribution.agentId,
            agentName: attribution.agentName,
            sessionId: attribution.sessionId
        )
    }

    /// Who is driving the current unit of work, for activity-log attribution.
    /// Read from `ChatExecutionContext` task-locals on the caller's task —
    /// they are not visible inside `Task.detached` producers, so emitters
    /// capture this up-front and pass it along.
    struct ActivityAttribution: Sendable, Equatable {
        var agentId: UUID?
        var agentName: String?
        var sessionId: UUID?

        static let none = ActivityAttribution()

        init(agentId: UUID? = nil, agentName: String? = nil, sessionId: UUID? = nil) {
            self.agentId = agentId
            self.agentName = agentName ?? agentId.flatMap { AgentManager.agentDisplayName(for: $0) }
            self.sessionId = sessionId
        }

        nonisolated static func current() -> ActivityAttribution {
            ActivityAttribution(
                agentId: ChatExecutionContext.currentAgentId,
                sessionId: ChatExecutionContext.currentSessionId.flatMap(UUID.init(uuidString:))
            )
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
        parentTurnId: UUID? = nil,
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
        path: String = "/chat/completions",
        egress: EgressInfo? = nil,
        privacy: WireTransportProbe.PrivacyOutcome? = nil,
        agentId: UUID? = nil,
        agentName: String? = nil,
        sessionId: UUID? = nil
    ) {
        var resolvedEgress = egress ?? Self.inferenceEgress(connection: connection, requestBody: requestBody)
        if let privacy, resolvedEgress != nil {
            resolvedEgress?.privacyFilterApplied = privacy.applied
            resolvedEgress?.redactedSpanCount = privacy.applied ? privacy.redactedCount : nil
        }
        // A delegated helper session (`spawn_agent`) runs inside the parent's
        // tool call; the engine captured the dispatching assistant turn at
        // request time (task-locals are not reliable on the stream's
        // termination path). Record it so a reviewer can walk orchestrator
        // turn → helper steps.
        if let parentTurn = parentTurnId, parentTurn != turnId {
            var details = resolvedEgress?.details ?? [:]
            details["parent_turn_id"] = parentTurn.uuidString
            if resolvedEgress == nil { resolvedEgress = EgressInfo(dataClasses: []) }
            resolvedEgress?.details = details
        }
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
            connection: connection,
            category: path.contains("compaction") ? .compaction : .inference,
            egress: resolvedEgress,
            agentId: agentId,
            agentName: agentName,
            sessionId: sessionId
        )
    }

    /// Build egress facts for a remote inference from its connection info:
    /// destination host/label from the endpoint + provider, and the data
    /// classes carried by a chat request body.
    nonisolated static func inferenceEgress(
        connection: RequestConnectionInfo?,
        requestBody: String?
    ) -> EgressInfo? {
        guard let connection else { return nil }
        let isRemote: Bool = {
            switch connection.mode {
            case .remoteInference, .remoteAgentRun: return true
            case .local: return false
            case nil: return connection.transport == .direct || connection.transport == .secureChannel
            }
        }()
        guard isRemote else { return nil }
        var classes = ["prompt"]
        if let body = requestBody {
            if body.contains("\"tools\"") { classes.append("tools") }
            if body.contains("\"image_url\"") || body.contains("\"input_audio\"") || body.contains("\"file\"") {
                classes.append("attachments")
            }
        }
        let host = EgressInfo.host(from: connection.remoteEndpoint)
        return EgressInfo(
            destinationLabel: Self.providerLabel(providerId: connection.providerId, host: host),
            destinationHost: host,
            dataClasses: classes
        )
    }

    /// Human-readable destination for a provider id. Looked up through the
    /// main-actor provider manager when available; falls back to the host.
    nonisolated static func providerLabel(providerId: UUID?, host: String?) -> String? {
        if let providerId, let name = RemoteProviderManager.providerDisplayName(for: providerId) {
            return name
        }
        guard let host else { return nil }
        return Self.knownHostLabels.first { host.hasSuffix($0.key) }?.value ?? host
    }

    /// Well-known API hosts so the egress card reads "OpenAI", not "api.openai.com".
    nonisolated static let knownHostLabels: [String: String] = [
        "openai.com": "OpenAI",
        "anthropic.com": "Anthropic",
        "googleapis.com": "Google",
        "x.ai": "xAI",
        "deepseek.com": "DeepSeek",
        "fireworks.ai": "Fireworks",
        "mistral.ai": "Mistral",
        "minimax.io": "MiniMax",
        "venice.ai": "Venice",
        "openrouter.ai": "OpenRouter",
        "atlascloud.ai": "AtlasCloud",
        "azure.com": "Azure OpenAI",
        "osaurus.ai": "Osaurus Router",
        "tavily.com": "Tavily",
        "exa.ai": "Exa",
        "brave.com": "Brave Search",
        "search.brave.com": "Brave Search",
        "serper.dev": "Serper",
        "parallel.ai": "Parallel",
        "kagi.com": "Kagi",
        "you.com": "You.com",
        "bing.com": "Bing",
        "duckduckgo.com": "DuckDuckGo",
        "slack.com": "Slack",
        "discord.com": "Discord",
        "huggingface.co": "Hugging Face",
    ]

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
        connection: RequestConnectionInfo? = nil,
        agentId: UUID? = nil,
        agentName: String? = nil,
        sessionId: UUID? = nil,
        details: [String: String]? = nil
    ) {
        let source = Self.inboundSource(method: method, transport: connection?.transport)
        // Inbound rows from another peer are egress too: the response goes
        // back over the Secure Channel to the caller.
        var egress: EgressInfo?
        if connection?.transport == .secureChannel {
            egress = EgressInfo(
                destinationLabel: L("Paired peer"),
                destinationHost: EgressInfo.host(from: connection?.remoteEndpoint) ?? connection?.audience,
                dataClasses: ["response"]
            )
        }
        // Handler-supplied facts (media size, audio seconds, text counts…).
        // A details-only `EgressInfo` keeps the row's locality local.
        if let details, !details.isEmpty {
            var merged = egress ?? EgressInfo(dataClasses: [])
            merged.details.merge(details) { current, _ in current }
            egress = merged
        }

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
            connection: connection,
            egress: egress,
            agentId: agentId,
            agentName: agentName,
            sessionId: sessionId,
            clientIP: clientIP
        )
    }
}
