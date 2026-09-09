//
//  WorkspaceAgentLiveness.swift
//  osaurus
//
//  On-the-wire liveness for a teammate's shared agent, asked right before a
//  headless run (spawn, schedule, watcher, channel) is admitted.
//
//  Why not the cached roster presence: `WorkspaceRosterStore.presence` is a
//  hint that decays to `.unknown` 35 s after the last verification and lags
//  the relay's Redis claim TTL, and a spawn that trusts it can still land on
//  a host that went to sleep a minute ago. The relay is the authority — a
//  `GET /agents/{address}` through `*.agent.osaurus.ai` either reaches the
//  host (any host status) or answers `502 agent_offline` — so the probe asks
//  it directly, with a bounded budget, and feeds the verdict back into the
//  roster so the sidebar benefits without ever being the source of truth.
//
//  Why the verdict never touches the prompt: spawn guidance and the spawn
//  tool enums are composed from durable configuration only. A non-live
//  verdict becomes the spawn tool's *result* (the model re-plans in the
//  tool-result turn), so the system prompt stays byte-identical and the
//  prefix / KV cache survives the presence flip. See the plan's "Liveness
//  without prompt churn" contract and `PromptSurfaceMatrixTests`.
//

import Foundation

/// One raw answer from the transport layer, before classification.
enum WorkspaceAgentLivenessResponse: Sendable, Equatable {
    /// The relay answered for itself (outer HTTP status >= 400 on the
    /// `/secure/call` or `/secure/session` hop): the host was not reached.
    case relay(status: Int, body: Data)
    /// The host answered (inner status from the Secure Channel envelope).
    case host(status: Int, body: Data)
    /// No HTTP response at all (DNS, TLS, timeout on THIS Mac's side).
    case transport(String)
    /// The Secure Channel handshake failed for a non-HTTP reason (peer
    /// predates it, identity mismatch, key agreement).
    case secureChannel(String)
}

/// Injectable transport so the classifier and the run-client policy can be
/// exercised without a relay.
protocol WorkspaceAgentLivenessTransport: Sendable {
    func get(path: String, provider: RemoteProvider, timeout: TimeInterval) async -> WorkspaceAgentLivenessResponse
}

enum WorkspaceAgentLiveness {
    /// Total wall-clock budget for one probe (handshake + call).
    static let defaultBudget: TimeInterval = 8

    enum Verdict: Sendable, Equatable {
        /// The host answered `GET /agents/{address}` with 2xx.
        case live(RemoteProviderService.RemoteAgentMetadata?)
        /// The relay has no tunnel for the host (`agent_offline`,
        /// `tunnel_send_failed`, `gateway_timeout`).
        case offline
        /// The relay itself could not be reached from this Mac, or the probe
        /// ran out of budget. Says nothing about the teammate's host.
        case unreachable(String)
        /// The host refused our key (401/403). For a workspace pairing this
        /// is a lapsed attestation: one re-handshake repairs it.
        case rejected
        /// The host answered 404: the agent no longer exists there.
        case notFound
        /// Any other host/relay answer (5xx from the host, malformed body).
        case failed(String)

        var isLive: Bool {
            if case .live = self { return true }
            return false
        }
    }

    // MARK: - Classification (pure)

    /// Map a transport answer to a verdict. Pure, so the whole matrix is
    /// unit-testable without a network.
    static func classify(_ response: WorkspaceAgentLivenessResponse) -> Verdict {
        switch response {
        case .relay(let status, let body):
            if OsaurusRelayPresenceSignal.indicatesHostUnreachable(statusCode: status, body: body) {
                return .offline
            }
            if status == 401 || status == 403 { return .rejected }
            if status == 404 { return .notFound }
            let token = OsaurusRelayPresenceSignal.relayError(in: body) ?? "HTTP \(status)"
            return .failed("relay: \(token)")
        case .host(let status, let body):
            switch status {
            case 200..<300:
                return .live(RemoteProviderService.parseAgentMetadata(from: body))
            case 401, 403:
                return .rejected
            case 404:
                return .notFound
            default:
                let excerpt = String(decoding: body.prefix(160), as: UTF8.self)
                return .failed("HTTP \(status)\(excerpt.isEmpty ? "" : ": \(excerpt)")")
            }
        case .transport(let message):
            return .unreachable(message)
        case .secureChannel(let message):
            // A handshake refused with an HTTP status carries the relay's or
            // host's verdict inside the message (`HTTP 502: {"error":…}`).
            if let (status, body) = parseHandshakeHTTPFailure(message) {
                if OsaurusRelayPresenceSignal.indicatesHostUnreachable(statusCode: status, body: body) {
                    return .offline
                }
                if status == 401 || status == 403 { return .rejected }
            }
            return .failed("secure channel: \(message)")
        }
    }

    /// `SecureChannelClient.session(for:)` throws
    /// `handshakeFailed("HTTP <status>: <body prefix>")` for any non-200 /
    /// non-404 / non-429 answer. Recover the status and body so a relay
    /// `agent_offline` during the handshake still reads as offline.
    static func parseHandshakeHTTPFailure(_ message: String) -> (status: Int, body: Data)? {
        let marker = "HTTP "
        guard let range = message.range(of: marker) else { return nil }
        let rest = message[range.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        guard let status = Int(rest[..<colon].trimmingCharacters(in: .whitespaces)) else { return nil }
        let body = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (status, Data(body.utf8))
    }

    /// Short user/model-facing sentence for a non-live verdict.
    static func message(for verdict: Verdict, agentName: String, lastSeen: Date?, now: Date = Date()) -> String {
        switch verdict {
        case .live:
            return L("\(agentName) is online.")
        case .offline:
            if let lastSeen {
                let ago = relativeAge(from: lastSeen, to: now)
                return L("Workspace agent \(agentName) is offline (last seen \(ago)). Its owner's Mac is not connected to the relay.")
            }
            return L("Workspace agent \(agentName) is offline. Its owner's Mac is not connected to the relay.")
        case .unreachable(let why):
            return L("Couldn't reach the relay to check \(agentName) (\(why)). Check this Mac's connection.")
        case .rejected:
            return L("\(agentName)'s host refused this Mac's workspace key. Reconnect the agent from the Workspaces tab.")
        case .notFound:
            return L("\(agentName) is no longer available on its owner's Mac.")
        case .failed(let why):
            return L("\(agentName) did not answer the liveness check (\(why)).")
        }
    }

    static func relativeAge(from: Date, to: Date) -> String {
        let seconds = max(0, Int(to.timeIntervalSince(from)))
        if seconds < 60 { return L("moments ago") }
        let minutes = seconds / 60
        if minutes < 60 { return minutes == 1 ? L("1 min ago") : L("\(minutes) min ago") }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? L("1 hour ago") : L("\(hours) hours ago") }
        let days = hours / 24
        return days == 1 ? L("1 day ago") : L("\(days) days ago")
    }

    // MARK: - Probe

    /// Injectable transport (tests). nil = the Secure Channel transport.
    nonisolated(unsafe) static var transportOverride: (any WorkspaceAgentLivenessTransport)?

    /// Ask the relay whether `provider`'s agent is reachable right now.
    /// Bounded by `budget`; a budget miss is `.unreachable("timed out")`.
    /// Feeds the verdict into `WorkspaceRosterStore` presence as a side
    /// effect (online on any host answer, offline on a relay verdict).
    static func probe(
        provider: RemoteProvider,
        budget: TimeInterval = defaultBudget
    ) async -> Verdict {
        guard let address = provider.remoteAgentAddress, !address.isEmpty else {
            return .failed("provider has no agent address")
        }
        let transport = transportOverride ?? SecureChannelLivenessTransport()
        let path = "/agents/\(address)"
        let response = await withBudget(budget) {
            await transport.get(path: path, provider: provider, timeout: budget)
        } ?? .transport("timed out after \(Int(budget)) s")
        let verdict = classify(response)
        await feedPresence(verdict, address: address)
        return verdict
    }

    @MainActor
    private static func feedPresence(_ verdict: Verdict, address: String) {
        switch verdict {
        case .live, .rejected, .notFound:
            // The host answered — the tunnel is up.
            WorkspaceRosterStore.shared.noteHostReachable(agentAddress: address)
        case .offline:
            WorkspaceRosterStore.shared.noteHostUnreachable(agentAddress: address)
        case .unreachable, .failed:
            // Says more about this Mac (or the relay) than about the host.
            break
        }
    }

    private static func withBudget<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Coalescing

/// Shares one in-flight probe per agent so a `spawn_batch` fanning out to the
/// same teammate's agent N times asks the relay once.
actor WorkspaceAgentLivenessCoalescer {
    static let shared = WorkspaceAgentLivenessCoalescer()

    private var inFlight: [String: Task<WorkspaceAgentLiveness.Verdict, Never>] = [:]

    func probe(
        provider: RemoteProvider,
        budget: TimeInterval = WorkspaceAgentLiveness.defaultBudget
    ) async -> WorkspaceAgentLiveness.Verdict {
        let key = (provider.remoteAgentAddress ?? provider.id.uuidString).lowercased()
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task { await WorkspaceAgentLiveness.probe(provider: provider, budget: budget) }
        inFlight[key] = task
        let verdict = await task.value
        inFlight[key] = nil
        return verdict
    }
}

// MARK: - Default transport

/// `GET` through the Secure Channel (`/secure/session` + `/secure/call`) so
/// the workspace key never crosses the relay in cleartext. Unlike
/// `RemoteProviderService.osaurusGET`, this keeps the relay's own status and
/// body when the outer hop fails, because that is exactly the verdict the
/// probe exists to read.
struct SecureChannelLivenessTransport: WorkspaceAgentLivenessTransport {
    func get(path: String, provider: RemoteProvider, timeout: TimeInterval) async -> WorkspaceAgentLivenessResponse {
        guard let url = provider.url(for: path) else {
            return .transport("could not build URL for \(path)")
        }
        let headers = await provider.resolvedHeadersOffMainActor()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = min(provider.timeout, timeout)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let urlSession = GlobalProxySettings.sharedSession()
        do {
            let (outer, opener) = try await SecureChannelClient.shared.wrappedRequest(
                for: request,
                provider: provider,
                urlSession: urlSession
            )
            let (data, response) = try await urlSession.data(for: outer)
            guard let http = response as? HTTPURLResponse else {
                return .transport("non-HTTP response")
            }
            if SecureChannelClient.isSessionUnknownError(statusCode: http.statusCode, body: data) {
                // Session rotated under us: drop it and retry the call once
                // with a fresh handshake before reporting anything.
                await SecureChannelClient.shared.invalidateSession(for: provider)
                let (retryOuter, retryOpener) = try await SecureChannelClient.shared.wrappedRequest(
                    for: request,
                    provider: provider,
                    urlSession: urlSession
                )
                let (retryData, retryResponse) = try await urlSession.data(for: retryOuter)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    return .transport("non-HTTP response")
                }
                return Self.classifyOuter(status: retryHTTP.statusCode, data: retryData, opener: retryOpener)
            }
            return Self.classifyOuter(status: http.statusCode, data: data, opener: opener)
        } catch let error as SecureChannelClientError {
            switch error {
            case .handshakeFailed(let message):
                return .secureChannel(message)
            default:
                return .secureChannel(error.localizedDescription)
            }
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    private static func classifyOuter(
        status: Int,
        data: Data,
        opener: SecureResponseOpener
    ) -> WorkspaceAgentLivenessResponse {
        guard status < 400 else { return .relay(status: status, body: data) }
        guard let inner = try? SecureChannelClient.openBufferedResponse(data, opener: opener) else {
            return .secureChannel("could not open the encrypted response")
        }
        let body = inner.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
        return .host(status: inner.status, body: body)
    }
}
