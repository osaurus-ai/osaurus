//
//  WorkspaceAuditLog.swift
//  osaurus
//
//  Host-side, append-only, hash-chained audit trail for the Workspaces
//  (shared-agent) feature. One JSONL file per workspace under
//  `~/.osaurus/workspaces/audit/<workspaceId>.jsonl`, plus a `.head` sidecar
//  holding the last record's `seq:hash` so truncation of the tail is
//  detectable.
//
//  Each record's `hash` is `SHA-256(prevHash || "\n" || canonicalJSON(record
//  without hash))`. `verify()` walks the chain and reports the first break.
//  This is tamper-EVIDENT, not tamper-PROOF: an actor with write access to
//  the user's home directory can rewrite the whole chain and the sidecar.
//  It defends against casual edits, partial deletion, and reordering, and
//  gives an exportable, independently checkable record of what this host
//  observed. Router-side actions performed by other members on the web are
//  not visible here unless this host received their effect.
//
//  Metadata only: caller identity, agent, model, tool NAMES, outcomes,
//  reasons. Never message content, tool arguments/results, keys, or
//  attestation tokens.
//

import CryptoKit
import Foundation

/// Every kind of event the trail records. Raw values are the on-disk
/// `event` field; keep them stable.
enum WorkspaceAuditEventKind: String, Codable, CaseIterable, Sendable {
    // Teammate access (host side)
    case attestationGranted = "attestation.granted"
    case attestationDenied = "attestation.denied"
    case keyMinted = "key.minted"
    case keyRevoked = "key.revoked"
    // Teammate runs (host side)
    case runStarted = "run.started"
    case runFinished = "run.finished"
    case runStoppedByOwner = "run.stopped_by_owner"
    case runRejected = "run.rejected"
    case scopeDenied = "scope.denied"
    case taskCancelled = "task.cancelled"
    // Runs THIS instance started on a teammate's shared agent (client side:
    // spawn / schedule / watcher / channel dispatch over the relay).
    case outboundRunStarted = "run.outbound_started"
    case outboundRunFinished = "run.outbound_finished"
    case outboundRunRefused = "run.outbound_refused"
    // Owner actions taken from this app
    case workspaceCreated = "workspace.created"
    case workspaceRenamed = "workspace.renamed"
    case workspaceDeleted = "workspace.deleted"
    /// Owner put a suspended workspace back on their subscription.
    case workspaceReactivated = "workspace.reactivated"
    case workspaceLeft = "workspace.left"
    case inviteCreated = "invite.created"
    case inviteRevoked = "invite.revoked"
    case memberRemoved = "member.removed"
    case memberRoleChanged = "member.role_changed"
    case agentShared = "agent.shared"
    case agentUnshared = "agent.unshared"
    case joinRedeemed = "join.redeemed"
    case billingPreferenceChanged = "billing.preference_changed"
    /// Owner's one-time pool top-up was confirmed by Stripe.
    case poolTopUp = "pool.topup"
    /// Owner saved the pool's auto-reload settings.
    case poolAutoReloadChanged = "pool.auto_reload_changed"

    /// Coarse grouping for the viewer's filter.
    enum Category: String, CaseIterable, Sendable {
        case access
        case runs
        case denials
        case administration
    }

    var category: Category {
        switch self {
        case .attestationGranted, .keyMinted, .keyRevoked:
            return .access
        case .runStarted, .runFinished, .runStoppedByOwner, .taskCancelled,
            .outboundRunStarted, .outboundRunFinished:
            return .runs
        case .attestationDenied, .runRejected, .scopeDenied, .outboundRunRefused:
            return .denials
        case .workspaceCreated, .workspaceRenamed, .workspaceDeleted, .workspaceReactivated, .workspaceLeft,
            .inviteCreated, .inviteRevoked, .memberRemoved, .memberRoleChanged,
            .agentShared, .agentUnshared, .joinRedeemed, .billingPreferenceChanged,
            .poolTopUp, .poolAutoReloadChanged:
            return .administration
        }
    }
}

/// Who performed / was the subject of an event.
struct WorkspaceAuditActor: Codable, Sendable, Equatable {
    /// Lowercase wallet address.
    let wallet: String?
    let accountId: String?
    let name: String?
    let role: String?
    /// `true` when the actor is this host's own account (owner actions).
    let isSelf: Bool

    init(wallet: String?, accountId: String? = nil, name: String? = nil, role: String? = nil, isSelf: Bool = false) {
        self.wallet = wallet?.lowercased()
        self.accountId = accountId
        self.name = name
        self.role = role
        self.isSelf = isSelf
    }

    /// The host's own account, from the wallet the router last saw us sign with.
    static func me(role: String? = nil) -> WorkspaceAuditActor {
        WorkspaceAuditActor(
            wallet: OsaurusRouterWalletCache.lastSignedAddress,
            role: role,
            isSelf: true
        )
    }
}

/// One persisted line of the trail.
struct WorkspaceAuditRecord: Codable, Sendable, Equatable, Identifiable {
    /// 1-based, strictly increasing per workspace file.
    let seq: Int
    /// Unix milliseconds. An integer (not a formatted date) so canonical JSON
    /// is byte-stable across encoder versions.
    let tsMs: Int64
    let event: WorkspaceAuditEventKind
    let workspaceId: String
    let actor: WorkspaceAuditActor?
    let agentAddress: String?
    let agentName: String?
    /// Free-form subject (invite id, member account id, task id, path…).
    let target: String?
    /// Small string-only bag of metadata (model, reason, tool names…).
    let details: [String: String]
    let prevHash: String
    let hash: String

    var id: Int { seq }
    var timestamp: Date { Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000) }

    /// The hashed projection (everything except `hash`).
    fileprivate struct Body: Codable {
        let seq: Int
        let tsMs: Int64
        let event: WorkspaceAuditEventKind
        let workspaceId: String
        let actor: WorkspaceAuditActor?
        let agentAddress: String?
        let agentName: String?
        let target: String?
        let details: [String: String]
        let prevHash: String
    }

    fileprivate var body: Body {
        Body(
            seq: seq, tsMs: tsMs, event: event, workspaceId: workspaceId, actor: actor,
            agentAddress: agentAddress, agentName: agentName, target: target, details: details,
            prevHash: prevHash
        )
    }
}

/// Result of walking one workspace's chain.
struct WorkspaceAuditVerification: Sendable, Equatable {
    enum Problem: Sendable, Equatable {
        /// A line failed to decode.
        case malformedLine(lineNumber: Int)
        /// `seq` is not the previous `seq + 1`.
        case sequenceGap(seq: Int, expected: Int)
        /// `prevHash` does not equal the previous record's `hash`.
        case brokenLink(seq: Int)
        /// Recomputed hash differs from the stored one (record edited).
        case hashMismatch(seq: Int)
        /// The `.head` sidecar points past the last record (tail truncated)
        /// or at a different hash.
        case headMismatch(expectedSeq: Int, actualSeq: Int)
    }

    let recordCount: Int
    let problems: [Problem]
    var isIntact: Bool { problems.isEmpty }
}

actor WorkspaceAuditLog {
    static let shared = WorkspaceAuditLog()

    enum RevocationReason: String, Sendable {
        case replacedByRefresh = "replaced_by_refresh"
        case agentUnshared = "agent_unshared"
        case workspaceDeleted = "workspace_deleted"
    }

    /// Hash of "nothing" — the `prevHash` of the first record.
    static let genesisHash = String(repeating: "0", count: 64)

    /// Directory holding `<workspaceId>.jsonl` / `<workspaceId>.head`.
    /// Injectable for tests.
    var directoryURL: @Sendable () -> URL = { OsaurusPaths.workspaceAudit() }
    var now: @Sendable () -> Date = { Date() }

    /// Per-workspace tail cache so appends don't re-read the file.
    private var tails: [String: (seq: Int, hash: String)] = [:]
    /// Observers notified (on the main actor) after each append so a live
    /// viewer can refresh. Keyed so views can unregister.
    private var observers: [UUID: @Sendable (String) -> Void] = [:]

    func setSeams(
        directoryURL: (@Sendable () -> URL)? = nil,
        now: (@Sendable () -> Date)? = nil
    ) {
        if let directoryURL { self.directoryURL = directoryURL }
        if let now { self.now = now }
        tails = [:]
    }

    // MARK: - Observation

    @discardableResult
    func addObserver(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    // MARK: - Append

    /// Appends one record to `workspaceId`'s chain. Failures are logged, never
    /// thrown to the caller — the audit trail must not break the operation it
    /// records — but the method returns the record so callers/tests can check.
    @discardableResult
    func append(
        _ event: WorkspaceAuditEventKind,
        workspaceId: String,
        actor: WorkspaceAuditActor? = nil,
        agentAddress: String? = nil,
        agentName: String? = nil,
        target: String? = nil,
        details: [String: String] = [:]
    ) -> WorkspaceAuditRecord? {
        let sanitizedId = Self.sanitizeWorkspaceId(workspaceId)
        guard !sanitizedId.isEmpty else { return nil }
        let tail = currentTail(for: sanitizedId)
        let seq = tail.seq + 1
        let tsMs = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let body = WorkspaceAuditRecord.Body(
            seq: seq,
            tsMs: tsMs,
            event: event,
            workspaceId: workspaceId,
            actor: actor,
            agentAddress: agentAddress?.lowercased(),
            agentName: agentName,
            target: target,
            details: Self.boundedDetails(details),
            prevHash: tail.hash
        )
        guard let hash = Self.hash(of: body) else { return nil }
        let record = WorkspaceAuditRecord(
            seq: body.seq, tsMs: body.tsMs, event: body.event, workspaceId: body.workspaceId,
            actor: body.actor, agentAddress: body.agentAddress, agentName: body.agentName,
            target: body.target, details: body.details, prevHash: body.prevHash, hash: hash
        )
        do {
            try write(record, workspaceId: sanitizedId)
        } catch {
            NSLog("[Osaurus][Workspaces] audit append failed: %@", "\(error)")
            return nil
        }
        tails[sanitizedId] = (seq, hash)
        let handlers = Array(observers.values)
        if !handlers.isEmpty {
            Task { @MainActor in
                for handler in handlers { handler(workspaceId) }
            }
        }
        return record
    }

    // MARK: - Read / verify / export

    /// All records for a workspace in file order. Malformed lines are skipped
    /// here (use `verify` to detect them).
    func records(workspaceId: String) -> [WorkspaceAuditRecord] {
        let sanitizedId = Self.sanitizeWorkspaceId(workspaceId)
        guard let lines = readLines(workspaceId: sanitizedId) else { return [] }
        let decoder = JSONDecoder()
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
            return try? decoder.decode(WorkspaceAuditRecord.self, from: data)
        }
    }

    /// Walks the chain and the head sidecar.
    func verify(workspaceId: String) -> WorkspaceAuditVerification {
        let sanitizedId = Self.sanitizeWorkspaceId(workspaceId)
        guard let lines = readLines(workspaceId: sanitizedId) else {
            return WorkspaceAuditVerification(recordCount: 0, problems: [])
        }
        let decoder = JSONDecoder()
        var problems: [WorkspaceAuditVerification.Problem] = []
        var previousHash = Self.genesisHash
        var expectedSeq = 1
        var count = 0
        var lastSeq = 0
        for (index, line) in lines.enumerated() where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                let record = try? decoder.decode(WorkspaceAuditRecord.self, from: data)
            else {
                problems.append(.malformedLine(lineNumber: index + 1))
                continue
            }
            count += 1
            if record.seq != expectedSeq {
                problems.append(.sequenceGap(seq: record.seq, expected: expectedSeq))
            }
            if record.prevHash != previousHash {
                problems.append(.brokenLink(seq: record.seq))
            }
            if Self.hash(of: record.body) != record.hash {
                problems.append(.hashMismatch(seq: record.seq))
            }
            previousHash = record.hash
            expectedSeq = record.seq + 1
            lastSeq = record.seq
        }
        if let head = readHead(workspaceId: sanitizedId) {
            if head.seq != lastSeq || head.hash != previousHash {
                problems.append(.headMismatch(expectedSeq: head.seq, actualSeq: lastSeq))
            }
        } else if count > 0 {
            // Records without a head sidecar: someone removed it.
            problems.append(.headMismatch(expectedSeq: 0, actualSeq: lastSeq))
        }
        return WorkspaceAuditVerification(recordCount: count, problems: problems)
    }

    /// The raw JSONL file for hand-off (support ticket, compliance archive).
    func exportURL(workspaceId: String) -> URL? {
        let url = fileURL(workspaceId: Self.sanitizeWorkspaceId(workspaceId))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies the JSONL (and its head sidecar) to `destination`, a directory.
    /// Returns the copied log URL.
    func export(workspaceId: String, to destination: URL) throws -> URL {
        let sanitizedId = Self.sanitizeWorkspaceId(workspaceId)
        let source = fileURL(workspaceId: sanitizedId)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
        let head = headURL(workspaceId: sanitizedId)
        if fm.fileExists(atPath: head.path) {
            let headTarget = destination.appendingPathComponent(head.lastPathComponent)
            if fm.fileExists(atPath: headTarget.path) { try fm.removeItem(at: headTarget) }
            try fm.copyItem(at: head, to: headTarget)
        }
        return target
    }

    // MARK: - Typed recorders (host side)

    func recordAttestationGranted(
        record: WorkspaceAgentAccessHost.WorkspaceKeyRecord,
        agentName: String,
        sealed: Bool
    ) {
        let actor = WorkspaceAuditActor(
            wallet: record.wallet, accountId: record.accountId, role: record.role
        )
        append(
            .attestationGranted,
            workspaceId: record.workspaceId,
            actor: actor,
            agentAddress: record.agentAddressLower,
            agentName: agentName,
            details: [
                "attestation_expires_at": Self.iso(record.attestationExpiresAt),
            ]
        )
        append(
            .keyMinted,
            workspaceId: record.workspaceId,
            actor: actor,
            agentAddress: record.agentAddressLower,
            agentName: agentName,
            target: record.keyId.uuidString,
            details: [
                "expires_at": Self.iso(record.attestationExpiresAt),
                "sealed": sealed ? "true" : "false",
            ]
        )
    }

    func recordAttestationDenied(
        attestation: WorkspaceMembershipAttestation,
        agentAddress: String,
        rejection: WorkspaceRedeemRejection
    ) {
        append(
            .attestationDenied,
            workspaceId: attestation.payload.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: attestation.payload.wallet,
                accountId: attestation.payload.accountId,
                role: attestation.payload.typedRole.rawValue
            ),
            agentAddress: agentAddress,
            details: [
                "reason": Self.reasonCode(rejection),
                "http_status": String(rejection.httpStatus),
            ]
        )
    }

    func recordKeyRevoked(
        record: WorkspaceAgentAccessHost.WorkspaceKeyRecord,
        reason: RevocationReason
    ) {
        append(
            .keyRevoked,
            workspaceId: record.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: record.wallet, accountId: record.accountId, role: record.role
            ),
            agentAddress: record.agentAddressLower,
            target: record.keyId.uuidString,
            details: ["reason": reason.rawValue]
        )
    }

    func recordRunStarted(
        record: WorkspaceAgentAccessHost.WorkspaceKeyRecord,
        agentId: UUID,
        runKey: String,
        model: String,
        callerName: String?
    ) async {
        append(
            .runStarted,
            workspaceId: record.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: record.wallet, accountId: record.accountId, name: callerName, role: record.role
            ),
            agentAddress: record.agentAddressLower,
            agentName: await agentName(for: agentId),
            target: runKey,
            details: ["model": model]
        )
    }

    func recordRunFinished(
        record: WorkspaceAgentAccessHost.WorkspaceKeyRecord,
        agentId: UUID,
        runKey: String,
        model: String,
        success: Bool,
        summary: String,
        toolNames: [String],
        toolErrorCount: Int
    ) async {
        var details: [String: String] = [
            "model": model,
            "success": success ? "true" : "false",
            "summary": summary,
            "tool_count": String(toolNames.count),
        ]
        if !toolNames.isEmpty {
            details["tools"] = toolNames.joined(separator: ",")
        }
        if toolErrorCount > 0 {
            details["tool_errors"] = String(toolErrorCount)
        }
        append(
            .runFinished,
            workspaceId: record.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: record.wallet, accountId: record.accountId, role: record.role
            ),
            agentAddress: record.agentAddressLower,
            agentName: await agentName(for: agentId),
            target: runKey,
            details: details
        )
    }

    func recordRunStopped(
        record: WorkspaceAgentAccessHost.WorkspaceKeyRecord,
        agentId: UUID,
        runKey: String
    ) async {
        append(
            .runStoppedByOwner,
            workspaceId: record.workspaceId,
            actor: .me(),
            agentAddress: record.agentAddressLower,
            agentName: await agentName(for: agentId),
            target: runKey,
            details: ["caller_wallet": record.wallet]
        )
    }

    func recordRunRejected(
        record: WorkspaceAgentAccessHost.WorkspaceKeyRecord,
        agentId: UUID,
        reason: String,
        detail: String?
    ) async {
        var details = ["reason": reason]
        if let detail, !detail.isEmpty { details["detail"] = detail }
        append(
            .runRejected,
            workspaceId: record.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: record.wallet, accountId: record.accountId, role: record.role
            ),
            agentAddress: record.agentAddressLower,
            agentName: await agentName(for: agentId),
            details: details
        )
    }

    /// A workspace-minted key was refused at a route it may not reach. Keys
    /// that are not workspace-minted (plain paired connectors) have no
    /// workspace to attribute to and are only in the Insights request log.
    // MARK: Outbound runs (client side)

    /// This instance started a headless run on a teammate's shared agent.
    /// `source` is the trigger (`delegation`, `schedule`, `watcher`,
    /// `channel`); `runKey` is the local task/session id.
    func recordOutboundRunStarted(
        ref: WorkspaceAgentRef,
        agentName: String?,
        runKey: String,
        source: SessionSource
    ) {
        append(
            .outboundRunStarted,
            workspaceId: ref.workspaceId,
            actor: .me(),
            agentAddress: ref.agentAddress,
            agentName: agentName,
            target: runKey,
            details: ["source": source.rawValue]
        )
    }

    func recordOutboundRunFinished(
        ref: WorkspaceAgentRef,
        agentName: String?,
        runKey: String,
        source: SessionSource,
        success: Bool,
        summary: String
    ) {
        append(
            .outboundRunFinished,
            workspaceId: ref.workspaceId,
            actor: .me(),
            agentAddress: ref.agentAddress,
            agentName: agentName,
            target: runKey,
            details: [
                "source": source.rawValue,
                "success": success ? "true" : "false",
                "summary": String(summary.prefix(200)),
            ]
        )
    }

    /// A headless run was refused before it started (offline host, lapsed
    /// key, agent unshared, router disabled…).
    func recordOutboundRunRefused(
        ref: WorkspaceAgentRef,
        agentName: String?,
        source: SessionSource,
        reason: String
    ) {
        append(
            .outboundRunRefused,
            workspaceId: ref.workspaceId,
            actor: .me(),
            agentAddress: ref.agentAddress,
            agentName: agentName,
            details: ["source": source.rawValue, "reason": String(reason.prefix(200))]
        )
    }

    func recordScopeDenied(keyNonce: String?, audience: String, method: String, path: String) async {
        guard let keyNonce,
            let record = await WorkspaceAgentAccessHost.shared.workspaceKeyRecord(forKeyNonce: keyNonce)
        else { return }
        append(
            .scopeDenied,
            workspaceId: record.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: record.wallet, accountId: record.accountId, role: record.role
            ),
            agentAddress: record.agentAddressLower,
            target: "\(method) \(path)",
            details: ["audience": audience]
        )
    }

    func recordTaskCancelled(taskId: UUID, keyNonce: String?, audience: String?) async {
        guard let keyNonce,
            let record = await WorkspaceAgentAccessHost.shared.workspaceKeyRecord(forKeyNonce: keyNonce)
        else { return }
        append(
            .taskCancelled,
            workspaceId: record.workspaceId,
            actor: WorkspaceAuditActor(
                wallet: record.wallet, accountId: record.accountId, role: record.role
            ),
            agentAddress: record.agentAddressLower,
            target: taskId.uuidString,
            details: audience.map { ["audience": $0] } ?? [:]
        )
    }

    // MARK: - Typed recorders (owner actions from this app)

    func recordOwnerAction(
        _ event: WorkspaceAuditEventKind,
        workspaceId: String,
        agentAddress: String? = nil,
        agentName: String? = nil,
        target: String? = nil,
        details: [String: String] = [:]
    ) {
        append(
            event,
            workspaceId: workspaceId,
            actor: .me(),
            agentAddress: agentAddress,
            agentName: agentName,
            target: target,
            details: details
        )
    }

    // MARK: - Internals

    /// Best-effort display name at event time (the agent may be renamed or
    /// deleted later; the address stays the stable identity).
    private func agentName(for agentId: UUID) async -> String? {
        await MainActor.run { AgentManager.shared.agent(for: agentId)?.name }
    }

    private static func reasonCode(_ rejection: WorkspaceRedeemRejection) -> String {
        switch rejection {
        case .malformedRequest: return "malformed_request"
        case .attestationInvalid: return "attestation_invalid"
        case .attestationExpired: return "attestation_expired"
        case .unknownChallenge: return "unknown_challenge"
        case .badWalletSignature: return "bad_wallet_signature"
        case .agentNotFound: return "agent_not_found"
        case .notShared: return "not_shared"
        case .rosterUnavailable: return "roster_unavailable"
        case .mintFailed: return "mint_failed"
        }
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Keep the on-disk record small and free of accidental content: each
    /// detail value is clipped, and the bag itself is capped.
    private static func boundedDetails(_ details: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in details.sorted(by: { $0.key < $1.key }).prefix(32) {
            out[String(key.prefix(64))] = String(value.prefix(512))
        }
        return out
    }

    /// Workspace ids come from the router; constrain them to a safe file
    /// name so a hostile id can't escape the audit directory.
    static func sanitizeWorkspaceId(_ id: String) -> String {
        let allowed = id.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        return String(String.UnicodeScalarView(allowed).prefix(128))
    }

    private static let canonicalEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// `SHA-256(prevHash || "\n" || canonicalJSON(body))`, hex.
    fileprivate static func hash(of body: WorkspaceAuditRecord.Body) -> String? {
        guard let json = try? canonicalEncoder.encode(body) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(body.prevHash.utf8))
        hasher.update(data: Data("\n".utf8))
        hasher.update(data: json)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(workspaceId: String) -> URL {
        directoryURL().appendingPathComponent("\(workspaceId).jsonl")
    }

    private func headURL(workspaceId: String) -> URL {
        directoryURL().appendingPathComponent("\(workspaceId).head")
    }

    private func currentTail(for workspaceId: String) -> (seq: Int, hash: String) {
        if let cached = tails[workspaceId] { return cached }
        // Prefer the last decodable line over the sidecar so an append after
        // a truncated tail continues the real chain (the verifier will still
        // flag the truncation via the sidecar mismatch that preceded it).
        if let lines = readLines(workspaceId: workspaceId) {
            let decoder = JSONDecoder()
            for line in lines.reversed() where !line.isEmpty {
                if let data = line.data(using: .utf8),
                    let record = try? decoder.decode(WorkspaceAuditRecord.self, from: data)
                {
                    let tail = (record.seq, record.hash)
                    tails[workspaceId] = tail
                    return tail
                }
            }
        }
        if let head = readHead(workspaceId: workspaceId) {
            tails[workspaceId] = head
            return head
        }
        let genesis = (0, Self.genesisHash)
        tails[workspaceId] = genesis
        return genesis
    }

    private func readLines(workspaceId: String) -> [String]? {
        let url = fileURL(workspaceId: workspaceId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    private func readHead(workspaceId: String) -> (seq: Int, hash: String)? {
        let url = headURL(workspaceId: workspaceId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let seq = Int(parts[0]), parts[1].count == 64 else { return nil }
        return (seq, parts[1])
    }

    private func write(_ record: WorkspaceAuditRecord, workspaceId: String) throws {
        let fm = FileManager.default
        let directory = directoryURL()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(workspaceId: workspaceId)
        var line = try Self.canonicalEncoder.encode(record)
        line.append(0x0A)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } else {
            try line.write(to: url, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let head = "\(record.seq):\(record.hash)\n"
        try Data(head.utf8).write(to: headURL(workspaceId: workspaceId), options: [.atomic])
    }
}
