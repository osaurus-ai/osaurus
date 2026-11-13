//
//  ToolPermissionPromptService.swift
//  osaurus
//
//  Presents a modern confirmation dialog when a tool requires user approval.
//
//  One coordinator, one panel at a time. Every approval request becomes a
//  queued entry with its own identity and continuation; exactly one entry is
//  presented, and resolving it (button, keyboard, close, cancellation) tears
//  down exactly its own panel and presents the next entry. Concurrent callers
//  — parallel tool calls whose bodies prompt (`spawn_agent`, image/video
//  billing, the config fallback) or a delegated child prompting while the
//  parent does — therefore never overwrite each other's window.
//
//  History: the previous implementation kept a single static window slot. Two
//  concurrent `spawn_agent` prompts overwrote it; the first panel stayed on
//  screen with dead button handlers after the second resolved, and its Stop
//  cancellation hook was lost, so its continuation could never be resumed.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
enum ToolPermissionPromptService {
    // MARK: - Public outcome vocabularies (unchanged for callers)

    enum PolicyApprovalOutcome: Sendable, Equatable {
        case denied
        case allowOnce
        case alwaysAllow
    }

    enum ApprovalOutcome: Sendable, Equatable {
        case denied
        case allowOnce
        case allowForRun
        case alwaysAllow
    }

    /// Internal resolution shared by every entry point. Public entry points
    /// map it onto their own narrower vocabulary.
    enum PromptResolution: Sendable, Equatable {
        case denied
        case allowOnce
        case allowForRun
        case alwaysAllow
    }

    /// Re-evaluated immediately before an entry is presented. A non-nil value
    /// resolves the entry without showing a panel — e.g. a sibling spawn
    /// prompt already persisted "Always Allow" while this one was queued.
    typealias Revalidation = @Sendable () async -> PromptResolution?

    // MARK: - Queue state

    struct PromptRequest {
        let toolName: String
        let description: String
        let argumentsJSON: String
        let knowledgeWritePreview: KnowledgeWritePreview?
        let perCallApprovalOnly: Bool
        /// Whether the caller has a task lease to grant "Allow for This Task"
        /// into. Policy callers without that owner leave this false.
        let offersRunLease: Bool
        /// Where the approved call will run (VM / this Mac / remote MCP
        /// server), shown on the card so consent is informed
        /// (osaurus#2651). Nil for prompts that are not about executing a
        /// tool on a machine (billing, spawn policy), which show no badge.
        let executionSurface: ToolExecutionSurface?
        /// Whose run raised the card, and so where it's answered.
        let requester: Requester
        /// `description` was written for the model (the tool schema text),
        /// so the sheet does not show it as prose.
        var descriptionIsForModel: Bool = false
        /// The workflow step's purpose when a step raised the card.
        var stepReason: String? = nil
        /// Sandbox bounds for a VM call, read when the request was made.
        var sandboxFacts: ToolApprovalPresentation.SandboxFacts? = nil
        /// The folders a workflow run's file tools are held to, read when the
        /// request was made.
        var workflowFacts: ToolApprovalPresentation.WorkflowFacts? = nil
        /// A caller-owned approval must publish its new authority before the
        /// next queued request revalidates. Nil preserves generic callers.
        var commitApproval: (@MainActor @Sendable (ApprovalOutcome) -> Void)? = nil

        /// Only paired-phone cards reach the phone's `GET /approvals`, as in
        /// the computer-use and config queues: a card from a Mac chat is
        /// answered on the Mac.
        var fromPairedPhone: Bool { requester == .pairedPhone }

        var presentation: ToolApprovalPresentation {
            ToolApprovalPresentation.make(
                toolName: toolName,
                description: description,
                descriptionIsForModel: descriptionIsForModel,
                argumentsJSON: argumentsJSON,
                surface: executionSurface,
                stepReason: stepReason,
                sandbox: sandboxFacts,
                workflow: workflowFacts
            )
        }
    }

    /// The folders the calling workflow run's file tools may use, from the
    /// scopes bound for its step. Nil outside a workflow run.
    static func workflowFacts() -> ToolApprovalPresentation.WorkflowFacts? {
        guard ChatExecutionContext.currentWorkflowRunId != nil else { return nil }
        let hooks = ChatExecutionContext.workflowHostFiles
        return .make(
            granted: ChatExecutionContext.workflowGrantedPaths ?? [],
            writable: ChatExecutionContext.workflowWritableRoots, workspace: hooks?.workspace,
            folderRoot: ChatExecutionContext.currentFolderRoot, asksBeforeReplacing: hooks != nil,
            sandboxPathsRouteToVM: ChatExecutionContext.sandboxReadBridge != nil
                && !ChatExecutionContext.hostFolderIsDispatchTarget)
    }

    /// The bounds the sandbox enforces on a VM call: the VM size from the
    /// Sandbox settings, and the calling agent's own network policy. A
    /// workflow environment or an unattributed call reports its network as
    /// unknown rather than guessing.
    static func sandboxFacts(for surface: ToolExecutionSurface?) -> ToolApprovalPresentation.SandboxFacts? {
        guard surface == .sandboxVM else { return nil }
        let config = SandboxConfigurationStore.load()
        var network = ToolApprovalPresentation.SandboxFacts.Network.unknown
        if ChatExecutionContext.workflowSandbox == nil, let agentId = ChatExecutionContext.currentAgentId {
            switch SandboxManager.egressMode(forAgentId: agentId) {
            case .open: network = .open
            case .allowlist: network = .limited
            case .none: network = .none
            }
        }
        return ToolApprovalPresentation.SandboxFacts(cpus: config.cpus, memoryGB: config.memoryGB, network: network)
    }

    enum Requester: Equatable, Sendable {
        /// A run started here; the card shows on this Mac.
        case thisMac
        /// A run of the user's paired phone, which also answers it.
        case pairedPhone
        /// A run this Mac hosts for another of the user's devices. No panel
        /// shows here: the card goes to the run's sync conversation.
        case syncedDevice(scope: String)

        static var current: Requester {
            if let scope = ChatExecutionContext.syncReviewerScope { return .syncedDevice(scope: scope) }
            return ChatExecutionContext.hasRemoteReviewer ? .pairedPhone : .thisMac
        }
    }

    private struct PendingPrompt {
        let id: UUID
        let request: PromptRequest
        let revalidate: Revalidation?
        /// Captured from the requesting task so a test presenter follows its
        /// own requests through the queue regardless of which task pumps.
        let presenter: TestPresenter?
    }

    /// AppKit handles owned by the presented entry. Nil under the test
    /// presenter override, which never constructs a window.
    private struct PanelHandles {
        let panel: NSPanel
        let closeObserver: NSObjectProtocol
        let keyMonitor: Any?
    }

    private enum PresenterSlot {
        /// The head entry is running its `revalidate` hook. The slot is held
        /// so no other entry can present in the meantime.
        case revalidating(UUID)
        case presented(UUID, PanelHandles?)

        var id: UUID {
            switch self {
            case .revalidating(let id), .presented(let id, _): return id
            }
        }
    }

    private static var queue: [PendingPrompt] = []
    private static var continuations: [UUID: CheckedContinuation<PromptResolution, Never>] = [:]
    private static var slot: PresenterSlot?
    /// The request behind the presented `slot`, kept for test introspection.
    private static var presentedRequest: PromptRequest?
    /// Card size reported by `onGeometryChange` during the sizing layout
    /// pass, applied once the panel is registered.
    private static var lastRenderedCardSize: CGSize?

    /// Tool permission prompts showing or waiting their turn.
    static var openPromptCount: Int { queue.count + (slot == nil ? 0 : 1) }

    // MARK: - Headless / test seams

    /// A test process has nobody to press the button.
    ///
    /// Every approval entry point blocks on a `withCheckedContinuation` that
    /// is only ever resumed by a panel button, so a test that reaches one
    /// hangs — and because the bundle runs in a single process, every test
    /// behind it hangs too. Observed 2026-08-22: the whole OsaurusCore suite
    /// sat for 40+ minutes with a 0-byte log while a live
    /// `swiftpm-testing-helper` held a 460x478 "Tool Permission" panel on
    /// screen. Denying is the deterministic answer and matches the registry's
    /// "external-surface / headless denials" semantics.
    ///
    /// Tests that exercise the queue itself bind `presentationOverrideForTests`
    /// around their requests, which replaces the AppKit panel with a callback
    /// and lifts this guard for exactly those requests.
    private static var isHeadlessTestProcess: Bool {
        RuntimeEnvironment.isUnderTests && presentationOverrideForTests == nil
    }

    /// Replaces panel construction. Receives the presented entry's id, tool
    /// name, and how many entries are queued behind it; the test resolves the
    /// entry with `resolveForTesting`. Task-local so concurrently running
    /// suites that do not bind it keep the headless denial.
    typealias TestPresenter = @Sendable (_ id: UUID, _ toolName: String, _ queuedBehind: Int) -> Void

    @TaskLocal
    static var presentationOverrideForTests: TestPresenter?

    static func resolveForTesting(id: UUID, outcome: PromptResolution) {
        resolve(id: id, outcome: outcome)
    }

    /// Whether a real AppKit permission panel is currently presented. Exists
    /// so a test can assert that no window outlives an approval call — the
    /// window left behind is the thing that could neither be clicked nor
    /// quit. Test stand-ins (presenter override) are not windows; see
    /// `presentedPromptIDForTesting`.
    static var hasOpenPermissionWindowForTesting: Bool {
        if case .presented(_, let handles?) = slot { return handles.panel.isVisible }
        return false
    }

    static var presentedPromptIDForTesting: UUID? { slot?.id }
    static var queuedPromptCountForTesting: Int { queue.count }
    /// The surface the presented card is showing, so a test can prove the
    /// gate's routing answer reached the prompt.
    static var presentedExecutionSurfaceForTesting: ToolExecutionSurface? {
        presentedRequest?.executionSurface
    }
    /// What the presented sheet says.
    static var presentedPresentationForTesting: ToolApprovalPresentation? {
        presentedRequest?.presentation
    }

    /// Deny everything outstanding.
    static func resetForTesting() {
        let outstanding = queue.map(\.id) + Array(continuations.keys)
        for id in Set(outstanding) { resolve(id: id, outcome: .denied, attention: AttentionProducers.abandoned) }
        if let slot { tearDown(slot) }
        slot = nil
        presentedRequest = nil
        queue.removeAll()
    }

    // MARK: - Remote approvals (Osaurus Connect)

    /// One card as a paired phone sees it (docs/MOBILE_PROTOCOL.md §16).
    struct RemotePrompt: Sendable, Equatable {
        let id: UUID
        let toolName: String
        let description: String
        let argumentsJSON: String
        /// Whether "Allow for This Task" is on offer.
        let offersRunLease: Bool
        /// Where the approved call would run, so consent is informed.
        let surface: String?
        /// True for the card on screen; the rest are queued behind it.
        let isPresented: Bool
    }

    /// Everything outstanding from the paired phone's runs, presented card
    /// first. The phone shows these and answers them with `resolveRemotely`.
    static var remotePrompts: [RemotePrompt] {
        var result: [RemotePrompt] = []
        if let slot, let request = presentedRequest, request.fromPairedPhone {
            result.append(remotePrompt(id: slot.id, request: request, isPresented: true))
        }
        for entry in queue where entry.id != slot?.id && entry.request.fromPairedPhone {
            result.append(remotePrompt(id: entry.id, request: entry.request, isPresented: false))
        }
        return result
    }

    /// The outstanding card `id`, presented or queued.
    private static func pendingRequest(id: UUID) -> PromptRequest? {
        if let slot, slot.id == id { return presentedRequest }
        return queue.first { $0.id == id }?.request
    }

    private static func remotePrompt(id: UUID, request: PromptRequest, isPresented: Bool) -> RemotePrompt {
        RemotePrompt(
            id: id,
            toolName: request.toolName,
            description: request.description,
            argumentsJSON: request.argumentsJSON,
            offersRunLease: request.offersRunLease && !request.perCallApprovalOnly,
            surface: request.executionSurface?.rawValue,
            isPresented: isPresented
        )
    }

    /// Answers a card from a paired phone, exactly as the panel's buttons do:
    /// the waiting run resumes and any open panel is torn down. False when
    /// the id is unknown — already answered on the Mac, or the run ended —
    /// or the card is not from one of the phone's runs.
    @discardableResult
    static func resolveRemotely(id: UUID, outcome: PromptResolution) -> Bool {
        guard continuations[id] != nil, pendingRequest(id: id)?.fromPairedPhone == true else { return false }
        resolve(
            id: id,
            outcome: outcome,
            attention: AttentionResolution(
                outcome: attentionOutcome(for: outcome),
                surface: .phone,
                decidedBy: .ownerDevice(L("iPhone"))
            )
        )
        return true
    }

    // MARK: - Synced-device approvals

    /// Posted when the cards held for a sync conversation change;
    /// `userInfo["scope"]` is the conversation.
    static let syncedPromptsDidChangeNotification = Notification.Name("ToolPermissionPromptService.syncedPrompts")

    /// A card held for the device the user is chatting on.
    struct SyncedPrompt: Sendable, Equatable {
        let id: UUID
        let toolName: String
        let description: String
        let argumentsJSON: String
        let offersRunLease: Bool
        let surface: String?
        let requestedAt: Date
    }

    private struct HeldPrompt {
        let scope: String
        let prompt: SyncedPrompt
        let commitApproval: (@MainActor @Sendable (ApprovalOutcome) -> Void)?
    }

    private static var syncedHeld: [UUID: HeldPrompt] = [:]

    private static func holdForSyncedDevice(id: UUID, scope: String, request: PromptRequest) {
        syncedHeld[id] = HeldPrompt(
            scope: scope,
            prompt: SyncedPrompt(
                id: id,
                toolName: request.toolName,
                description: request.description,
                argumentsJSON: request.argumentsJSON,
                offersRunLease: request.offersRunLease && !request.perCallApprovalOnly,
                surface: request.executionSurface?.rawValue,
                requestedAt: Date()
            ),
            commitApproval: request.commitApproval
        )
        AttentionProducers.beginWaiting(itemId: id, step: L("Waiting for approval"))
        postSyncedChange(scope: scope)
    }

    private static func postSyncedChange(scope: String) {
        NotificationCenter.default.post(name: syncedPromptsDidChangeNotification, object: nil, userInfo: ["scope": scope])
    }

    /// The cards waiting on the device chatting in `scope`, oldest first.
    static func syncedPrompts(scope: String) -> [SyncedPrompt] {
        syncedHeld.values.filter { $0.scope == scope }.map(\.prompt).sorted { $0.requestedAt < $1.requestedAt }
    }

    /// Answers a held card from the device chatting in `scope`. False when
    /// the id isn't waiting there.
    @discardableResult
    static func resolveFromSyncedDevice(id: UUID, scope: String, outcome: PromptResolution) -> Bool {
        guard let held = syncedHeld[id], held.scope == scope else { return false }
        let outcome = !held.prompt.offersRunLease && outcome == .allowForRun ? .allowOnce : outcome
        resolve(id: id, outcome: outcome)
        return true
    }

    /// Denies every card held for `scope`, when its run ends.
    static func denySyncedPrompts(scope: String) {
        for (id, held) in syncedHeld where held.scope == scope { resolve(id: id, outcome: .denied) }
    }

    // MARK: - Entry points

    static func requestApproval(
        toolName: String,
        description: String,
        descriptionIsForModel: Bool = false,
        argumentsJSON: String,
        knowledgeWritePreview: KnowledgeWritePreview? = nil,
        perCallApprovalOnly: Bool = false,
        executionSurface: ToolExecutionSurface? = nil
    ) async -> Bool {
        switch await requestApprovalOutcome(
            toolName: toolName,
            description: description,
            descriptionIsForModel: descriptionIsForModel,
            argumentsJSON: argumentsJSON,
            knowledgeWritePreview: knowledgeWritePreview,
            perCallApprovalOnly: perCallApprovalOnly,
            executionSurface: executionSurface
        ) {
        case .denied: return false
        case .allowOnce, .allowForRun, .alwaysAllow: return true
        }
    }

    /// `knowledgeWritePreview` swaps the generic JSON arguments block for a
    /// per-document manifest with diffs. Supplied only by the knowledge write
    /// tools; every other caller leaves it nil and the modal is unchanged.
    ///
    /// `perCallApprovalOnly` suppresses "Allow for This Task" and "Always
    /// Allow" so the call cannot be pre-granted. See `PerCallApprovalTool`.
    ///
    /// `executionSurface` names the machine the call runs on (VM / this Mac /
    /// remote MCP server). The registry gate resolves it from the tool's
    /// live routing; other callers leave it nil and the card shows no badge.
    ///
    /// `descriptionIsForModel` marks `description` as the tool's schema
    /// text, which the sheet replaces with plain copy instead of showing.
    static func requestApprovalOutcome(
        toolName: String,
        description: String,
        descriptionIsForModel: Bool = false,
        argumentsJSON: String,
        knowledgeWritePreview: KnowledgeWritePreview? = nil,
        perCallApprovalOnly: Bool = false,
        executionSurface: ToolExecutionSurface? = nil
    ) async -> ApprovalOutcome {
        if isHeadlessTestProcess { return .denied }
        if Task.isCancelled { return .denied }

        let resolution = await enqueue(
            PromptRequest(
                toolName: toolName,
                description: description,
                argumentsJSON: argumentsJSON,
                knowledgeWritePreview: knowledgeWritePreview,
                perCallApprovalOnly: perCallApprovalOnly,
                offersRunLease: !perCallApprovalOnly,
                executionSurface: executionSurface,
                requester: .current,
                descriptionIsForModel: descriptionIsForModel,
                stepReason: ChatExecutionContext.currentWorkflowStepReason,
                sandboxFacts: sandboxFacts(for: executionSurface),
                workflowFacts: workflowFacts()
            ),
            revalidate: nil
        )
        switch resolution {
        case .denied:
            return .denied
        case .allowOnce:
            return .allowOnce
        case .allowForRun:
            return .allowForRun
        case .alwaysAllow:
            ToolRegistry.shared.setPolicy(.auto, for: toolName)
            return .alwaysAllow
        }
    }

    /// Approval prompt for a caller-owned policy. Unlike `requestApproval`,
    /// choosing "Always Allow" does NOT mutate `ToolRegistry`: the caller owns
    /// the policy namespace and persists that outcome in its own store.
    ///
    /// Cancellation is terminal and denial-shaped. This is required by spawn
    /// preparation, where the feed's Stop control can fire while the panel is
    /// open (or while the request is still queued behind another prompt); the
    /// continuation must be resumed and the modal dismissed rather than
    /// stranding the tool call.
    ///
    /// `revalidate` runs right before this request would be presented. Return
    /// a resolution to settle it silently (the caller's policy changed while it
    /// waited in the queue), or nil to show the panel.
    static func requestPolicyApproval(
        toolName: String,
        description: String,
        argumentsJSON: String,
        revalidate: (@Sendable () async -> PolicyApprovalOutcome?)? = nil
    ) async -> PolicyApprovalOutcome {
        if isHeadlessTestProcess { return .denied }
        if Task.isCancelled { return .denied }

        var mappedRevalidate: Revalidation?
        if let hook = revalidate {
            mappedRevalidate = { () async -> PromptResolution? in
                guard let outcome = await hook() else { return nil }
                return Self.resolution(for: outcome)
            }
        }
        let resolution = await enqueue(
            PromptRequest(
                toolName: toolName,
                description: description,
                argumentsJSON: argumentsJSON,
                knowledgeWritePreview: nil,
                perCallApprovalOnly: false,
                offersRunLease: false,
                executionSurface: nil,
                requester: .current,
                stepReason: ChatExecutionContext.currentWorkflowStepReason
            ),
            revalidate: mappedRevalidate
        )
        switch resolution {
        case .denied: return .denied
        case .allowOnce, .allowForRun: return .allowOnce
        case .alwaysAllow: return .alwaysAllow
        }
    }

    /// Full outcomes for a caller-owned policy that also owns a task lease.
    /// The caller records run approval in that lease and persistent approval
    /// in its policy store. This entry point never writes ToolRegistry.
    /// Existing spawn callers keep the narrower entry point and no run button.
    static func requestPolicyApprovalOutcome(
        toolName: String,
        description: String,
        descriptionIsForModel: Bool = false,
        argumentsJSON: String,
        offersRunLease: Bool = false,
        commitApproval: (@MainActor @Sendable (ApprovalOutcome) -> Void)? = nil,
        revalidate: (@Sendable () async -> PolicyApprovalOutcome?)? = nil
    ) async -> ApprovalOutcome {
        if isHeadlessTestProcess { return .denied }
        if Task.isCancelled { return .denied }

        var mappedRevalidate: Revalidation?
        if let hook = revalidate {
            mappedRevalidate = { () async -> PromptResolution? in
                guard let outcome = await hook() else { return nil }
                return Self.resolution(for: outcome)
            }
        }
        let resolution = await enqueue(
            PromptRequest(
                toolName: toolName,
                description: description,
                argumentsJSON: argumentsJSON,
                knowledgeWritePreview: nil,
                perCallApprovalOnly: false,
                offersRunLease: offersRunLease,
                executionSurface: nil,
                requester: .current,
                descriptionIsForModel: descriptionIsForModel,
                stepReason: ChatExecutionContext.currentWorkflowStepReason,
                commitApproval: commitApproval
            ),
            revalidate: mappedRevalidate
        )
        switch resolution {
        case .denied: return .denied
        case .allowOnce: return .allowOnce
        case .allowForRun: return .allowForRun
        case .alwaysAllow: return .alwaysAllow
        }
    }

    nonisolated private static func resolution(
        for outcome: PolicyApprovalOutcome
    ) -> PromptResolution {
        switch outcome {
        case .denied: return .denied
        case .allowOnce: return .allowOnce
        case .alwaysAllow: return .alwaysAllow
        }
    }

    // MARK: - Queue core

    private static func enqueue(
        _ request: PromptRequest,
        revalidate: Revalidation?
    ) async -> PromptResolution {
        let id = UUID()
        let presenter = presentationOverrideForTests
        let observer = ChatExecutionContext.approvalWaitObserver
        await observer?(true)
        let resolution = await waitForResolution(id: id, request: request, revalidate: revalidate, presenter: presenter)
        await observer?(false)
        return resolution
    }

    private static func waitForResolution(
        id: UUID,
        request: PromptRequest,
        revalidate: Revalidation?,
        presenter: TestPresenter?
    ) async -> PromptResolution {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[id] = continuation
                if case .syncedDevice(let scope) = request.requester {
                    holdForSyncedDevice(id: id, scope: scope, request: request)
                    return
                }
                queue.append(
                    PendingPrompt(
                        id: id,
                        request: request,
                        revalidate: revalidate,
                        presenter: presenter
                    )
                )
                // Cancellation can race the MainActor hop into this
                // continuation. Re-check after the entry is registered so the
                // hook below (or this check) always finds something to deny.
                if Task.isCancelled {
                    resolve(id: id, outcome: .denied, attention: AttentionProducers.abandoned)
                    return
                }
                raiseAttention(id: id, request: request)
                pump()
            }
        } onCancel: {
            Task { @MainActor in
                resolve(id: id, outcome: .denied, attention: AttentionProducers.abandoned)
            }
        }
    }

    /// Mirrors the card onto the attention channels (desktop notification,
    /// the phone's feed) so it can be answered away from the panel. Any
    /// answer lands in `resolve`, which settles the item everywhere.
    private static func raiseAttention(id: UUID, request: PromptRequest) {
        var actions: [AttentionAction] = [.approve, .deny, .open]
        if request.offersRunLease && !request.perCallApprovalOnly {
            actions.insert(.allowForConversation, at: 1)
        }
        let presentation = request.presentation
        var item = AttentionProducers.item(
            id: id,
            kind: .toolApproval,
            title: L("\(presentation.title)?"),
            body: presentation.reason ?? presentation.summary ?? presentation.preview ?? "",
            toolName: request.toolName,
            actions: actions
        )
        let arguments = request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !arguments.isEmpty, arguments != "{}" {
            item.argumentsPreview = String(arguments.prefix(600))
        }
        AttentionProducers.beginWaiting(itemId: id, step: L("Waiting for approval"))
        AttentionCenter.shared.raise(item) { resolution in
            let outcome: PromptResolution
            switch resolution.outcome {
            case .approved: outcome = .allowOnce
            case .allowedForConversation: outcome = actions.contains(.allowForConversation) ? .allowForRun : .allowOnce
            default: outcome = .denied
            }
            resolve(id: id, outcome: outcome, attention: resolution)
        }
    }

    nonisolated private static func attentionOutcome(for outcome: PromptResolution) -> AttentionResolution.Outcome {
        switch outcome {
        case .denied: return .denied
        case .allowOnce, .alwaysAllow: return .approved
        case .allowForRun: return .allowedForConversation
        }
    }

    /// Present the head of the queue if nothing is presented. Re-entrant safe:
    /// a resolution that happens synchronously inside presentation (headless
    /// guard, immediate cancellation) simply pumps again.
    private static func pump() {
        guard slot == nil else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            // Resolved (cancelled) while it was still queued.
            guard continuations[next.id] != nil else { continue }

            if let revalidate = next.revalidate {
                slot = .revalidating(next.id)
                Task { @MainActor in
                    let early = await revalidate()
                    // Resolved during the re-check: `resolve` already
                    // released the slot and pumped.
                    guard case .revalidating(let heldId)? = slot, heldId == next.id else { return }
                    if let early {
                        resolve(
                            id: next.id,
                            outcome: early,
                            attention: AttentionResolution(outcome: attentionOutcome(for: early), surface: .system)
                        )
                    } else {
                        present(next)
                    }
                }
                return
            }

            present(next)
            return
        }
    }

    /// `attention` describes who answered and where; nil means the owner on
    /// the panel.
    private static func resolve(id: UUID, outcome: PromptResolution, attention: AttentionResolution? = nil) {
        if let held = syncedHeld.removeValue(forKey: id) {
            AttentionProducers.endWaiting(itemId: id)
            if let continuation = continuations.removeValue(forKey: id) {
                commit(outcome, to: held.commitApproval)
                continuation.resume(returning: outcome)
            }
            postSyncedChange(scope: held.scope)
            return
        }
        let commitApproval = pendingRequest(id: id)?.commitApproval
        queue.removeAll { $0.id == id }
        if let current = slot, current.id == id {
            tearDown(current)
            slot = nil
            presentedRequest = nil
        }
        if let continuation = continuations.removeValue(forKey: id) {
            AttentionCenter.shared.resolve(
                id: id,
                with: attention ?? AttentionProducers.inline(attentionOutcome(for: outcome))
            )
            AttentionProducers.endWaiting(itemId: id)
            commit(outcome, to: commitApproval)
            continuation.resume(returning: outcome)
        }
        pump()
    }

    /// Publish the caller-owned grant while this resolution still owns the
    /// queue. Resuming first lets the next card read stale Ask.
    private static func commit(
        _ outcome: PromptResolution,
        to commitApproval: (@MainActor @Sendable (ApprovalOutcome) -> Void)?
    ) {
        switch outcome {
        case .denied: break
        case .allowOnce: commitApproval?(.allowOnce)
        case .allowForRun: commitApproval?(.allowForRun)
        case .alwaysAllow: commitApproval?(.alwaysAllow)
        }
    }

    private static func tearDown(_ slot: PresenterSlot) {
        guard case .presented(_, let handles?) = slot else { return }
        NotificationCenter.default.removeObserver(handles.closeObserver)
        if let monitor = handles.keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        handles.panel.orderOut(nil)
        lastRenderedCardSize = nil
    }

    // MARK: - Presentation

    private static func present(_ entry: PendingPrompt) {
        let id = entry.id
        let request = entry.request
        let queuedBehind = queue.count
        presentedRequest = request

        if let override = entry.presenter {
            slot = .presented(id, nil)
            override(id, request.toolName, queuedBehind)
            return
        }

        let onAllow = { resolve(id: id, outcome: .allowOnce) }
        let onDeny = { resolve(id: id, outcome: .denied) }
        let onAlwaysAllow = { resolve(id: id, outcome: .alwaysAllow) }
        let onAllowForRun: (() -> Void)? =
            request.offersRunLease && !request.perCallApprovalOnly
            ? { resolve(id: id, outcome: .allowForRun) }
            : nil

        let themeManager = ThemeManager.shared
        let permissionView = ToolPermissionView(
            presentation: request.presentation,
            onAllow: onAllow,
            onDeny: onDeny,
            onAlwaysAllow: onAlwaysAllow,
            onAllowForRun: onAllowForRun,
            knowledgeWritePreview: request.knowledgeWritePreview,
            perCallApprovalOnly: request.perCallApprovalOnly,
            queuedBehind: queuedBehind
        )
        .environment(\.theme, themeManager.currentTheme)

        let handles = makePanel(view: permissionView, onAllow: onAllow, onDeny: onDeny)
        slot = .presented(id, handles)
        // Apply the card size reported during the sizing layout pass, when
        // the panel was not yet registered and the callback could not act.
        if let renderedSize = lastRenderedCardSize {
            resizePanelToRenderedContent(renderedSize)
        }
        NSApp.activate(ignoringOtherApps: true)
        handles.panel.makeKeyAndOrderFront(nil)
        let panel = handles.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            panel.makeKey()
            if let contentView = panel.contentView { panel.makeFirstResponder(contentView) }
        }
    }

    /// Builds a centered borderless modal panel hosting `view`, wires
    /// Enter→allow / Esc→deny key handling, and a close-safety-net that denies.
    /// Every handle is returned to the caller; nothing is stored in a shared
    /// static, so a second panel can never orphan the first.
    private static func makePanel<V: View>(
        view: V,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) -> PanelHandles {
        // `fittingSize` measures the card at its ideal size, but the
        // description/arguments ScrollViews report their full content height
        // as ideal while rendering capped. Sizing the window from that
        // measurement leaves transparent slack around the card whose edge
        // shows as a scribbled outline. Track the rendered size instead and
        // keep the window glued to it.
        let sizedView = view.onGeometryChange(for: CGSize.self, of: \.size) { size in
            // The first report arrives during the sizing layout pass, before
            // the panel is registered; stash it so presentation can apply it.
            lastRenderedCardSize = size
            resizePanelToRenderedContent(size)
        }
        let hostingController = NSHostingController(rootView: sizedView)
        // The hidden title bar must not become a SwiftUI safe-area inset:
        // it pushes the card down and leaves a transparent strip at the top
        // of the panel where the window edge shows through.
        hostingController.safeAreaRegions = []
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Tool Permission")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Follow the app theme, not the system appearance: otherwise the
        // scroll indicators render for the wrong appearance (white thumb on
        // the light card).
        panel.appearance = NSAppearance(
            named: ThemeManager.shared.currentTheme.isDark ? .darkAqua : .aqua
        )
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .alertPanel
        panel.contentViewController = hostingController

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        let windowSize = NSSize(
            width: max(fittingSize.width, 480),
            height: max(fittingSize.height, 300)
        )
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        }
        // Keep the decision on the launching app window's display. Falling
        // back to the mouse display can make a security prompt appear on a
        // different monitor than the chat that is visibly blocked on it.
        let targetScreen = preferredPresentationCandidate(
            keyWindow: NSApp.keyWindow?.screen,
            mainWindow: NSApp.mainWindow?.screen,
            mouse: mouseScreen,
            fallback: NSScreen.main
        )
        if let screen = targetScreen {
            let vf = screen.visibleFrame
            // The approval buttons must stay reachable: never size the panel
            // taller (or wider) than the visible screen area. With
            // .fullSizeContentView the content fills the whole frame, so the
            // fitting size is the frame size; adding a title-bar conversion
            // here over-sizes the window and leaves empty strips.
            let frameSize = clampedWindowSize(windowSize, to: vf.size)
            panel.setFrame(
                NSRect(
                    x: vf.origin.x + (vf.width - frameSize.width) / 2,
                    y: vf.origin.y + (vf.height - frameSize.height) / 2,
                    width: frameSize.width,
                    height: frameSize.height
                ),
                display: false
            )
        } else {
            panel.setContentSize(windowSize)
            panel.center()
        }

        nonisolated(unsafe) let onDenyForClose = onDeny
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in onDenyForClose() }

        let handleKeyEvent: (NSEvent) -> Bool = { event in
            if event.keyCode == 36 { onAllow(); return true }
            if event.keyCode == 53 { onDeny(); return true }
            return false
        }
        weak var weakPanel = panel
        let shownAt = Date()
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isPanelKey = weakPanel?.isKeyWindow == true
            guard shouldAcceptKeyboardShortcut(
                isVisible: weakPanel?.isVisible == true,
                isKeyWindow: isPanelKey,
                isAppActive: NSApp.isActive,
                shownFor: Date().timeIntervalSince(shownAt)
            ) else {
                // Swallow an early Return/Esc aimed at the panel instead of
                // passing it to whatever is behind it.
                if isPanelKey, event.keyCode == 36 || event.keyCode == 53 { return nil }
                return event
            }
            return handleKeyEvent(event) ? nil : event
        }
        return PanelHandles(panel: panel, closeObserver: closeObserver, keyMonitor: keyMonitor)
    }

    private static var presentedPanel: NSPanel? {
        guard case .presented(_, let handles?) = slot else { return nil }
        return handles.panel
    }

    /// Snaps the panel to the card's actually rendered size, recentered on
    /// its screen and clamped to the visible frame so the approval buttons
    /// stay reachable. Called from `onGeometryChange`, so the window follows
    /// the card if its layout settles differently than first measured.
    private static func resizePanelToRenderedContent(_ size: CGSize) {
        guard let panel = presentedPanel, size.width > 1, size.height > 1 else { return }
        var target = NSSize(width: size.width, height: size.height)
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame
        if let vf { target = clampedWindowSize(target, to: vf.size) }
        guard abs(panel.frame.width - target.width) > 0.5
            || abs(panel.frame.height - target.height) > 0.5
        else { return }
        let origin: NSPoint
        if let vf {
            origin = NSPoint(
                x: vf.origin.x + (vf.width - target.width) / 2,
                y: vf.origin.y + (vf.height - target.height) / 2
            )
        } else {
            origin = panel.frame.origin
        }
        panel.setFrame(NSRect(origin: origin, size: target), display: true)
        panel.invalidateShadow()
    }

    // MARK: - Pure seams

    /// Pure seams keep the security-sensitive screen and key-event policy
    /// deterministic in tests without constructing AppKit windows.
    nonisolated static func clampedWindowSize(_ size: NSSize, to visible: NSSize) -> NSSize {
        NSSize(
            width: min(size.width, visible.width),
            height: min(size.height, visible.height)
        )
    }

    nonisolated static func preferredPresentationCandidate<T>(
        keyWindow: T?,
        mainWindow: T?,
        mouse: T?,
        fallback: T?
    ) -> T? {
        keyWindow ?? mainWindow ?? mouse ?? fallback
    }

    /// The panel activates the app and takes key focus, so a Return typed
    /// for another app just as it appears would land here as Allow.
    nonisolated static let keyboardArmDelay: TimeInterval = 0.8

    nonisolated static func shouldAcceptKeyboardShortcut(
        isVisible: Bool,
        isKeyWindow: Bool,
        isAppActive: Bool,
        shownFor: TimeInterval
    ) -> Bool {
        isVisible && isKeyWindow && isAppActive && shownFor >= keyboardArmDelay
    }
}
