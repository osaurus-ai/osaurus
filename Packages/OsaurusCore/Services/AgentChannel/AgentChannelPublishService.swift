//
//  AgentChannelPublishService.swift
//  osaurus
//
//  Serialized authorization + durable-intent pipeline for PROACTIVE agent
//  channel publishing (`agent_channel_publish`). Reactive replies keep
//  using the existing reply-token / auto-reply paths; this service only
//  handles binding-scoped outbound sends that were not triggered by an
//  inbound channel message.
//

import Foundation

extension Notification.Name {
    /// Posted after any durable outbound-intent mutation (claim, send,
    /// failure, operator resolution, reconciliation) so the outbox UI and
    /// pending-approval badges refresh without polling.
    public static let agentChannelOutboundIntentsChanged =
        Notification.Name("AgentChannelOutboundIntentsChanged")
}

/// Context of the run attempting a proactive publish. Captured from
/// `ChatExecutionContext` at the tool boundary and passed explicitly so
/// the authorization matrix is testable without task-local plumbing.
struct AgentChannelPublishContext: Sendable {
    let agentId: UUID?
    let source: SessionSource?
    let isExternalSurface: Bool
    let isUnattendedDispatch: Bool
    let sessionId: String?
    /// True when the EFFECTIVE tool permission for this invocation resolved
    /// to `.ask` on a run where nobody can answer a prompt (unattended
    /// dispatch with a user-configured `.ask` policy on the publish tool).
    /// The publish service must then queue the intent for operator approval
    /// even when the binding's own mode is `autonomous` — the user's global
    /// policy narrows the binding policy, never the other way around.
    let requiresOperatorApproval: Bool

    init(
        agentId: UUID?,
        source: SessionSource?,
        isExternalSurface: Bool,
        isUnattendedDispatch: Bool,
        sessionId: String? = nil,
        requiresOperatorApproval: Bool = false
    ) {
        self.agentId = agentId
        self.source = source
        self.isExternalSurface = isExternalSurface
        self.isUnattendedDispatch = isUnattendedDispatch
        self.sessionId = sessionId
        self.requiresOperatorApproval = requiresOperatorApproval
    }

    /// Snapshot of the live task-local execution context.
    static func current(requiresOperatorApproval: Bool = false) -> AgentChannelPublishContext {
        AgentChannelPublishContext(
            agentId: ChatExecutionContext.currentAgentId,
            source: ChatExecutionContext.currentSessionSource,
            isExternalSurface: ChatExecutionContext.isExternalSurface,
            isUnattendedDispatch: ChatExecutionContext.isUnattendedDispatch,
            sessionId: ChatExecutionContext.currentSessionId,
            requiresOperatorApproval: requiresOperatorApproval
        )
    }
}

struct AgentChannelPublishRequest: Sendable {
    let bindingId: String
    let content: String
    let intentKey: String
    /// Optional model-supplied thread. Only honored when the binding does
    /// NOT pin a thread itself; a binding-pinned thread always wins and a
    /// conflicting request is refused. Thread writability is enforced by
    /// the provider service at send time (Slack parses `channel:ts` and
    /// requires a writable channel, Discord threads are channels on the
    /// write allowlist, custom HTTP validates via `requireWritableRoom`).
    let threadId: String?

    init(bindingId: String, content: String, intentKey: String, threadId: String? = nil) {
        self.bindingId = bindingId
        self.content = content
        self.intentKey = intentKey
        let trimmed = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// Typed result of a publish attempt. Every case maps to a structured tool
/// envelope; denials carry a stable machine code plus whether the caller
/// may retry (rate limits / transient provider failures) or must stop.
enum AgentChannelPublishOutcome: Sendable, Equatable {
    case sent(intentId: String, providerMessageId: String?)
    case draftRecorded(intentId: String)
    case queuedForApproval(intentId: String)
    /// The same intent key was already recorded; no provider I/O happened.
    case duplicate(intentId: String, status: AgentChannelOutboundIntentStatus)
    case denied(code: String, message: String, retryable: Bool)

    var statusLabel: String {
        switch self {
        case .sent: return "sent"
        case .draftRecorded: return "draft_recorded"
        case .queuedForApproval: return "queued_for_approval"
        case .duplicate: return "duplicate"
        case .denied: return "denied"
        }
    }
}

/// Serialized proactive-publish pipeline.
///
/// An actor so per-binding rate checks, idempotent intent claims, and the
/// provider write are strictly ordered — two concurrent publishes of the
/// same intent key resolve to exactly one provider write, and rate policy
/// cannot be raced past. Swift actors are reentrant across `await`, so the
/// provider write itself is additionally guarded by an explicit per-binding
/// lock (`withBindingLock`): two different intent keys for one binding are
/// serialized end-to-end (policy check → send → durable transition), while
/// unrelated bindings still send concurrently. Every attempt re-resolves
/// the binding and the destination connection at execution time, so a stale
/// queued item can never bypass settings that changed after it was recorded.
actor AgentChannelPublishService {
    static let shared = AgentChannelPublishService()

    /// Hard cap on outbound content, applied before any provider limits.
    static let maxContentLength = 4_000
    /// Hard cap on the caller-supplied idempotency key. Past this the key is
    /// not an identifier anymore; it also bounds what audit metadata stores.
    static let maxIntentKeyLength = 200
    static let auditAction = "proactive_publish"
    /// Terminal outbox history (sent / failed / cancelled) is pruned past
    /// this age. Unresolved rows are never pruned.
    static let terminalRetention: TimeInterval = 30 * 24 * 3_600

    /// Performs the actual provider write for a resolved binding and
    /// returns the provider message id when one can be extracted.
    typealias Sender = @Sendable (AgentChannelBinding, String) async throws -> String?

    private let loadConfiguration: @Sendable () -> AgentChannelConfiguration
    private let resolveConnection: @Sendable (String) throws -> AgentChannelConnection
    private let killSwitchSnapshot: @Sendable () -> ChannelWriteKillSwitchSnapshot
    private let sender: Sender
    private let store: AgentChannelMessageStore
    private let now: @Sendable () -> Date

    /// Instant this service instance came up. Startup reconciliation only
    /// touches `sending` rows older than this, so it can never clobber a
    /// row this instance itself just claimed.
    private let startedAt: Date
    private var didRunStartupReconciliation = false

    /// Explicit per-binding critical section (see the actor doc comment).
    private var lockedBindingIds: Set<String> = []
    private var bindingLockWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        // Stored bindings plus automatic (derived) destinations: automatic
        // ids must resolve on the send path AND at approval time, so an
        // allowlist change that removes the derived binding refuses the
        // queued item via the existing `binding_removed` path.
        loadConfiguration: @escaping @Sendable () -> AgentChannelConfiguration = {
            AgentChannelAutoDestinationResolver.effectiveConfiguration()
        },
        resolveConnection: @escaping @Sendable (String) throws -> AgentChannelConnection = {
            try AgentChannelConnectionService.shared.resolvedConnectionView(id: $0)
        },
        killSwitchSnapshot: @escaping @Sendable () -> ChannelWriteKillSwitchSnapshot = {
            ChannelWriteKillSwitch.shared.snapshot()
        },
        sender: @escaping Sender = AgentChannelPublishService.defaultSender,
        store: AgentChannelMessageStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadConfiguration = loadConfiguration
        self.resolveConnection = resolveConnection
        self.killSwitchSnapshot = killSwitchSnapshot
        self.sender = sender
        self.store = store
        self.now = now
        self.startedAt = now()
    }

    // MARK: - Publish (tool path)

    func publish(
        _ request: AgentChannelPublishRequest,
        context: AgentChannelPublishContext
    ) async -> AgentChannelPublishOutcome {
        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return .denied(
                code: "empty_content",
                message: "Message content is required.",
                retryable: false
            )
        }
        guard content.count <= Self.maxContentLength else {
            return .denied(
                code: "content_too_long",
                message: "Message content exceeds \(Self.maxContentLength) characters.",
                retryable: false
            )
        }
        let intentKey = request.intentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intentKey.isEmpty else {
            return .denied(
                code: "missing_intent_key",
                message: "A caller-stable `intent_key` is required for idempotent publishing.",
                retryable: false
            )
        }
        guard intentKey.count <= Self.maxIntentKeyLength else {
            return .denied(
                code: "intent_key_too_long",
                message: "`intent_key` exceeds \(Self.maxIntentKeyLength) characters.",
                retryable: false
            )
        }

        // Surface gate first: proactive publishing is never reachable from
        // external surfaces (HTTP agent runs, the MCP bridge) or from runs
        // triggered by an inbound channel message — those must stay
        // reactive and sender-bound.
        guard !context.isExternalSurface else {
            return deniedAndAudited(
                code: "external_surface_denied",
                message: "Proactive channel publishing is not available on external surfaces.",
                request: request,
                context: context,
                binding: nil
            )
        }
        guard let agentId = context.agentId else {
            return deniedAndAudited(
                code: "missing_agent_context",
                message: "No agent identity is bound for this run.",
                request: request,
                context: context,
                binding: nil
            )
        }
        guard let source = context.source,
            let runSource = AgentChannelBindingRunSource(sessionSource: source)
        else {
            return deniedAndAudited(
                code: "run_source_not_allowed",
                message:
                    "Proactive publishing is only available from chat, schedule, watcher, "
                    + "or self-scheduled runs.",
                request: request,
                context: context,
                binding: nil
            )
        }

        // Binding resolution + ownership. The binding is re-read from the
        // store on every attempt so settings edits apply immediately.
        let configuration = loadConfiguration()
        guard let binding = configuration.binding(id: request.bindingId) else {
            return deniedAndAudited(
                code: "binding_not_found",
                message: "No destination binding `\(request.bindingId)` is configured.",
                request: request,
                context: context,
                binding: nil
            )
        }
        guard binding.agentId == agentId else {
            return deniedAndAudited(
                code: "binding_not_owned",
                message: "Destination binding `\(binding.id)` belongs to a different agent.",
                request: request,
                context: context,
                binding: binding
            )
        }
        guard binding.enabled else {
            return deniedAndAudited(
                code: "binding_disabled",
                message: "Destination binding `\(binding.id)` is disabled.",
                request: request,
                context: context,
                binding: binding
            )
        }
        guard binding.outboundMode != .off else {
            return deniedAndAudited(
                code: "binding_mode_off",
                message: "Destination binding `\(binding.id)` has outbound mode `off`.",
                request: request,
                context: context,
                binding: binding
            )
        }
        guard binding.allows(source: runSource) else {
            return deniedAndAudited(
                code: "run_source_not_allowed",
                message:
                    "Destination binding `\(binding.id)` does not allow "
                    + "`\(runSource.rawValue)` runs.",
                request: request,
                context: context,
                binding: binding
            )
        }

        // Thread contract: a binding-pinned thread always wins; a model-
        // supplied thread is only honored when the binding leaves the
        // thread open, and a conflicting request is an argument error.
        if let pinnedThread = binding.threadId, let requestedThread = request.threadId,
            pinnedThread != requestedThread
        {
            return deniedAndAudited(
                code: "thread_conflict",
                message:
                    "Destination binding `\(binding.id)` is pinned to thread "
                    + "`\(pinnedThread)`; omit `thread_id` or match it.",
                request: request,
                context: context,
                binding: binding
            )
        }
        let effectiveThreadId = binding.threadId ?? request.threadId

        // Destination re-validation (draft mode skips: no provider I/O).
        let willSendNow: Bool
        let initialStatus: AgentChannelOutboundIntentStatus
        switch binding.outboundMode {
        case .off:
            return .denied(code: "binding_mode_off", message: "Unreachable.", retryable: false)
        case .draft:
            willSendNow = false
            initialStatus = .draft
        case .confirm:
            // Unattended confirm queues a pending outbound item for the
            // operator instead of prompting; attended confirm reached this
            // point only after the interactive approval card was granted
            // (the registry's contextual permission hook resolves `.ask`).
            willSendNow = !context.isUnattendedDispatch && !context.requiresOperatorApproval
            initialStatus = willSendNow ? .sending : .pending
        case .autonomous:
            // A user-configured `.ask` on the publish tool narrows even an
            // autonomous binding on unattended runs: queue for approval
            // instead of sending (strictest wins, but never stall the run).
            willSendNow = !context.requiresOperatorApproval
            initialStatus = willSendNow ? .sending : .pending
        }

        // Durable idempotent claim FIRST, before any send-time policy check:
        // a replayed intent key must always report `duplicate`, not whatever
        // rate/kill-switch state happens to hold right now. Send-time policy
        // runs in `authorizeAndPerformSend` for every path that would write.
        do {
            try store.openIfNeeded()
        } catch {
            return .denied(
                code: "ledger_unavailable",
                message: "Outbound ledger is unavailable: \(error.localizedDescription)",
                retryable: true
            )
        }
        reconcileAndPruneIfNeeded()
        let intent = AgentChannelOutboundIntent(
            agentId: agentId,
            bindingId: binding.id,
            connectionId: binding.connectionId,
            roomId: binding.roomId,
            threadId: effectiveThreadId,
            intentKey: intentKey,
            content: content,
            status: initialStatus,
            runSource: runSource.rawValue,
            sessionId: context.sessionId,
            createdAt: now(),
            updatedAt: now()
        )
        let claim: (intent: AgentChannelOutboundIntent, inserted: Bool)
        do {
            claim = try store.upsertOutboundIntentIfNew(intent)
        } catch {
            return .denied(
                code: "ledger_write_failed",
                message: "Failed to record outbound intent: \(error.localizedDescription)",
                retryable: true
            )
        }

        if !claim.inserted {
            // Replayed intent key. Completed intents are terminal; drafts
            // and pending items are already recorded; an in-flight send is
            // reported as retryable so the caller can poll, not resend; an
            // unknown delivery must never be auto-retried.
            switch claim.intent.status {
            case .sending:
                return .denied(
                    code: "intent_in_flight",
                    message: "This intent key is already being sent.",
                    retryable: true
                )
            case .deliveryUnknown:
                audit(
                    status: .duplicate,
                    reason: "intent_key_replayed_delivery_unknown",
                    request: request,
                    context: context,
                    binding: binding,
                    content: content
                )
                return .duplicate(intentId: claim.intent.id, status: claim.intent.status)
            case .failed:
                // Retry a failed intent only when this attempt would send
                // now AND the stored route still matches the binding — an
                // edited binding must not silently resend old content to a
                // new destination. The claim is a CAS so concurrent retries
                // collapse.
                guard routeMatches(binding: binding, intent: claim.intent) else {
                    return deniedAndAudited(
                        code: "binding_route_changed",
                        message:
                            "The destination binding's route changed since this intent was "
                            + "recorded; use a new intent_key for the new destination.",
                        request: request,
                        context: context,
                        binding: binding
                    )
                }
                guard willSendNow,
                    (try? store.transitionOutboundIntent(
                        id: claim.intent.id,
                        from: .failed,
                        to: .sending,
                        updatedAt: now()
                    )) == true
                else {
                    return .duplicate(intentId: claim.intent.id, status: claim.intent.status)
                }
                notifyOutboxChanged()
                return await authorizeAndPerformSend(
                    intentId: claim.intent.id,
                    binding: sendRoute(binding: binding, intent: claim.intent),
                    content: claim.intent.content,
                    request: request,
                    context: context
                )
            case .draft, .pending, .sent, .cancelled:
                audit(
                    status: .duplicate,
                    reason: "intent_key_replayed",
                    request: request,
                    context: context,
                    binding: binding,
                    content: content
                )
                return .duplicate(intentId: claim.intent.id, status: claim.intent.status)
            }
        }

        notifyOutboxChanged()
        switch initialStatus {
        case .draft:
            audit(
                status: .accepted,
                reason: "draft_recorded",
                request: request,
                context: context,
                binding: binding,
                content: content
            )
            return .draftRecorded(intentId: claim.intent.id)
        case .pending:
            audit(
                status: .accepted,
                reason: "queued_for_approval",
                request: request,
                context: context,
                binding: binding,
                content: content
            )
            return .queuedForApproval(intentId: claim.intent.id)
        case .sending:
            return await authorizeAndPerformSend(
                intentId: claim.intent.id,
                binding: sendRoute(binding: binding, intent: claim.intent),
                content: content,
                request: request,
                context: context
            )
        case .sent, .failed, .cancelled, .deliveryUnknown:
            return .denied(code: "internal_error", message: "Unreachable.", retryable: false)
        }
    }

    // MARK: - Operator actions (outbox path)

    /// Operator approval of a `pending` intent. Authorization is re-run in
    /// full against the CURRENT binding/connection/kill-switch state — a
    /// stale queued item can never bypass settings that changed since it
    /// was recorded — and the stored route is compared field-by-field with
    /// the current binding so an edited binding can never send old content
    /// to a destination the operator did not see.
    func approvePendingIntent(id: String) async -> AgentChannelPublishOutcome {
        await operatorSend(
            id: id,
            expectedStatus: .pending,
            requiredModes: [.confirm, .autonomous],
            keepStatusOnRetryableDenial: true
        )
    }

    /// Operator explicitly sending a recorded draft. The operator action IS
    /// the human approval, so any non-`off` outbound mode qualifies; every
    /// send-time gate (route match, allowlists, rate policy, kill switch)
    /// still re-runs against current state.
    func sendDraftIntent(id: String) async -> AgentChannelPublishOutcome {
        await operatorSend(
            id: id,
            expectedStatus: .draft,
            requiredModes: [.draft, .confirm, .autonomous],
            keepStatusOnRetryableDenial: true
        )
    }

    /// Operator explicitly retrying an unknown delivery. This may duplicate
    /// a message that DID reach the provider — the outbox says so before
    /// offering the action — which is exactly why it requires a human and
    /// is never done automatically.
    func retryUnknownDeliveryIntent(id: String) async -> AgentChannelPublishOutcome {
        await operatorSend(
            id: id,
            expectedStatus: .deliveryUnknown,
            requiredModes: [.draft, .confirm, .autonomous],
            keepStatusOnRetryableDenial: true
        )
    }

    /// Operator resolution of an unknown delivery without provider I/O:
    /// `markSent: true` records the message as delivered (it counts toward
    /// the binding's rate policy from now on), `false` discards it.
    func resolveUnknownDeliveryIntent(id: String, markSent: Bool) -> Bool {
        guard (try? store.openIfNeeded()) != nil else { return false }
        reconcileAndPruneIfNeeded()
        guard let intent = try? store.outboundIntent(id: id) else { return false }
        let resolved = (try? store.transitionOutboundIntent(
            id: id,
            from: .deliveryUnknown,
            to: markSent ? .sent : .cancelled,
            updatedAt: now()
        )) == true
        if resolved {
            auditIntent(
                status: markSent ? .accepted : .denied,
                reason: markSent ? "operator_marked_sent" : "operator_discarded_unknown_delivery",
                intent: intent
            )
            notifyOutboxChanged()
        }
        return resolved
    }

    /// Operator discard of a draft or pending intent.
    func discardIntent(id: String) -> Bool {
        guard (try? store.openIfNeeded()) != nil else { return false }
        reconcileAndPruneIfNeeded()
        let intent = try? store.outboundIntent(id: id)
        for status in [AgentChannelOutboundIntentStatus.pending, .draft] {
            if (try? store.transitionOutboundIntent(
                id: id,
                from: status,
                to: .cancelled,
                updatedAt: now()
            )) == true {
                if let intent {
                    auditIntent(status: .denied, reason: "operator_discarded", intent: intent)
                }
                notifyOutboxChanged()
                return true
            }
        }
        return false
    }

    /// Startup reconciliation + retention pruning, callable from the outbox
    /// UI so interrupted sends surface without waiting for the next publish.
    func reconcileInterruptedWork() {
        guard (try? store.openIfNeeded()) != nil else { return }
        reconcileAndPruneIfNeeded()
    }

    /// Shared operator send pipeline (approve pending / send draft / retry
    /// unknown delivery): re-resolve the binding, verify ownership, mode,
    /// stored-route match, and run-source permission, then run the full
    /// send-time policy gate and provider write under the binding lock.
    private func operatorSend(
        id: String,
        expectedStatus: AgentChannelOutboundIntentStatus,
        requiredModes: Set<AgentChannelBindingOutboundMode>,
        keepStatusOnRetryableDenial: Bool
    ) async -> AgentChannelPublishOutcome {
        do {
            try store.openIfNeeded()
        } catch {
            return .denied(
                code: "ledger_unavailable",
                message: "Outbound ledger is unavailable: \(error.localizedDescription)",
                retryable: true
            )
        }
        reconcileAndPruneIfNeeded()
        guard let intent = try? store.outboundIntent(id: id) else {
            return .denied(
                code: "intent_not_found",
                message: "Outbound intent `\(id)` was not found.",
                retryable: false
            )
        }
        guard intent.status == expectedStatus else {
            return .denied(
                code: "intent_not_actionable",
                message:
                    "Outbound intent `\(id)` is `\(intent.status.rawValue)`, "
                    + "not \(expectedStatus.rawValue).",
                retryable: false
            )
        }

        let configuration = loadConfiguration()
        guard let binding = configuration.binding(id: intent.bindingId),
            binding.agentId == intent.agentId
        else {
            markFailed(intentId: id, from: expectedStatus, code: "binding_removed")
            auditIntent(status: .denied, reason: "binding_removed", intent: intent)
            return .denied(
                code: "binding_removed",
                message: "The destination binding for this intent no longer exists.",
                retryable: false
            )
        }
        guard binding.enabled, requiredModes.contains(binding.outboundMode) else {
            markFailed(intentId: id, from: expectedStatus, code: "binding_policy_changed")
            auditIntent(status: .denied, reason: "binding_policy_changed", intent: intent, binding: binding)
            return .denied(
                code: "binding_policy_changed",
                message: "The destination binding's outbound policy changed; the item was not sent.",
                retryable: false
            )
        }
        // Stale-route gate: the outbox showed the operator the intent's
        // STORED destination. If the binding was repointed since, this
        // approval must not silently follow it.
        guard routeMatches(binding: binding, intent: intent) else {
            markFailed(intentId: id, from: expectedStatus, code: "binding_route_changed")
            auditIntent(status: .denied, reason: "binding_route_changed", intent: intent, binding: binding)
            return .denied(
                code: "binding_route_changed",
                message:
                    "The destination binding's route changed since this item was recorded; "
                    + "it was not sent. Ask the agent to publish again.",
                retryable: false
            )
        }
        // Source re-check: if the operator narrowed the allowed run sources
        // after this intent was queued, honor the narrowed policy.
        guard let rawSource = intent.runSource,
            let storedSource = AgentChannelBindingRunSource(rawValue: rawSource),
            binding.allows(source: storedSource)
        else {
            markFailed(intentId: id, from: expectedStatus, code: "run_source_not_allowed")
            auditIntent(status: .denied, reason: "run_source_not_allowed", intent: intent, binding: binding)
            return .denied(
                code: "run_source_not_allowed",
                message:
                    "The destination binding no longer allows the run source that queued "
                    + "this item; it was not sent.",
                retryable: false
            )
        }

        let route = sendRoute(binding: binding, intent: intent)
        return await withBindingLock(binding.id) {
            if let denial = self.sendPolicyDenial(binding: route) {
                if !denial.retryable || !keepStatusOnRetryableDenial {
                    self.markFailed(intentId: id, from: expectedStatus, code: denial.code)
                }
                self.auditIntent(status: .denied, reason: denial.code, intent: intent, binding: binding)
                return .denied(code: denial.code, message: denial.message, retryable: denial.retryable)
            }
            guard (try? self.store.transitionOutboundIntent(
                id: id,
                from: expectedStatus,
                to: .sending,
                updatedAt: self.now()
            )) == true else {
                return .denied(
                    code: "intent_in_flight",
                    message: "This intent is already being processed.",
                    retryable: true
                )
            }
            self.notifyOutboxChanged()
            return await self.performSend(
                intentId: id,
                binding: route,
                content: intent.content,
                request: AgentChannelPublishRequest(
                    bindingId: binding.id,
                    content: intent.content,
                    intentKey: intent.intentKey,
                    threadId: intent.threadId
                ),
                context: AgentChannelPublishContext(
                    agentId: intent.agentId,
                    source: nil,
                    isExternalSurface: false,
                    isUnattendedDispatch: false,
                    sessionId: intent.sessionId
                )
            )
        }
    }

    // MARK: - Send pipeline

    private struct SendPolicyDenial {
        let code: String
        let message: String
        let retryable: Bool
    }

    /// The exact route a send must use: the current binding's policy with
    /// the intent's STORED thread (a model-supplied thread is part of the
    /// recorded intent, not of the binding). Room/connection equality with
    /// the stored intent is verified by `routeMatches` before this is used.
    private func sendRoute(
        binding: AgentChannelBinding,
        intent: AgentChannelOutboundIntent
    ) -> AgentChannelBinding {
        var route = binding
        route.threadId = intent.threadId
        return route
    }

    /// Whether the intent's stored destination still matches the current
    /// binding. A binding-pinned thread must match the stored thread; a
    /// binding without a pinned thread accepts whatever thread the intent
    /// recorded (including none).
    private func routeMatches(
        binding: AgentChannelBinding,
        intent: AgentChannelOutboundIntent
    ) -> Bool {
        guard binding.connectionId == intent.connectionId,
            binding.roomId == intent.roomId
        else { return false }
        if let pinnedThread = binding.threadId {
            return intent.threadId == pinnedThread
        }
        return true
    }

    /// Everything that must hold at the moment of a provider write:
    /// kill switch, connection enablement, write capability, room
    /// allowlist, and the binding's rate policy.
    private func sendPolicyDenial(binding: AgentChannelBinding) -> SendPolicyDenial? {
        let killSwitch = killSwitchSnapshot()
        guard killSwitch.writeEnabled else {
            return SendPolicyDenial(
                code: "global_writes_disabled",
                message:
                    "Global Agent Channel writes are disabled by the write kill switch "
                    + "(generation \(killSwitch.generation)).",
                retryable: false
            )
        }
        let connection: AgentChannelConnection
        do {
            connection = try resolveConnection(binding.connectionId)
        } catch {
            return SendPolicyDenial(
                code: "connection_unavailable",
                message: error.localizedDescription,
                retryable: false
            )
        }
        guard connection.enabled else {
            return SendPolicyDenial(
                code: "connection_disabled",
                message: "Connection `\(connection.id)` is disabled.",
                retryable: false
            )
        }
        guard connection.writeEnabled else {
            return SendPolicyDenial(
                code: "connection_writes_disabled",
                message: "Write access is disabled for connection `\(connection.id)`.",
                retryable: false
            )
        }
        if let threadId = binding.threadId, !threadId.isEmpty {
            guard connection.supportedActions.contains(.replyThread) else {
                return SendPolicyDenial(
                    code: "thread_publish_unsupported",
                    message: "Connection `\(connection.id)` does not support thread replies.",
                    retryable: false
                )
            }
            // Thread writability is enforced by the provider service at
            // send time (thread ids are provider-scoped); the room-level
            // allowlist below does not apply to the thread route.
        } else {
            guard connection.supportedActions.contains(.sendMessage) else {
                return SendPolicyDenial(
                    code: "send_unsupported",
                    message: "Connection `\(connection.id)` does not support sending messages.",
                    retryable: false
                )
            }
            guard connection.writeRoomAllowlist.contains(binding.roomId) else {
                return SendPolicyDenial(
                    code: "room_not_write_allowlisted",
                    message:
                        "Room `\(binding.roomId)` is not on the write allowlist for "
                        + "connection `\(connection.id)`.",
                    retryable: false
                )
            }
        }

        // Rate policy against the durable ledger. This runs INSIDE the
        // per-binding lock, so a concurrent send for the same binding
        // cannot pass the same headroom twice.
        do {
            try store.openIfNeeded()
            let hourAgo = now().addingTimeInterval(-3_600)
            let sentLastHour = try store.sentOutboundIntentCount(
                bindingId: binding.id,
                since: hourAgo
            )
            guard sentLastHour < binding.ratePolicy.maxSendsPerHour else {
                return SendPolicyDenial(
                    code: "rate_limited",
                    message:
                        "Binding `\(binding.id)` reached its hourly send limit "
                        + "(\(binding.ratePolicy.maxSendsPerHour)/hour).",
                    retryable: true
                )
            }
            if binding.ratePolicy.minSecondsBetweenSends > 0,
                let lastSent = try store.lastSentOutboundIntentAt(bindingId: binding.id) {
                let elapsed = now().timeIntervalSince(lastSent)
                guard elapsed >= Double(binding.ratePolicy.minSecondsBetweenSends) else {
                    return SendPolicyDenial(
                        code: "rate_limited",
                        message:
                            "Binding `\(binding.id)` requires "
                            + "\(binding.ratePolicy.minSecondsBetweenSends)s between sends.",
                        retryable: true
                    )
                }
            }
        } catch {
            return SendPolicyDenial(
                code: "ledger_unavailable",
                message: "Outbound ledger is unavailable: \(error.localizedDescription)",
                retryable: true
            )
        }
        return nil
    }

    /// Send-time policy gate + provider write for an intent this caller has
    /// already claimed into `.sending`. Runs AFTER the durable claim so a
    /// replayed intent key reports `duplicate` instead of leaking the current
    /// rate/kill-switch state, and INSIDE the per-binding lock so rate
    /// headroom cannot be double-spent across an `await`. On denial the
    /// claim is released to `.failed` with the denial code, so a retryable
    /// denial (e.g. `rate_limited`) can be retried later under the same
    /// intent key via the failed-retry CAS.
    private func authorizeAndPerformSend(
        intentId: String,
        binding: AgentChannelBinding,
        content: String,
        request: AgentChannelPublishRequest,
        context: AgentChannelPublishContext
    ) async -> AgentChannelPublishOutcome {
        await withBindingLock(binding.id) {
            if let denial = self.sendPolicyDenial(binding: binding) {
                self.markFailed(intentId: intentId, from: .sending, code: denial.code)
                return self.deniedAndAudited(
                    code: denial.code,
                    message: denial.message,
                    retryable: denial.retryable,
                    request: request,
                    context: context,
                    binding: binding
                )
            }
            return await self.performSend(
                intentId: intentId,
                binding: binding,
                content: content,
                request: request,
                context: context
            )
        }
    }

    private func performSend(
        intentId: String,
        binding: AgentChannelBinding,
        content: String,
        request: AgentChannelPublishRequest,
        context: AgentChannelPublishContext
    ) async -> AgentChannelPublishOutcome {
        do {
            let providerMessageId = try await sender(binding, content)
            let recorded = (try? store.transitionOutboundIntent(
                id: intentId,
                from: .sending,
                to: .sent,
                providerMessageId: providerMessageId,
                updatedAt: now()
            )) == true
            audit(
                status: .accepted,
                reason: recorded ? "proactive_send_completed" : "proactive_send_completed_unrecorded",
                request: request,
                context: context,
                binding: binding,
                content: content,
                providerMessageId: providerMessageId
            )
            notifyOutboxChanged()
            return .sent(intentId: intentId, providerMessageId: providerMessageId)
        } catch {
            switch Self.classifyProviderFailure(error) {
            case .deterministic:
                _ = try? store.transitionOutboundIntent(
                    id: intentId,
                    from: .sending,
                    to: .failed,
                    failureCode: "provider_error",
                    failureMessage: error.localizedDescription,
                    updatedAt: now()
                )
                audit(
                    status: .failed,
                    reason: "provider_error",
                    request: request,
                    context: context,
                    binding: binding,
                    content: content,
                    failureMessage: error.localizedDescription
                )
                notifyOutboxChanged()
                // The provider REJECTED the request before accepting the
                // message (auth, permissions, rate limit, unreachable host),
                // so a retry cannot duplicate: the intent is durably
                // `failed` and a retry re-claims it via CAS.
                return .denied(
                    code: "provider_error",
                    message: error.localizedDescription,
                    retryable: true
                )
            case .ambiguous:
                // The message MAY have reached the provider (timeout after
                // dispatch, undecodable success response, 5xx). None of the
                // native providers dedupe on a client key, so an automatic
                // retry could post a duplicate a human already saw. Park the
                // intent as delivery-unknown and require explicit operator
                // resolution.
                _ = try? store.transitionOutboundIntent(
                    id: intentId,
                    from: .sending,
                    to: .deliveryUnknown,
                    failureCode: "delivery_unknown",
                    failureMessage: error.localizedDescription,
                    updatedAt: now()
                )
                audit(
                    status: .failed,
                    reason: "delivery_unknown",
                    request: request,
                    context: context,
                    binding: binding,
                    content: content,
                    failureMessage: error.localizedDescription
                )
                notifyOutboxChanged()
                return .denied(
                    code: "delivery_unknown",
                    message:
                        "The provider did not confirm delivery; the message may or may not "
                        + "have been posted. Do NOT resend — the item awaits operator "
                        + "resolution in the channel outbox.",
                    retryable: false
                )
            }
        }
    }

    private func markFailed(
        intentId: String,
        from expected: AgentChannelOutboundIntentStatus,
        code: String
    ) {
        _ = try? store.transitionOutboundIntent(
            id: intentId,
            from: expected,
            to: .failed,
            failureCode: code,
            updatedAt: now()
        )
        notifyOutboxChanged()
    }

    // MARK: - Failure classification

    enum ProviderFailureKind: Sendable, Equatable {
        /// The provider (or a local gate) rejected the request before
        /// accepting the message; retrying cannot duplicate.
        case deterministic
        /// The message may have been accepted; retrying may duplicate.
        case ambiguous
    }

    /// Classify a thrown provider error by whether the send could have
    /// reached the provider. Anything unrecognized is AMBIGUOUS: when in
    /// doubt, require a human instead of risking a duplicate post.
    static func classifyProviderFailure(_ error: Error) -> ProviderFailureKind {
        // Local gates and provider-side validation errors thrown before any
        // write was accepted.
        if error is AgentChannelConnectionServiceError { return .deterministic }
        if let runnerError = error as? AgentChannelCustomJSONRunnerError {
            // The custom JSON runner tracks dispatch itself: a non-nil
            // partial-write status means the request may have gone out.
            return runnerError.partialWriteStatus == nil ? .deterministic : .ambiguous
        }
        if let discordError = error as? DiscordConnectionServiceError {
            if case .api = discordError { return .ambiguous }
            return .deterministic
        }
        if let slackError = error as? SlackConnectionServiceError {
            if case .api = slackError { return .ambiguous }
            return .deterministic
        }
        if let telegramError = error as? TelegramConnectionServiceError {
            if case .api = telegramError { return .ambiguous }
            return .deterministic
        }
        // Provider API clients: typed rejections are deterministic (the
        // provider answered and said no); transport wrappers and
        // undecodable responses are ambiguous (`requestFailed` covers both
        // 5xx and transport errors, `invalidResponse` fires AFTER a 2xx).
        if let discordAPI = error as? DiscordAPIError {
            switch discordAPI {
            case .invalidToken, .missingPermissions, .notFound, .rateLimited:
                return .deterministic
            case .invalidResponse, .requestFailed:
                return .ambiguous
            }
        }
        if let slackAPI = error as? SlackAPIError {
            switch slackAPI {
            case .invalidToken, .missingPermissions, .notFound, .rateLimited:
                return .deterministic
            case .invalidResponse, .requestFailed:
                return .ambiguous
            }
        }
        if let telegramAPI = error as? TelegramAPIError {
            switch telegramAPI {
            case .invalidToken, .forbidden, .conflict, .notFound, .rateLimited:
                return .deterministic
            case .invalidResponse, .requestFailed:
                return .ambiguous
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                .dataNotAllowed, .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                // The connection never carried the request body.
                return .deterministic
            default:
                return .ambiguous
            }
        }
        return .ambiguous
    }

    // MARK: - Per-binding critical section

    /// FIFO async lock keyed by binding id. Serializes policy check +
    /// provider write per binding across actor-reentrancy suspension points
    /// without serializing unrelated bindings.
    private func withBindingLock<T: Sendable>(
        _ bindingId: String,
        _ body: () async -> T
    ) async -> T {
        while lockedBindingIds.contains(bindingId) {
            await withCheckedContinuation { continuation in
                bindingLockWaiters[bindingId, default: []].append(continuation)
            }
        }
        lockedBindingIds.insert(bindingId)
        defer {
            lockedBindingIds.remove(bindingId)
            if var waiters = bindingLockWaiters[bindingId], !waiters.isEmpty {
                let next = waiters.removeFirst()
                bindingLockWaiters[bindingId] = waiters.isEmpty ? nil : waiters
                next.resume()
            } else {
                bindingLockWaiters[bindingId] = nil
            }
        }
        return await body()
    }

    // MARK: - Recovery + retention

    /// One-shot per service instance: `sending` rows older than this
    /// instance's start were claimed by a run that never finished (crash,
    /// force quit). Their provider write is unconfirmed, so they become
    /// `delivery_unknown` — visible in the outbox, never auto-retried.
    /// Terminal history past the retention window is pruned at the same
    /// time. Synchronous (no awaits), so within this actor no send can be
    /// in flight while it runs.
    private func reconcileAndPruneIfNeeded() {
        guard !didRunStartupReconciliation else { return }
        didRunStartupReconciliation = true
        let interrupted = (try? store.reconcileInterruptedOutboundIntents(
            before: startedAt,
            updatedAt: now()
        )) ?? 0
        let pruned = (try? store.pruneTerminalOutboundIntents(
            olderThan: now().addingTimeInterval(-Self.terminalRetention)
        )) ?? 0
        if interrupted > 0 {
            _ = try? store.recordAuditEvent(
                AgentChannelAuditRecord(
                    connectionId: "outbound_ledger",
                    roomId: nil,
                    providerMessageId: nil,
                    direction: .outbound,
                    action: Self.auditAction,
                    status: .failed,
                    reason: "interrupted_sends_reconciled",
                    failureMessage: nil,
                    redactedSummary: "\(interrupted) interrupted send(s) moved to delivery_unknown",
                    metadataJSON: "{\"count\": \(interrupted)}",
                    createdAt: now()
                )
            )
        }
        if interrupted > 0 || pruned > 0 {
            notifyOutboxChanged()
        }
    }

    private func notifyOutboxChanged() {
        NotificationCenter.default.post(
            name: .agentChannelOutboundIntentsChanged,
            object: nil
        )
    }

    // MARK: - Audit

    private func deniedAndAudited(
        code: String,
        message: String,
        retryable: Bool = false,
        request: AgentChannelPublishRequest,
        context: AgentChannelPublishContext,
        binding: AgentChannelBinding?
    ) -> AgentChannelPublishOutcome {
        audit(
            status: .denied,
            reason: code,
            request: request,
            context: context,
            binding: binding,
            content: request.content
        )
        return .denied(code: code, message: message, retryable: retryable)
    }

    private func audit(
        status: AgentChannelAuditStatus,
        reason: String,
        request: AgentChannelPublishRequest,
        context: AgentChannelPublishContext,
        binding: AgentChannelBinding?,
        content: String,
        providerMessageId: String? = nil,
        failureMessage: String? = nil
    ) {
        guard (try? store.openIfNeeded()) != nil else { return }
        var metadata: [String: String] = [
            "binding_id": binding?.id ?? request.bindingId,
            "intent_key": String(request.intentKey.prefix(Self.maxIntentKeyLength)),
        ]
        if let binding {
            metadata["outbound_mode"] = binding.outboundMode.rawValue
        }
        if let source = context.source {
            metadata["run_source"] = source.rawValue
        }
        recordAudit(
            status: status,
            reason: reason,
            connectionId: binding?.connectionId ?? "unresolved",
            roomId: binding?.roomId,
            providerMessageId: providerMessageId,
            failureMessage: failureMessage,
            content: content,
            metadata: metadata
        )
    }

    /// Audit entry for operator outbox actions and stale-intent denials,
    /// keyed off the stored intent (there is no live request/context).
    private func auditIntent(
        status: AgentChannelAuditStatus,
        reason: String,
        intent: AgentChannelOutboundIntent,
        binding: AgentChannelBinding? = nil
    ) {
        guard (try? store.openIfNeeded()) != nil else { return }
        var metadata: [String: String] = [
            "binding_id": intent.bindingId,
            "intent_id": intent.id,
            "intent_key": String(intent.intentKey.prefix(Self.maxIntentKeyLength)),
            "operator_action": "true",
        ]
        if let binding {
            metadata["outbound_mode"] = binding.outboundMode.rawValue
        }
        if let runSource = intent.runSource {
            metadata["run_source"] = runSource
        }
        recordAudit(
            status: status,
            reason: reason,
            connectionId: intent.connectionId,
            roomId: intent.roomId,
            providerMessageId: intent.providerMessageId,
            failureMessage: nil,
            content: intent.content,
            metadata: metadata
        )
    }

    private func recordAudit(
        status: AgentChannelAuditStatus,
        reason: String,
        connectionId: String,
        roomId: String?,
        providerMessageId: String?,
        failureMessage: String?,
        content: String,
        metadata: [String: String]
    ) {
        let metadataJSON: String
        if JSONSerialization.isValidJSONObject(metadata),
            let data = try? JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            ),
            let string = String(data: data, encoding: .utf8)
        {
            metadataJSON = string
        } else {
            metadataJSON = "{}"
        }
        _ = try? store.recordAuditEvent(
            AgentChannelAuditRecord(
                connectionId: connectionId,
                roomId: roomId,
                providerMessageId: providerMessageId,
                direction: .outbound,
                action: Self.auditAction,
                status: status,
                reason: reason,
                failureMessage: failureMessage,
                redactedSummary: AgentChannelAuditRedactor.redactedPreview(content),
                metadataJSON: metadataJSON,
                createdAt: now()
            )
        )
    }

    // MARK: - Default provider sender

    /// Production sender: routes through the standard connection service so
    /// provider `confirmSend`, write allowlists, and the global kill switch
    /// are enforced a second time at the provider boundary. Custom HTTP
    /// connections additionally get provider-side idempotency when their
    /// action config declares it (the runner derives a deterministic key
    /// from connection + action + target + content hash, so a retried
    /// intent maps to the same provider key). Discord/Slack/Telegram have
    /// no server-side idempotency for bot sends — which is exactly why
    /// ambiguous failures park as `delivery_unknown` instead of retrying.
    static let defaultSender: Sender = { binding, content in
        let payload: [String: Any]
        if let threadId = binding.threadId, !threadId.isEmpty {
            payload = try await AgentChannelConnectionService.shared.replyThread(
                connectionId: binding.connectionId,
                threadId: threadId,
                content: content,
                confirmSend: true
            )
        } else {
            payload = try await AgentChannelConnectionService.shared.sendMessage(
                connectionId: binding.connectionId,
                roomId: binding.roomId,
                content: content,
                confirmSend: true
            )
        }
        return extractProviderMessageId(payload)
    }

    /// Best-effort provider message id extraction from the heterogeneous
    /// provider payload shapes (Discord nests `message.id`, Slack uses
    /// `ts`, Telegram uses `message_id`, iMessage uses a top-level `guid`).
    static func extractProviderMessageId(_ payload: [String: Any]) -> String? {
        func stringValue(_ value: Any?) -> String? {
            if let string = value as? String, !string.isEmpty { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        if let direct = stringValue(payload["message_id"]) { return direct }
        if let guid = stringValue(payload["guid"]) { return guid }
        if let message = payload["message"] as? [String: Any] {
            if let id = stringValue(message["id"]) { return id }
            if let ts = stringValue(message["ts"]) { return ts }
            if let id = stringValue(message["message_id"]) { return id }
            // iMessage nests the helper's send result, which identifies the
            // sent message by its Messages GUID.
            if let guid = stringValue(message["guid"]) { return guid }
        }
        if let ts = stringValue(payload["ts"]) { return ts }
        return nil
    }
}
