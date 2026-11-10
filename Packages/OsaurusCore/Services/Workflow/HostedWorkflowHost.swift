//
//  HostedWorkflowHost.swift
//  osaurus
//
//  The owner's side of hosted workflows: a shared agent runs some of this
//  Mac's workflows for the people it's shared with, on this Mac, with this
//  Mac's keys and folders. A workflow is offered only when it's on for that
//  agent (Abilities → Workflows) and its owner turned on Teammates can run
//  this. `GET /agents/{id}` lists the offers (`hosted_workflows`, never the
//  template); `POST /agents/{id}/workflows/{workflowId}/run` asks the owner
//  and starts a run; the caller follows it with
//  `GET /agents/{id}/workflows/runs/{ticket}` and may cancel it. Each run
//  is the caller's alone: another caller's ticket reads as not found.
//

import Foundation

/// One workflow a shared agent runs for its teammates, as
/// `hosted_workflows` lists it.
public struct HostedWorkflowWire: Codable, Equatable, Sendable {
    public var id: UUID
    public var templateID: UUID
    public var name: String
    public var summary: String?
    /// The tool schema `workflow_<slug>` takes.
    public var inputs: JSONValue

    public init(id: UUID, templateID: UUID, name: String, summary: String?, inputs: JSONValue) {
        self.id = id
        self.templateID = templateID
        self.name = name
        self.summary = summary
        self.inputs = inputs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, inputs
        case templateID = "template_id"
    }
}

/// What a hosted run's ticket reads as (`GET .../workflows/runs/{ticket}`).
public struct HostedWorkflowStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The owner hasn't answered yet.
        case awaitingOwner = "awaiting_owner"
        /// Declined, timed out, or couldn't start; `message` says why.
        case refused
        case running
        /// Stopped on a form the owner answers on their Mac.
        case awaitingUser = "awaiting_user"
        case completed
        case failed
        case cancelled
    }

    public var ticket: UUID
    public var phase: Phase
    public var message: String?
    public var result: WorkflowCallResult?

    public init(ticket: UUID, phase: Phase, message: String? = nil, result: WorkflowCallResult? = nil) {
        self.ticket = ticket
        self.phase = phase
        self.message = message
        self.result = result
    }

    public var isFinal: Bool {
        switch phase {
        case .refused, .completed, .failed, .cancelled: return true
        case .awaitingOwner, .running, .awaitingUser: return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case ticket = "run_id"
        case phase = "status"
        case message, result
    }
}

enum HostedWorkflowHost {
    static let feature = "hosted_workflows"

    /// Who an authenticated remote caller is, from its access key: a
    /// teammate's workspace-minted key, or an invite-link guest's key.
    /// Nil when the workspace access no longer checks out.
    static func caller(keyNonce nonce: String, audience: String?) async -> Caller? {
        if let record = await WorkspaceAgentAccessHost.shared.workspaceKeyRecord(forKeyNonce: nonce) {
            guard (try? await WorkspaceAgentAccessHost.shared.validateCurrentAccess(record)) != nil else { return nil }
            let person = await WorkspaceCallerNameResolver.shared.person(
                workspaceId: record.workspaceId, accountId: record.accountId, wallet: record.wallet)
            let context = WorkspaceSessionContext(
                workspaceId: record.workspaceId, agentAddress: record.agentAddressLower, callerWallet: record.wallet,
                callerName: person?.legacyName, callerHandle: person?.handle)
            return Caller(
                participant: Participant.caller(from: context), workspaceId: record.workspaceId,
                key: record.wallet.lowercased())
        }
        let label = await MainActor.run { APIKeyManager.shared.listKeys().first { $0.nonce == nonce }?.label }
        let provenWallet = InvitePeerIdentityStore.wallet(forKeyNonce: nonce)
        var handle: String?
        if let provenWallet { handle = await WalletHandles.resolver.handle(forWallet: provenWallet) }
        let context = WorkspaceSessionContext(
            workspaceId: "", agentAddress: audience ?? "", callerWallet: nonce,
            callerName: (label?.isEmpty == false) ? label : nil, callerHandle: handle, callerAddress: provenWallet)
        return Caller(participant: Participant.caller(from: context), workspaceId: nil, key: nonce.lowercased())
    }

    /// Workflows `agent` runs for the people it's shared with.
    @MainActor
    static func offers(
        for agent: Agent, workflows: [InstalledWorkflow] = InstalledWorkflowStore.shared.workflows
    ) -> [HostedWorkflowWire] {
        guard !agent.isBuiltIn else { return [] }
        let enabled = Set(agent.settings.enabledWorkflowIDs)
        return workflows.filter { enabled.contains($0.id) && $0.teammatesCanRun }.map {
            HostedWorkflowWire(
                id: $0.id, templateID: $0.templateID, name: $0.name, summary: $0.summary,
                inputs: WorkflowTool.parameters(for: $0.definition.inputSchema))
        }
    }

    struct Refusal: Error, Equatable {
        var status: Int
        var code: String
        var message: String

        var json: String {
            JSONValue.object(["error": .string(code), "message": .string(message)]).compactJSONString
        }
    }

    /// Who asked: the person (or their agent), the workspace they came
    /// through (nil for an invite-link guest), and the key their tickets
    /// belong to (their wallet, else their access key).
    struct Caller: Sendable {
        var participant: Participant
        var workspaceId: String?
        var key: String
    }

    /// The checks that answer at once: the agent runs this workflow for
    /// teammates and is set to ask its owner.
    @MainActor
    static func admit(agentId: UUID, workflowID: UUID, caller: Caller, runtime: Runtime = .live) -> Result<
        (agent: Agent, workflow: InstalledWorkflow, policy: SharedToolApprovalPolicy), Refusal
    > {
        guard let agent = runtime.agent(agentId), !agent.isBuiltIn,
            let workflow = runtime.workflow(workflowID),
            agent.settings.enabledWorkflowIDs.contains(workflowID)
        else {
            return .failure(
                Refusal(status: 404, code: "workflow_not_found", message: "This agent doesn't run that workflow."))
        }
        let audited = workflowCaller(agent: agent, caller: caller)
        guard workflow.teammatesCanRun else {
            WorkflowToolCall.auditTeammateRun(
                .workflowRunRefused, caller: audited, workflow: workflow.name, runID: nil,
                details: ["reason": "not_open_to_teammates"])
            return .failure(
                Refusal(
                    status: 403, code: "not_open_to_teammates",
                    message: "\(workflow.name) isn't open to people \(agent.name) is shared with."))
        }
        guard let policy = agent.sharedToolApproval, policy.mode == .askOwner else {
            WorkflowToolCall.auditTeammateRun(
                .workflowRunRefused, caller: audited, workflow: workflow.name, runID: nil,
                details: ["reason": "owner_approval_off"])
            return .failure(
                Refusal(
                    status: 403, code: "owner_approval_off",
                    message: "\(agent.name)'s owner hasn't set it to ask them, so it can't run workflows for you."))
        }
        return .success((agent, workflow, policy))
    }

    @MainActor
    static func workflowCaller(agent: Agent, caller: Caller) -> WorkflowCaller {
        var out = WorkflowCaller(
            kind: .agent, agentID: agent.id, agentName: agent.name, background: true, isExternalSurface: true)
        out.onBehalfOf = caller.participant
        out.workspaceId = caller.workspaceId
        return out
    }

    /// Test seams for `admit` and `begin`.
    struct Runtime: Sendable {
        var askOwner: @Sendable (OwnerApprovalRoute, _ toolName: String, _ arguments: String) async -> OwnerApprovalDecision
        var start: @Sendable (UUID, JSONValue, WorkflowCaller, String) async -> Result<UUID, WorkflowToolCall.WorkflowCallFailure>
        var agent: @MainActor @Sendable (UUID) -> Agent? = { AgentManager.shared.agent(for: $0) }
        var workflow: @MainActor @Sendable (UUID) -> InstalledWorkflow? = { InstalledWorkflowStore.shared.workflow(id: $0) }
        var finished: @Sendable (UUID) async -> WorkflowRun? = { await WorkflowRunService.shared.result(of: $0) }

        static let live = Runtime(
            askOwner: { route, tool, arguments in
                await OwnerApprovalService.shared.request(
                    route: route, toolName: tool, callId: nil, perCallApproval: false, arguments: arguments)
            },
            start: { id, input, caller, tool in
                await WorkflowToolCall.start(workflowID: id, input: input, caller: caller, tool: tool)
            })
    }

    /// Admits the call, then (in the background) asks the owner and starts
    /// the run. Returns the ticket the caller follows.
    @MainActor
    static func begin(
        agentId: UUID, workflowID: UUID, input: JSONValue, caller: Caller,
        runs: HostedWorkflowRuns = .shared, runtime: Runtime = .live
    ) -> Result<UUID, Refusal> {
        guard input.objectValue != nil else {
            return .failure(Refusal(status: 400, code: "invalid_input", message: "`input` must be a JSON object."))
        }
        let admitted: (agent: Agent, workflow: InstalledWorkflow, policy: SharedToolApprovalPolicy)
        switch admit(agentId: agentId, workflowID: workflowID, caller: caller, runtime: runtime) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): admitted = value
        }
        let agent = admitted.agent
        let workflow = admitted.workflow
        let workflowCaller = workflowCaller(agent: agent, caller: caller)
        let ticket = runs.open(agentId: agentId, workflowID: workflowID, callerKey: caller.key)
        let route = OwnerApprovalRoute(
            agentId: agent.id, agentName: agent.name, agentAddress: agent.agentAddress, caller: caller.participant,
            workspaceId: caller.workspaceId, hostedSessionId: nil,
            conversationKey: "workflow|\(caller.key)|\(agent.id.uuidString)|\(workflowID.uuidString)",
            timeout: admitted.policy.effectiveTimeout, onStatus: { _ in })
        let toolName = workflow.toolName
        let name = workflow.name
        let task = Task { @MainActor in
            let decision = await runtime.askOwner(route, toolName, input.compactJSONString)
            guard decision.isGranted, !Task.isCancelled else {
                WorkflowToolCall.auditTeammateRun(
                    .workflowRunRefused, caller: workflowCaller, workflow: name, runID: nil,
                    details: ["reason": Task.isCancelled ? "cancelled" : "owner_\(decision)"])
                runs.refuse(
                    ticket,
                    message: Task.isCancelled
                        ? "The run was cancelled before it started."
                        : decision.refusalMessage(toolName: name, ownerLabel: OwnerApprovalService.shared.ownerLabel))
                return
            }
            let started = await ChatExecutionContext.$isExternalSurface.withValue(true) {
                await ChatExecutionContext.$currentParticipant.withValue(caller.participant) {
                    await ChatExecutionContext.$ownerApprovalRoute.withValue(route) {
                        await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                            await runtime.start(workflowID, input, workflowCaller, toolName)
                        }
                    }
                }
            }
            switch started {
            case .failure(let failure):
                runs.refuse(ticket, message: Self.message(inEnvelope: failure.envelope))
            case .success(let runID):
                runs.started(ticket, runID: runID)
                if let run = await runtime.finished(runID) {
                    WorkflowToolCall.auditFinished(run, caller: workflowCaller, workflow: name)
                }
            }
        }
        runs.attach(task, to: ticket)
        return .success(ticket)
    }

    static func message(inEnvelope envelope: String) -> String {
        HostedWorkflowClient.errorMessage(Data(envelope.utf8), fallback: L("The workflow"))
    }
}

/// The hosted runs callers started on this Mac, by ticket. Kept in memory:
/// after a relaunch a ticket reads as not found and the caller says so.
@MainActor
final class HostedWorkflowRuns {
    static let shared = HostedWorkflowRuns()
    static let capacity = 200

    private struct Ticket {
        let agentId: UUID
        let workflowID: UUID
        let callerKey: String
        var runID: UUID?
        var refusal: String?
        var task: Task<Void, Never>?
        let openedAt: Date
    }

    private var tickets: [UUID: Ticket] = [:]
    private let runStatus: @MainActor (UUID) -> (run: WorkflowRun?, active: Bool)
    private let cancelRun: @MainActor (UUID) -> Void

    init(
        runStatus: @escaping @MainActor (UUID) -> (run: WorkflowRun?, active: Bool) = {
            (WorkflowRunStore.shared.run(id: $0), WorkflowRunService.shared.isActive($0))
        },
        cancelRun: @escaping @MainActor (UUID) -> Void = { WorkflowRunService.shared.cancel($0) }
    ) {
        self.runStatus = runStatus
        self.cancelRun = cancelRun
    }

    func open(agentId: UUID, workflowID: UUID, callerKey: String) -> UUID {
        if tickets.count >= Self.capacity,
            let oldest = tickets.filter({ $0.value.task == nil || $0.value.refusal != nil })
                .min(by: { $0.value.openedAt < $1.value.openedAt })?.key
        {
            tickets[oldest] = nil
        }
        let id = UUID()
        tickets[id] = Ticket(agentId: agentId, workflowID: workflowID, callerKey: callerKey, openedAt: Date())
        return id
    }

    func attach(_ task: Task<Void, Never>, to ticket: UUID) { tickets[ticket]?.task = task }
    func refuse(_ ticket: UUID, message: String) {
        tickets[ticket]?.refusal = message
        tickets[ticket]?.task = nil
    }
    func started(_ ticket: UUID, runID: UUID) { tickets[ticket]?.runID = runID }

    /// The ticket's state for the caller who opened it; nil for anyone else.
    func status(_ ticket: UUID, agentId: UUID, callerKey: String) -> HostedWorkflowStatus? {
        guard let entry = tickets[ticket], entry.agentId == agentId, entry.callerKey == callerKey else { return nil }
        if let refusal = entry.refusal { return HostedWorkflowStatus(ticket: ticket, phase: .refused, message: refusal) }
        guard let runID = entry.runID else { return HostedWorkflowStatus(ticket: ticket, phase: .awaitingOwner) }
        let (run, active) = runStatus(runID)
        guard let run else { return HostedWorkflowStatus(ticket: ticket, phase: .running) }
        let phase: HostedWorkflowStatus.Phase
        switch run.status {
        case .running: phase = .running
        case .awaitingUser: phase = .awaitingUser
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed, .needsSetup: phase = active ? .running : .failed
        }
        return HostedWorkflowStatus(
            ticket: ticket, phase: phase, result: phase == .running ? nil : WorkflowCallResult(run: run))
    }

    /// Stops the caller's run, or its wait on the owner.
    @discardableResult
    func cancel(_ ticket: UUID, agentId: UUID, callerKey: String) -> Bool {
        guard let entry = tickets[ticket], entry.agentId == agentId, entry.callerKey == callerKey else { return false }
        if let runID = entry.runID {
            cancelRun(runID)
        } else {
            entry.task?.cancel()
        }
        return true
    }
}
