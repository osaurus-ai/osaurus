//
//  WorkspaceAgentConnectService.swift
//  osaurus
//
//  Teammate (client) side of the Workspaces shared-agent handshake. Fetches a
//  router-minted membership attestation, redeems it against the sharer's
//  Osaurus over the relay (`/pair-invite` workspace mode: attestation → nonce
//  challenge → EIP-191 master-key signature → HPKE-sealed agent-scoped
//  key), and persists the result as an ordinary paired `RemoteAgent` +
//  `RemoteProvider` so every existing remote-chat surface just works.
//
//  While the app runs, each connected agent's key is silently re-minted at
//  ~80% of the attestation TTL; a refresh that fails with `NOT_A_MEMBER` /
//  `WORKSPACE_NOT_FOUND` tears the pairing down (the spec's revocation model:
//  key validity is bound to attestation freshness).
//
//  Shared agents are also connected automatically: whenever a workspace
//  roster is loaded (tab open, detail poll, launch/activation sweep), every
//  agent a teammate shared that isn't paired yet gets the handshake in the
//  background, so "share once and it appears for everyone, ready to chat"
//  holds without each member clicking Connect. Failures are recorded per
//  agent (not surfaced as banners) and retried on a cooldown; the manual
//  Connect button stays as the fallback and shows the last reason.
//

import AppKit
import Foundation
import LocalAuthentication

@MainActor
final class WorkspaceAgentConnectService: ObservableObject {
    static let shared = WorkspaceAgentConnectService()

    /// Lowercased addresses with a connect/refresh currently in flight.
    @Published private(set) var connectingAddresses: Set<String> = []
    /// User-facing message from the most recent failed connect. Kept for
    /// callers that want a banner; every failure is also recorded per agent
    /// in `connectFailures`, which is what the rows and composer render.
    @Published var lastError: String?
    /// Last connect failure per lowercased agent address — automatic or
    /// user-initiated alike — so every surface (sidebar row, composer lock,
    /// Workspaces row) explains why the agent isn't ready with the same text.
    @Published private(set) var connectFailures: [String: String] = [:]
    /// Lowercased addresses that have had at least one connect attempt this
    /// launch (success or failure). Drives `Connect` vs `Retry` labels.
    @Published private(set) var attemptedAddresses: Set<String> = []

    /// Live refresh loops, keyed by lowercased agent address.
    private var authorizedScopes: Set<String>?
    private var pairingGeneration: [String: UUID] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    /// When each agent was last auto-attempted (lowercased address), for the
    /// retry cooldown.
    private var lastAutoAttempt: [String: Date] = [:]
    /// Minimum spacing between automatic attempts for one agent. The detail
    /// view polls presence every 30 s; retrying a host that just failed on
    /// every poll would only spam an offline Mac.
    nonisolated static let autoConnectRetryInterval: TimeInterval = 2
    /// Minimum spacing between full sweeps (launch, app activation, tab open).
    nonisolated static let sweepInterval: TimeInterval = 300
    private var lastSweep: Date?
    private var sweepInFlight = false
    private var activationObserver: NSObjectProtocol?

    private struct ConnectFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct HostError: Decodable {
        let error: String?
    }

    /// Injectable for tests.
    var client: OsaurusRouterAPIClient = .shared

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sweepWorkspaces()
            }
        }
    }

    private func scope(_ address: String, _ workspaceId: String?) -> String {
        guard let workspaceId else { return address.lowercased() }
        return "\(workspaceId.count):\(workspaceId):\(address.lowercased())"
    }

    func isConnecting(_ agentAddress: String, workspaceId: String? = nil) -> Bool {
        connectingAddresses.contains(scope(agentAddress, workspaceId))
    }

    /// Why the last connect (automatic or manual) for this agent failed.
    func connectFailure(for agentAddress: String, workspaceId: String? = nil) -> String? {
        connectFailures[scope(agentAddress, workspaceId)]
    }

    /// Whether any connect has been attempted for this agent this launch.
    func hasAttempted(_ agentAddress: String, workspaceId: String? = nil) -> Bool {
        attemptedAddresses.contains(scope(agentAddress, workspaceId))
    }

    /// Record why a connect for this agent failed and mark it attempted.
    /// `connect` uses this; tests use it to seed the map without a network.
    func recordFailure(_ message: String, for agentAddress: String, workspaceId: String? = nil) {
        let lower = scope(agentAddress, workspaceId)
        attemptedAddresses.insert(lower)
        connectFailures[lower] = message
    }

    /// Forget a recorded failure — the reason is stale once the router says
    /// the host is offline (offline is the truer state), or the agent was
    /// unshared / the user left the workspace (nothing left to connect to).
    func clearFailure(for agentAddress: String, workspaceId: String? = nil) {
        let lower = scope(agentAddress, workspaceId)
        guard connectFailures[lower] != nil else { return }
        connectFailures[lower] = nil
    }

    /// Drop failures for every address not in `activeAddresses` (lowercased):
    /// the roster no longer lists them.
    func pruneFailures(keeping activeAddresses: Set<String>) {
        let stale = connectFailures.keys.filter { key in
            !activeAddresses.contains(where: { key == $0 || key.hasSuffix(":" + $0) }) }
        guard !stale.isEmpty else { return }
        for key in stale { connectFailures[key] = nil }
    }

    func reconcileMembership(_ snapshot: WorkspaceSyncSnapshot) {
        let active = Set(
            snapshot.workspaces.flatMap { entry in
                entry.agents.map { scope($0.agentAddress, entry.workspace.id) }
            }
        )
        authorizedScopes = active
        for key in pairingGeneration.keys where !active.contains(key) { pairingGeneration[key] = UUID() }
        for key in refreshTasks.keys where !active.contains(key) {
            refreshTasks.removeValue(forKey: key)?.cancel()
        }
    }

    // MARK: - Auto-connect

    /// Shared agents that should be connected automatically right now: shared
    /// by someone else, not paired yet, not mid-handshake, not known to be
    /// offline (a `nil` presence is "unknown" and still worth one try), and
    /// past the retry cooldown since their last automatic attempt.
    nonisolated static func autoConnectCandidates(
        agents: [OsaurusRouterWorkspaceAgent],
        myWalletAddress: String?,
        pairedAddresses: Set<String>,
        connectingAddresses: Set<String>,
        lastAttempts: [String: Date],
        now: Date = Date()
    ) -> [OsaurusRouterWorkspaceAgent] {
        let me = myWalletAddress?.lowercased()
        return agents.filter { agent in
            let address = agent.agentAddress.lowercased()
            if let owner = agent.owner?.walletAddress?.lowercased(), let me, owner == me {
                return false
            }
            if pairedAddresses.contains(address) || connectingAddresses.contains(address) {
                return false
            }
            if agent.online == false { return false }
            if let last = lastAttempts[address],
                now.timeIntervalSince(last) < autoConnectRetryInterval
            {
                return false
            }
            return true
        }
    }

    /// Connects up to four eligible agents concurrently on a loaded roster in
    /// the background. Silent by design: failures land in
    /// `connectFailures` for the row to show, never in `lastError`.
    func autoConnect(workspaceId: String, agents: [OsaurusRouterWorkspaceAgent]) async {
        let paired = Set(
            agents.map { $0.agentAddress.lowercased() }
                .filter { RemoteAgentManager.shared.remoteAgent(forAddress: $0, workspaceId: workspaceId) != nil
                        && refreshTasks[scope($0, workspaceId)] != nil
                        && WorkspaceRosterStore.shared.forcedOffline[$0] == nil
                        && connectFailure(for: $0, workspaceId: workspaceId) == nil
                }
        )
        let candidates = Self.autoConnectCandidates(
            agents: agents,
            myWalletAddress: OsaurusRouterWalletCache.lastSignedAddress,
            pairedAddresses: paired,
            connectingAddresses: Set(
                agents.map(\.agentAddress).filter { isConnecting($0, workspaceId: workspaceId) }.map { $0.lowercased() }
            ),
            lastAttempts: Dictionary(
                uniqueKeysWithValues: agents.map {
                    ($0.agentAddress.lowercased(), lastAutoAttempt[scope($0.agentAddress, workspaceId)] ?? .distantPast)
                }
            )
        )
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for agent in candidates {
                if inFlight == 4 {
                    await group.next()
                    inFlight -= 1
                }
                guard !Task.isCancelled else { break }
                group.addTask { await self.autoConnectOne(agent, workspaceId: workspaceId) }
                inFlight += 1
            }
        }
    }

    private func autoConnectOne(_ agent: OsaurusRouterWorkspaceAgent, workspaceId: String) async {
        guard !Task.isCancelled else { return }
        let address = agent.agentAddress.lowercased()
        // A local failed probe must be retried even while the router
        // snapshot remains online. An explicitly offline relay waits for push.
        if WorkspaceRosterStore.shared.agent(forAddress: address, workspaceId: workspaceId)?.online == false { return }
        lastAutoAttempt[scope(address, workspaceId)] = Date()
        _ = await connect(
            workspaceId: workspaceId,
            agentAddress: agent.agentAddress,
            displayName: agent.displayName,
            silent: true
        )
    }

    /// Lists every workspace the user belongs to and auto-connects each
    /// roster. Throttled; safe to call from launch, activation, and tab open.
    func sweepWorkspaces(force: Bool = false) async {
        guard OsaurusRouter.isEnabled, MasterKey.existsCached() else { return }
        guard !sweepInFlight else { return }
        if !force, let last = lastSweep, Date().timeIntervalSince(last) < Self.sweepInterval {
            return
        }
        sweepInFlight = true
        defer { sweepInFlight = false }
        lastSweep = Date()

        guard let workspaces = try? await client.listWorkspaces() else { return }
        for workspace in workspaces {
            guard let agents = try? await client.workspaceAgents(id: workspace.id) else { continue }
            await autoConnect(workspaceId: workspace.id, agents: agents)
        }
    }

    /// The existing pairing for a shared agent, if this teammate already
    /// connected (from any pairing path — the address is the identity).
    func pairedAgent(forAddress agentAddress: String, workspaceId: String? = nil) -> RemoteAgent? {
        RemoteAgentManager.shared.remoteAgent(forAddress: agentAddress, workspaceId: workspaceId)
    }

    // MARK: - Connect

    /// Full connect. Returns the persisted `RemoteAgent`, or nil with the
    /// failure recorded in `connectFailures` (and, for a user-initiated
    /// connect, also in `lastError`).
    ///
    /// The pairing is named with the router display name the sharer chose
    /// for the workspace (`displayName`), falling back to the host's live
    /// agent name only when the roster has none — teammates should see the
    /// name the sharer typed, consistently, on every surface.
    @discardableResult
    func connect(
        workspaceId: String,
        agentAddress: String,
        displayName: String?,
        silent: Bool = false
    ) async -> RemoteAgent? {
        let addressLower = scope(agentAddress, workspaceId)
        guard !connectingAddresses.contains(addressLower) else { return nil }
        guard authorizedScopes?.contains(addressLower) != false else { return nil }
        let generation = UUID()
        pairingGeneration[addressLower] = generation
        connectingAddresses.insert(addressLower)
        attemptedAddresses.insert(addressLower)
        defer { connectingAddresses.remove(addressLower) }

        do {
            let outcome = try await performHandshake(
                workspaceId: workspaceId, agentAddress: agentAddress
            )
            try Task.checkCancellation()
            guard pairingGeneration[addressLower] == generation,
                authorizedScopes?.contains(addressLower) != false
            else { throw CancellationError() }
            WorkspaceRosterStore.shared.noteHostReachable(agentAddress: agentAddress)
            let trimmedDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = RemoteAgentManager.shared.upsertPairedAgent(
                agentAddress: outcome.agentAddress,
                name: (trimmedDisplay?.isEmpty == false ? trimmedDisplay : nil)
                    ?? outcome.agentName ?? agentAddress,
                description: outcome.agentDescription ?? "",
                relayBaseURL: "https://\(agentAddress.lowercased()).agent.osaurus.ai",
                apiKey: outcome.apiKey,
                note: nil,
                model: outcome.agentModel,
                workspaceId: workspaceId
            )
            if !silent { lastError = nil }
            connectFailures[addressLower] = nil
            scheduleRefresh(
                workspaceId: workspaceId,
                agentAddress: agentAddress,
                attestationExpiresAt: outcome.attestationExpiresAt
            )
            return remote
        } catch {
            let message = Self.friendlyMessage(for: error)
            recordFailure(message, for: agentAddress, workspaceId: workspaceId)
            if !silent { lastError = message }
            return nil
        }
    }

    /// Stop refreshing (does not remove the pairing; the key simply expires
    /// with its attestation). Called when the pairing is removed by the user.
    func stopRefreshing(agentAddress: String, workspaceId: String? = nil) {
        let addressLower = scope(agentAddress, workspaceId)
        pairingGeneration[addressLower] = UUID()
        refreshTasks[addressLower]?.cancel()
        refreshTasks[addressLower] = nil
    }

    // MARK: - Silent refresh loop

    private func scheduleRefresh(
        workspaceId: String,
        agentAddress: String,
        attestationExpiresAt: Date?
    ) {
        let addressLower = scope(agentAddress, workspaceId)
        refreshTasks[addressLower]?.cancel()

        // No parseable expiry → no loop; the user reconnects manually when
        // the key dies. Never guess a TTL the router didn't state.
        guard let expiresAt = attestationExpiresAt else { return }
        let ttl = expiresAt.timeIntervalSinceNow
        guard ttl > 0 else { return }
        let delay = ttl * WorkspaceAgentAccess.refreshFraction

        refreshTasks[addressLower] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh(workspaceId: workspaceId, agentAddress: agentAddress)
        }
    }

    private func refresh(workspaceId: String, agentAddress: String) async {
        let addressLower = scope(agentAddress, workspaceId)
        // Pairing gone (user removed it) → nothing to keep alive.
        guard authorizedScopes?.contains(addressLower) != false,
            RemoteAgentManager.shared.remoteAgent(forAddress: agentAddress, workspaceId: workspaceId) != nil else {
            refreshTasks[addressLower] = nil
            return
        }
        do {
            let outcome = try await performHandshake(
                workspaceId: workspaceId, agentAddress: agentAddress
            )
            try Task.checkCancellation()
            if !RemoteAgentManager.shared.updateAPIKey(
                outcome.apiKey, forAddress: outcome.agentAddress,
                workspaceId: workspaceId
            ) {
                refreshTasks[addressLower] = nil
                return
            }
            connectFailures[addressLower] = nil
            WorkspaceRosterStore.shared.noteHostReachable(agentAddress: agentAddress)
            // The owner may have switched the agent's model since we paired.
            if let model = outcome.agentModel {
                RemoteAgentManager.shared.updateModel(model, forAddress: outcome.agentAddress, workspaceId: workspaceId)
            }
            scheduleRefresh(
                workspaceId: workspaceId,
                agentAddress: agentAddress,
                attestationExpiresAt: outcome.attestationExpiresAt
            )
        } catch {
            refreshTasks[addressLower] = nil
            // Membership revoked → drop the whole session per the spec (the
            // host already refuses the key; keeping a dead pairing around
            // just yields opaque chat failures).
            if Self.isMembershipRevoked(error) {
                if let remote = RemoteAgentManager.shared.remoteAgent(forAddress: agentAddress,
                    workspaceId: workspaceId
                ) {
                    _ = RemoteAgentManager.shared.remove(id: remote.id)
                }
            } else if !Task.isCancelled {
                recordFailure(Self.friendlyMessage(for: error), for: agentAddress, workspaceId: workspaceId)
                refreshTasks[addressLower] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.autoConnectRetryInterval))
                    guard !Task.isCancelled else { return }
                    await self?.refresh(workspaceId: workspaceId, agentAddress: agentAddress)
                }
            }
        }
    }

    private static func isMembershipRevoked(_ error: Error) -> Bool {
        guard case OsaurusRouterAPIError.server(let code, _, _) = error else { return false }
        switch OsaurusRouterWorkspaceErrorCode(code: code) {
        case .notAMember, .workspaceNotFound: return true
        default: return false
        }
    }

    // MARK: - Handshake

    struct HandshakeOutcome {
        let agentAddress: String
        let agentName: String?
        let agentDescription: String?
        let agentModel: String?
        let apiKey: String
        let attestationExpiresAt: Date?
    }

    /// Test seam: stands in for the router + host handshake so connect /
    /// repair flows can be exercised without a live relay. `(workspaceId,
    /// agentAddress)` in; a minted grant (or a thrown failure) out. nil in
    /// production.
    var testHandshakeOverride: ((String, String) async throws -> HandshakeOutcome)?

    /// Wire shape of the host's grant (step two of `/pair-invite` workspace
    /// mode). Internal so the decode contract is testable; every field but
    /// the address is optional for cross-version tolerance.
    struct GrantResponse: Decodable, Equatable {
        let agentAddress: String
        let agentName: String?
        let agentDescription: String?
        let agentModel: String?
        let apiKey: String?
        let sealedApiKey: PairingKeyEnvelope.Sealed?
    }

    /// Attestation mint → step-one challenge → master-key signature →
    /// step-two redeem → unsealed agent-scoped key.
    private func performHandshake(
        workspaceId: String,
        agentAddress: String
    ) async throws -> HandshakeOutcome {
        if let override = testHandshakeOverride {
            return try await override(workspaceId, agentAddress)
        }
        // 1. Router mints the membership attestation (wallet-signed request).
        let minted = try await client.workspaceAttestation(id: workspaceId)
        let attestationExpiresAt = WorkspaceMembershipAttestation
            .unverifiedPayload(token: minted.attestation)
            .map { Date(timeIntervalSince1970: TimeInterval($0.exp)) }

        let addressLower = agentAddress.lowercased()
        guard let endpoint = URL(string: "https://\(addressLower).agent.osaurus.ai/pair-invite")
        else {
            throw ConnectFailure(message: L("The shared agent's address is invalid."))
        }

        // 2. Step one: attestation only → nonce challenge.
        let stepOne = WorkspacePairRedeemEnvelope(
            workspaceRedeem: .init(
                v: 1,
                agentAddress: agentAddress,
                attestation: minted.attestation,
                nonce: nil,
                walletSignature: nil,
                encPub: nil
            )
        )
        let challengeData = try await post(endpoint, body: stepOne)
        guard
            let challenge = try? JSONDecoder().decode(
                WorkspacePairChallengeResponse.self, from: challengeData
            )
        else {
            throw ConnectFailure(
                message: L(
                    "The agent's host didn't recognize the workspace handshake. It may be running an older Osaurus."
                )
            )
        }
        let nonce = challenge.workspaceChallenge.nonce

        // 3. Master-key EIP-191 signature over the challenge (Touch ID may
        // prompt — same contract as every other wallet signature).
        let message = WorkspaceAgentAccess.redeemMessage(agentAddress: agentAddress, nonce: nonce)
        let signatureHex = try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 300
            var privateKey = try MasterKey.getPrivateKey(context: context)
            defer { privateKey.zeroOut() }
            return try signEIP191Message(message, privateKey: privateKey).hexEncodedString
        }.value

        // 4. Step two: nonce + signature + ephemeral HPKE key → sealed key.
        let (encPrivateKey, encPub) = PairingKeyEnvelope.generateRecipientKey()
        let stepTwo = WorkspacePairRedeemEnvelope(
            workspaceRedeem: .init(
                v: 1,
                agentAddress: agentAddress,
                attestation: minted.attestation,
                nonce: nonce,
                walletSignature: "0x\(signatureHex)",
                encPub: encPub
            )
        )
        let grantData = try await post(endpoint, body: stepTwo)

        guard let grant = try? JSONDecoder().decode(GrantResponse.self, from: grantData) else {
            throw ConnectFailure(message: L("The agent's host returned an unexpected response."))
        }

        // Prefer the sealed credential; plaintext only from hosts that
        // ignored `encPub` (mirrors the invite flow's cross-version stance).
        let apiKey: String
        if let sealed = grant.sealedApiKey {
            guard
                let opened = try? PairingKeyEnvelope.open(
                    sealed,
                    privateKey: encPrivateKey,
                    info: PairingKeyEnvelope.info(
                        agentAddress: grant.agentAddress, nonce: nonce
                    )
                )
            else {
                throw ConnectFailure(
                    message: L("Couldn't decrypt the access key from the agent's host.")
                )
            }
            apiKey = opened
        } else {
            apiKey = grant.apiKey ?? ""
        }
        guard !apiKey.isEmpty else {
            throw ConnectFailure(message: L("The agent's host didn't return an access key."))
        }

        return HandshakeOutcome(
            agentAddress: grant.agentAddress,
            agentName: grant.agentName,
            agentDescription: grant.agentDescription,
            agentModel: grant.agentModel,
            apiKey: apiKey,
            attestationExpiresAt: attestationExpiresAt
        )
    }

    // MARK: - Transport

    private func post<Body: Encodable>(_ url: URL, body: Body) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder.osaurusCanonical().encode(body)

        let session = RemoteAgentManager.makePairInviteSession()
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ConnectFailure(
                message: L(
                    "Couldn't reach the agent's host. It may be offline — ask the owner to open Osaurus."
                )
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectFailure(message: L("The agent's host returned an unexpected response."))
        }
        // The relay's verdict is live presence: flip the roster now so the
        // row/composer show offline (or come back online) without waiting
        // on the router poll.
        OsaurusRelayPresenceSignal.observe(url: http.url, statusCode: http.statusCode, body: data)
        guard http.statusCode == 200 else {
            if let offline = OsaurusRelayPresenceSignal.unreachableMessage(statusCode: http.statusCode, body: data) {
                throw ConnectFailure(message: offline)
            }
            let hostMessage = (try? JSONDecoder().decode(HostError.self, from: data))?.error
            throw ConnectFailure(
                message: hostMessage ?? "HTTP \(http.statusCode)"
            )
        }
        return data
    }

    // MARK: - Error copy

    private static func friendlyMessage(for error: Error) -> String {
        if let failure = error as? ConnectFailure { return failure.message }
        if case OsaurusRouterAPIError.server(let code, let message, let status) = error {
            switch OsaurusRouterWorkspaceErrorCode(code: code) {
            case .notAMember:
                return L("You're no longer a member of this workspace.")
            case .workspaceNotFound:
                return L("This workspace no longer exists.")
            case .subscriptionInactive:
                return L("This workspace's plan isn't active, so shared agents are unavailable.")
            default: break
            }
            if status == 409 {
                return L("Workspaces attestations aren't enabled on the router yet. Try again later.")
            }
            return message.isEmpty ? L("The Workspaces service refused the request.") : message
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return L("Couldn't connect to the shared agent. Check your connection and try again.")
    }
}
