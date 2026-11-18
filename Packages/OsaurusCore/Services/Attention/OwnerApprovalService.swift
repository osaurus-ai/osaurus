//
//  OwnerApprovalService.swift
//  osaurus
//
//  Approval flows for shared agents: when a teammate, an invite-link peer or
//  another person's agent drives one of the owner's shared agents and the
//  run reaches an `.ask` tool, the caller cannot answer the card. With the
//  agent's `sharedToolApproval` set to Ask Me, the run parks and the owner
//  decides — on the hosted conversation's inline card, a desktop
//  notification, or the paired phone. The caller's stream shows "Waiting
//  for @owner to approve <tool>" and resumes when the owner answers, or the
//  call is denied when the wait times out.
//
//  Only `.ask` tools reach here. `.deny` policies and the external-surface
//  deny list stay a hard floor in `ToolRegistry`. See docs/AGENT_ATTENTION.md.
//

import Foundation

/// What a shared agent does with an `.ask` tool when someone other than the
/// owner is driving it. Nil on `Agent` means `.deny`.
public struct SharedToolApprovalPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// The call fails: the caller cannot answer the card (the default).
        case deny
        /// Park the run and ask the owner.
        case askOwner = "ask_owner"
    }

    public var mode: Mode
    /// How long the run waits for the owner before the call is denied.
    public var timeoutSeconds: Int?

    public static let defaultTimeoutSeconds = 600
    public static let timeoutRange = 30 ... 86_400
    public static let deny = SharedToolApprovalPolicy(mode: .deny)

    public init(mode: Mode, timeoutSeconds: Int? = nil) {
        self.mode = mode
        self.timeoutSeconds = timeoutSeconds
    }

    public var effectiveTimeout: TimeInterval {
        let raw = timeoutSeconds ?? Self.defaultTimeoutSeconds
        return TimeInterval(min(max(raw, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound))
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case timeoutSeconds = "timeout_seconds"
    }
}

/// The `osaurus_owner_approval` SSE extension (docs/MOBILE_PROTOCOL.md §21).
/// Tool name only; arguments never leave the host.
struct OwnerApprovalStatus: Encodable, Sendable, Equatable {
    /// `waiting` | `approved` | `denied` | `timed_out`
    var phase: String
    var approval_id: String
    var name: String
    var call_id: String?
    /// "@owner" (handle-first label of the agent's owner).
    var owner: String
    /// ISO-8601, on `waiting`.
    var expires_at: String?
    /// Where the owner answered (`inline` | `desktop` | `phone`), once settled.
    var decided_on: String?
}

/// Bound for a shared-agent run by `/agents/{id}/run` when the agent's
/// policy is Ask Me.
struct OwnerApprovalRoute: Sendable {
    let agentId: UUID
    let agentName: String
    let agentAddress: String?
    let caller: Participant
    /// The workspace the caller reached the agent through, for the audit
    /// trail. Nil for invite-link peers.
    let workspaceId: String?
    /// The hosted conversation's task / session id (inline card target).
    let hostedSessionId: UUID?
    /// "Allow for this conversation" scope: caller + agent + conversation.
    let conversationKey: String
    let timeout: TimeInterval
    /// Streams `osaurus_owner_approval` to the caller.
    let onStatus: @Sendable (OwnerApprovalStatus) -> Void
}

enum OwnerApprovalDecision: Equatable, Sendable {
    case approved
    case allowedForConversation
    /// Allowed earlier in this conversation.
    case leased
    case denied
    case timedOut
    case abandoned
    /// The caller already has too many approvals waiting; not asked.
    case tooManyPending

    var isGranted: Bool {
        switch self {
        case .approved, .allowedForConversation, .leased: return true
        case .denied, .timedOut, .abandoned, .tooManyPending: return false
        }
    }

    /// The tool error the model (and the caller) sees on a refusal.
    func refusalMessage(toolName: String, ownerLabel: String) -> String {
        switch self {
        case .timedOut:
            return "No answer from the agent's owner (\(ownerLabel)) in time, so '\(toolName)' did not run. "
                + "Continue without it or ask the owner to try again."
        case .abandoned:
            return "The approval request for '\(toolName)' ended before the agent's owner answered."
        case .tooManyPending:
            return "Several requests are already waiting for the agent's owner (\(ownerLabel)), "
                + "so '\(toolName)' did not run. Wait for those answers before asking again."
        default:
            return "The agent's owner (\(ownerLabel)) declined '\(toolName)'. Continue without it."
        }
    }
}

@MainActor
final class OwnerApprovalService {
    static let shared = OwnerApprovalService()

    /// Tools allowed for the rest of a conversation. Kept in
    /// `~/.osaurus/attention/leases.json` (0600) so "Allow for This
    /// Conversation" survives a relaunch, and dropped with the conversation.
    struct Lease: Codable, Equatable {
        /// The hosted conversation the grant belongs to.
        var sessionId: UUID?
        var tools: Set<String>
        var grantedAt: Date
    }

    private struct Stored: Codable {
        var version = 1
        var leases: [String: Lease] = [:]
    }

    /// Conversations with grants kept; the oldest grants go first.
    static let leaseCapacity = 1_000

    /// Tools a caller on a shared run never gets a conversation lease for:
    /// one approved write must not cover every later path the caller picks.
    static let perCallOnSharedRuns: Set<String> = ["file_write", "file_edit"]

    /// Owner approvals one caller may have waiting at once; past this the
    /// call is denied without asking.
    static let pendingPerCallerLimit = 5

    private var stored: Stored?
    var leasesFileURL: URL?
    /// The arguments of each waiting approval, for the owner's other devices
    /// (`SyncServedChats`). Callers never get them.
    private(set) var pendingArguments: [UUID: String] = [:]

    private var resolvedLeasesURL: URL {
        leasesFileURL
            ?? OsaurusPaths.root()
            .appendingPathComponent("attention", isDirectory: true)
            .appendingPathComponent("leases.json")
    }

    /// The owner as callers see them: handle when claimed, else "the owner".
    var ownerLabel: String {
        Participant.owner().atHandle ?? L("the owner")
    }

    func hasLease(conversationKey: String, toolName: String) -> Bool {
        loadedLeases().leases[conversationKey]?.tools.contains(toolName) == true
    }

    func grantLease(conversationKey: String, toolName: String, sessionId: UUID?) {
        var state = loadedLeases()
        var lease = state.leases[conversationKey] ?? Lease(sessionId: sessionId, tools: [], grantedAt: Date())
        lease.tools.insert(toolName)
        lease.sessionId = lease.sessionId ?? sessionId
        lease.grantedAt = Date()
        state.leases[conversationKey] = lease
        if state.leases.count > Self.leaseCapacity {
            let oldest = state.leases.sorted { $0.value.grantedAt < $1.value.grantedAt }
                .prefix(state.leases.count - Self.leaseCapacity).map(\.key)
            for key in oldest { state.leases[key] = nil }
        }
        commitLeases(state)
    }

    func clearLeases(conversationKey: String) {
        var state = loadedLeases()
        guard state.leases.removeValue(forKey: conversationKey) != nil else { return }
        commitLeases(state)
    }

    /// Drops every grant made in a hosted conversation (it was deleted).
    func clearLeases(sessionId: UUID) {
        var state = loadedLeases()
        let before = state.leases.count
        state.leases = state.leases.filter { $0.value.sessionId != sessionId }
        guard state.leases.count != before else { return }
        commitLeases(state)
    }

    func resetForTesting(leasesFileURL: URL? = nil) {
        self.leasesFileURL = leasesFileURL
        stored = Stored()
    }

    /// Forgets the in-memory copy so the next read comes from disk (tests).
    func reloadLeasesForTesting() { stored = nil }

    private func loadedLeases() -> Stored {
        if let stored { return stored }
        let state: Stored
        switch AttentionFileIO.read(Stored.self, from: resolvedLeasesURL) {
        case .loaded(let value): state = value
        case .missing, .corrupt: state = Stored()
        }
        stored = state
        return state
    }

    private func commitLeases(_ state: Stored) {
        stored = state
        AttentionFileIO.write(state, to: resolvedLeasesURL)
    }

    /// Park until the owner answers, the wait times out, or the run ends.
    /// `perCallApproval` tools never take a conversation lease.
    func request(
        route: OwnerApprovalRoute,
        toolName: String,
        callId: String?,
        perCallApproval: Bool,
        arguments: String? = nil
    ) async -> OwnerApprovalDecision {
        if !perCallApproval, hasLease(conversationKey: route.conversationKey, toolName: toolName) {
            return .leased
        }
        if Task.isCancelled { return .abandoned }
        let callerKey = route.caller.key
        let waitingForCaller = AttentionCenter.shared.pending.filter {
            $0.kind == .ownerApproval && $0.requester?.key == callerKey
        }.count
        if waitingForCaller >= Self.pendingPerCallerLimit {
            AttentionLog.info("owner approval refused tool=\(toolName) reason=caller_pending_limit")
            return .tooManyPending
        }

        let id = UUID()
        let requestedAt = Date()
        let expiresAt = requestedAt.addingTimeInterval(route.timeout)
        let owner = ownerLabel
        var actions: [AttentionAction] = [.approve, .deny, .open]
        if !perCallApproval { actions.insert(.allowForConversation, at: 1) }
        let callerLabel = ParticipantFormatter.short(route.caller)
        var item = AttentionItem(
            id: id,
            kind: .ownerApproval,
            requester: route.caller,
            agent: .agent(name: route.agentName, address: route.agentAddress),
            agentId: route.agentId,
            sessionId: route.hostedSessionId,
            taskId: route.hostedSessionId,
            title: L("\(callerLabel) wants \(route.agentName) to use \(toolName)"),
            body: L("Allow to let it run. Nothing runs until you answer."),
            toolName: toolName,
            actions: actions,
            expiresAt: expiresAt,
            hasInlineCard: route.hostedSessionId != nil,
            link: route.hostedSessionId.map { .task($0) }
        )

        audit(.approvalRequested, route: route, approvalId: id, toolName: toolName)
        AttentionLog.info("owner approval waiting id=\(id) tool=\(toolName) caller=\(route.caller.kind.rawValue)")
        route.onStatus(
            OwnerApprovalStatus(
                phase: "waiting",
                approval_id: id.uuidString,
                name: toolName,
                call_id: callId,
                owner: owner,
                expires_at: ISO8601DateFormatter().string(from: expiresAt)
            )
        )

        let card = OwnerApprovalPromptState(
            attentionId: id,
            caller: route.caller,
            agentName: route.agentName,
            toolName: toolName,
            offersConversationLease: !perCallApproval,
            expiresAt: expiresAt
        )
        let hostedSession = route.hostedSessionId.flatMap {
            BackgroundTaskManager.shared.taskState(for: $0)?.chatSession
        }
        // The desktop and in-app channels hold back while a card is on
        // screen; only claim one when it will actually be shown.
        item.hasInlineCard = hostedSession != nil

        if let arguments { pendingArguments[id] = arguments }
        defer { pendingArguments[id] = nil }
        let resolution: AttentionResolution = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AttentionResolution, Never>) in
                hostedSession?.promptQueue.enqueue(.ownerApproval(card))
                AttentionCenter.shared.raise(item) { resolution in
                    continuation.resume(returning: resolution)
                }
                AttentionProducers.beginWaiting(
                    itemId: id, step: L("Waiting for your approval"), backgroundId: route.hostedSessionId)
                if Task.isCancelled {
                    AttentionCenter.shared.resolve(id: id, with: AttentionProducers.abandoned)
                }
            }
        } onCancel: {
            Task { @MainActor in
                AttentionCenter.shared.resolve(id: id, with: AttentionProducers.abandoned)
            }
        }

        AttentionProducers.endWaiting(itemId: id)
        card.settle()
        hostedSession?.promptQueue.remove { $0.id == ObjectIdentifier(card) }

        let decision: OwnerApprovalDecision
        switch resolution.outcome {
        case .approved: decision = .approved
        case .allowedForConversation:
            decision = perCallApproval ? .approved : .allowedForConversation
        case .timedOut: decision = .timedOut
        case .abandoned: decision = .abandoned
        case .denied, .dismissed, .replied: decision = .denied
        }
        if decision == .allowedForConversation {
            grantLease(conversationKey: route.conversationKey, toolName: toolName, sessionId: route.hostedSessionId)
        }
        AttentionLog.info(
            "owner approval settled id=\(id) tool=\(toolName) decision=\(decision) surface=\(resolution.surface.rawValue)"
        )
        if let event = Self.auditEvent(for: decision) {
            var details = ["surface": resolution.surface.rawValue]
            if decision == .allowedForConversation { details["scope"] = "conversation" }
            if let decider = resolution.decidedBy, decider.kind == .ownerDevice {
                details["device"] = ParticipantFormatter.short(decider)
            }
            details["wait_ms"] = String(Int(max(0, Date().timeIntervalSince(requestedAt)) * 1000))
            audit(event, route: route, approvalId: id, toolName: toolName, details: details)
        }
        // Abandoned (the run ended, or Osaurus is quitting) still reaches a
        // caller whose stream is open, as a denial with no decider.
        route.onStatus(
            OwnerApprovalStatus(
                phase: decision.isGranted ? "approved" : (decision == .timedOut ? "timed_out" : "denied"),
                approval_id: id.uuidString,
                name: toolName,
                call_id: callId,
                owner: owner,
                decided_on: resolution.surface == .system ? nil : resolution.surface.rawValue
            )
        )
        return decision
    }

    static func auditEvent(for decision: OwnerApprovalDecision) -> WorkspaceAuditEventKind? {
        switch decision {
        case .approved, .allowedForConversation: return .approvalGranted
        case .denied: return .approvalDenied
        case .timedOut: return .approvalTimedOut
        case .leased, .abandoned, .tooManyPending: return nil
        }
    }

    private func audit(
        _ event: WorkspaceAuditEventKind,
        route: OwnerApprovalRoute,
        approvalId: UUID,
        toolName: String,
        details: [String: String] = [:]
    ) {
        guard let workspaceId = route.workspaceId, !workspaceId.isEmpty else { return }
        Task {
            await WorkspaceAuditLog.shared.recordApproval(
                event,
                workspaceId: workspaceId,
                caller: route.caller,
                agentAddress: route.agentAddress,
                agentName: route.agentName,
                approvalId: approvalId,
                toolName: toolName,
                details: details
            )
        }
    }

    // MARK: - ask_owner

    enum OwnerAnswer: Equatable, Sendable {
        case replied(String)
        case dismissed
        case timedOut
        case abandoned
        case tooManyPending
    }

    /// The inline card for an `ask_owner` question in the hosted chat. A
    /// reply or dismissal resolves the attention item (first answer wins
    /// across surfaces); teardown releases the caller's run.
    static func ownerQuestionCard(
        id: UUID, question: String, agentName: String, caller: Participant
    ) -> ClarifyPromptState {
        let asked = String(
            format: L("%@ asks you, during %@'s conversation:"),
            agentName, ParticipantFormatter.short(caller)
        )
        return ClarifyPromptState(
            question: asked + "\n\n" + String(question.prefix(1_000)),
            onSubmit: { text in
                AttentionCenter.shared.resolve(id: id, with: AttentionProducers.inline(.replied, replyText: text))
            },
            onCancel: {
                AttentionCenter.shared.resolve(id: id, with: AttentionProducers.abandoned)
            },
            onUserCancel: {
                AttentionCenter.shared.resolve(id: id, with: AttentionProducers.inline(.dismissed))
            }
        )
    }

    /// The shared agent asks its owner a question on behalf of the run
    /// (`ask_owner`). Same wait as an approval — notification Reply field,
    /// paired phone, Approvals — answered with text.
    func ask(route: OwnerApprovalRoute, question: String, callId: String?) async -> OwnerAnswer {
        if Task.isCancelled { return .abandoned }
        let callerKey = route.caller.key
        let waitingForCaller = AttentionCenter.shared.pending.filter {
            ($0.kind == .ownerApproval || $0.kind == .clarification) && $0.requester?.key == callerKey
        }.count
        if waitingForCaller >= Self.pendingPerCallerLimit { return .tooManyPending }

        let id = UUID()
        let expiresAt = Date().addingTimeInterval(route.timeout)
        let owner = ownerLabel
        let hostedSession = route.hostedSessionId.flatMap {
            BackgroundTaskManager.shared.taskState(for: $0)?.chatSession
        }
        let card = Self.ownerQuestionCard(
            id: id, question: question, agentName: route.agentName, caller: route.caller)
        var item = AttentionItem(
            id: id,
            kind: .clarification,
            requester: route.caller,
            agent: .agent(name: route.agentName, address: route.agentAddress),
            agentId: route.agentId,
            sessionId: route.hostedSessionId,
            taskId: route.hostedSessionId,
            title: L("\(route.agentName) has a question for you"),
            body: String(question.prefix(1_000)),
            toolName: AskOwnerTool.toolName,
            actions: [.reply, .dismiss, .open],
            expiresAt: expiresAt,
            hasInlineCard: false,
            link: route.hostedSessionId.map { .task($0) }
        )
        // Same rule as approvals: the question is a card in the hosted chat
        // when that chat exists, so the desktop and in-app channels hold back
        // only when the card is actually on screen.
        item.hasInlineCard = hostedSession != nil
        AttentionLog.info("owner question waiting id=\(id) caller=\(route.caller.kind.rawValue)")
        route.onStatus(
            OwnerApprovalStatus(
                phase: "waiting", approval_id: id.uuidString, name: AskOwnerTool.toolName, call_id: callId,
                owner: owner, expires_at: ISO8601DateFormatter().string(from: expiresAt)))

        let resolution: AttentionResolution = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AttentionResolution, Never>) in
                hostedSession?.promptQueue.enqueue(.clarify(card))
                AttentionCenter.shared.raise(item) { resolution in
                    continuation.resume(returning: resolution)
                }
                AttentionProducers.beginWaiting(
                    itemId: id, step: L("Waiting for your answer"), backgroundId: route.hostedSessionId)
                if Task.isCancelled {
                    AttentionCenter.shared.resolve(id: id, with: AttentionProducers.abandoned)
                }
            }
        } onCancel: {
            Task { @MainActor in
                AttentionCenter.shared.resolve(id: id, with: AttentionProducers.abandoned)
            }
        }
        AttentionProducers.endWaiting(itemId: id)
        card.cancel()
        hostedSession?.promptQueue.remove { $0.id == ObjectIdentifier(card) }

        let answer: OwnerAnswer
        switch resolution.outcome {
        case .replied:
            let text = resolution.replyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            answer = text.isEmpty ? .dismissed : .replied(String(text.prefix(AttentionLimits.textCharacters)))
        case .timedOut: answer = .timedOut
        case .abandoned: answer = .abandoned
        case .approved, .allowedForConversation, .denied, .dismissed: answer = .dismissed
        }
        AttentionLog.info("owner question settled id=\(id) surface=\(resolution.surface.rawValue)")
        let phase: String
        switch answer {
        case .replied: phase = "answered"
        case .timedOut: phase = "timed_out"
        case .dismissed, .abandoned, .tooManyPending: phase = "denied"
        }
        route.onStatus(
            OwnerApprovalStatus(
                phase: phase, approval_id: id.uuidString, name: AskOwnerTool.toolName, call_id: callId,
                owner: owner, decided_on: resolution.surface == .system ? nil : resolution.surface.rawValue))
        return answer
    }
}
