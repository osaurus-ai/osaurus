//
//  WorkflowTools.swift
//  osaurus
//
//  Calling installed workflows. Each workflow a custom agent enables is a
//  `workflow_<slug>` tool whose parameters are the workflow's input schema;
//  the Orchestrator has one `run_workflow` tool for the workflows marked
//  visible to it. Both check setup before every call and answer with a
//  `WorkflowCallResult`. A chat waits for the run (its forms show inline);
//  a Work Mode task, or a chat's routed run, gets `awaiting_user` when the
//  run stops for a form and resumes when the run ends.
//

import Foundation

enum WorkflowToolCall {
    static func caller(kind: WorkflowCaller.Kind) async -> WorkflowCaller {
        let agentID = ChatExecutionContext.currentAgentId
        let agentName = await MainActor.run { agentID.flatMap { AgentManager.shared.agent(for: $0)?.name } }
        let inOpenHarnessChat = await isInOpenHarnessChat()
        var caller = WorkflowCaller(
            kind: kind, agentID: agentID, agentName: agentName, sessionID: ChatExecutionContext.currentSessionId,
            background: ChatExecutionContext.currentBackgroundId != nil || (isHeadless && !inOpenHarnessChat),
            toolCallID: ChatExecutionContext.currentToolCallId,
            isExternalSurface: ChatExecutionContext.isExternalSurface,
            hasRemoteReviewer: ChatExecutionContext.hasRemoteReviewer,
            isUnattendedDispatch: ChatExecutionContext.isUnattendedDispatch,
            folderPath: ChatExecutionContext.currentFolderRoot?.path)
        if let participant = sharedRunCaller {
            caller.onBehalfOf = participant
            caller.workspaceId = sharedRunWorkspaceId
        }
        return caller
    }

    /// The person or agent driving this call through one of this Mac's
    /// shared agents (`/agents/{id}/run` with a teammate, guest or remote
    /// agent as caller). nil for the owner, their own devices, channel
    /// senders and every in-app surface.
    static var sharedRunCaller: Participant? {
        guard ChatExecutionContext.isExternalSurface, let participant = ChatExecutionContext.currentParticipant
        else { return nil }
        switch participant.kind {
        case .teammate, .invitePeer, .remoteAgent: return participant
        default: return nil
        }
    }

    /// The workspace a shared run came through; nil for guests.
    static var sharedRunWorkspaceId: String? {
        let id =
            ChatExecutionContext.ownerApprovalRoute?.workspaceId
            ?? ChatExecutionContext.workspaceBillingContext?.workspaceId
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// `.ask` for a shared run of a workflow the owner opened to teammates,
    /// so the call reaches the owner through the agent's teammate approval
    /// (`OwnerApprovalService`) and is denied when that is off. A workflow
    /// that is not open to teammates resolves `.auto` here and is refused
    /// with a clear message by `run` before anything starts.
    static func sharedRunPolicy(workflowID: UUID?) async -> ToolPermissionPolicy {
        guard sharedRunCaller != nil, let workflowID else { return .auto }
        let open = await MainActor.run { InstalledWorkflowStore.shared.workflow(id: workflowID)?.teammatesCanRun }
        return open == true ? .ask : .auto
    }

    static func teammateRefusal(workflow: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message: "\(workflow) is not open to people this agent is shared with, so it did not run. "
                + "Tell them its owner has not allowed it; do not try another workflow in its place.",
            tool: tool, retryable: false)
    }

    /// Every start, finish, and refusal of a run someone else started (a
    /// teammate or an invite-link guest) lands in Insights → Interactions
    /// with who it was; a teammate's also goes to the workspace audit log.
    static func auditTeammateRun(
        _ event: WorkspaceAuditEventKind, caller: WorkflowCaller, workflow: String, runID: UUID?,
        details: [String: String] = [:]
    ) {
        if let interaction = interaction(event, caller: caller, workflow: workflow, runID: runID, details: details) {
            InsightsService.logEgress(
                category: .interaction, source: WorkflowActivityLogger.source(for: caller),
                method: interaction.method, path: interaction.path, statusCode: interaction.statusCode,
                durationMs: 0, egress: EgressInfo(details: interaction.details), locality: .local,
                attribution: InsightsService.ActivityAttribution(
                    agentId: caller.agentID, sessionId: caller.sessionID.flatMap(UUID.init(uuidString:)),
                    workflowRunId: runID, participant: caller.onBehalfOf))
        }
        guard let participant = caller.onBehalfOf, let workspaceId = caller.workspaceId else { return }
        let agentID = caller.agentID
        Task {
            let agent = await MainActor.run { agentID.flatMap { AgentManager.shared.agent(for: $0) } }
            await WorkspaceAuditLog.shared.recordWorkflowRun(
                event, workspaceId: workspaceId, caller: participant, agentAddress: agent?.agentAddress,
                agentName: agent?.name ?? caller.agentName, workflowName: workflow, runId: runID, details: details)
        }
    }

    struct Interaction: Equatable {
        var method: String
        var path: String
        var statusCode: Int
        var details: [String: String]
    }

    /// The Interactions row for a run someone else started; nil for the
    /// owner's own runs.
    static func interaction(
        _ event: WorkspaceAuditEventKind, caller: WorkflowCaller, workflow: String, runID: UUID?,
        details: [String: String] = [:]
    ) -> Interaction? {
        guard let participant = caller.onBehalfOf else { return nil }
        var row = details
        row["kind"] = "workflow_run"
        row["workflow"] = workflow
        row["requester"] = ParticipantFormatter.short(participant)
        row["requester_kind"] = participant.kind.rawValue
        if let workspaceId = caller.workspaceId { row["workspace_id"] = workspaceId }
        if let runID { row["run_id"] = runID.uuidString }
        switch event {
        case .workflowRunStarted:
            return Interaction(method: "START", path: "/workflows/run", statusCode: 202, details: row)
        case .workflowRunRefused:
            return Interaction(method: "REFUSE", path: "/workflows/run", statusCode: 403, details: row)
        default:
            let ok = details["success"] == "true"
            return Interaction(method: "FINISH", path: "/workflows/run", statusCode: ok ? 200 : 500, details: row)
        }
    }

    /// An external caller (HTTP agent run, MCP bridge) has no window to
    /// show a form in, so its runs park like Work Mode's. The owner's
    /// paired phone answers forms over the relay, so its calls still wait.
    static var isHeadless: Bool {
        ChatExecutionContext.isExternalSurface && !ChatExecutionContext.hasRemoteReviewer
    }

    /// A harness bridge call from a chat open in a window: its forms ask
    /// in that chat (`syncWorkflowDialogs`) instead of parking.
    static func isInOpenHarnessChat() async -> Bool {
        guard let chatId = ChatExecutionContext.harnessChatId else { return false }
        return await MainActor.run { ChatWindowManager.shared.session(forSessionId: chatId) != nil }
    }

    /// Checks setup and input, runs the workflow, and encodes the outcome.
    /// `routed`: see `follow`.
    static func run(
        workflowID: UUID, input: JSONValue, caller: WorkflowCaller, tool: String, routed: Bool = false
    ) async -> String {
        let started = await start(workflowID: workflowID, input: input, caller: caller, tool: tool)
        let runID: UUID
        switch started {
        case .failure(let failure): return failure.envelope
        case .success(let id): runID = id
        }
        let workflow = await MainActor.run { InstalledWorkflowStore.shared.workflow(id: workflowID) }
        return await follow(runID, workflow: workflow, caller: caller, tool: tool, routed: routed)
    }

    /// Runs an agent's wrapper (`AgentWrapperCatalog`) for the Orchestrator.
    /// Owner only: a teammate driving a shared agent can't reach the
    /// Orchestrator's agents through it.
    static func runWrapper(_ wrapper: AgentWrapper, input: JSONValue, caller: WorkflowCaller, tool: String) async
        -> String
    {
        guard caller.onBehalfOf == nil else { return teammateRefusal(workflow: wrapper.name, tool: tool) }
        let installed = wrapper.installed
        let issues = JSONSchemaValidator.validate(input, against: installed.definition.inputSchema)
        if let first = issues.first {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "\(wrapper.name) takes one input, `\(AgentWrapperCatalog.taskInput)`: the request in the "
                    + "user's words. " + issues.map(\.description).joined(separator: "; "),
                field: first.path, tool: tool)
        }
        let runID = await MainActor.run { WorkflowRunService.shared.startWrapper(wrapper, input: input, caller: caller) }
        return await follow(runID, workflow: installed, caller: caller, tool: tool, routed: true)
    }

    /// Runs a first-run ask (`PreparedAskCatalog`) by id. Owner only, with
    /// the same setup and input checks an installed workflow gets.
    static func runPrepared(_ workflow: InstalledWorkflow, input: JSONValue, caller: WorkflowCaller, tool: String)
        async -> String
    {
        guard caller.onBehalfOf == nil else { return teammateRefusal(workflow: workflow.name, tool: tool) }
        let failure: String? = await MainActor.run {
            let report = SetupChecker.check(
                workflow, secrets: .caller(caller.credentialAgentID), attended: caller.isAttended)
            if !report.blocking.isEmpty {
                return envelope(setupResult(report), workflow: workflow.name, tool: tool)
            }
            let issues = JSONSchemaValidator.validate(input, against: workflow.definition.inputSchema)
            if let first = issues.first {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: issues.map(\.description).joined(separator: "; "),
                    field: first.path, tool: tool)
            }
            return nil
        }
        if let failure { return failure }
        let runID = await MainActor.run {
            WorkflowRunService.shared.startPrepared(workflow, input: input, caller: caller)
        }
        return await follow(runID, workflow: workflow, caller: caller, tool: tool, routed: true)
    }

    /// Waits for a started run (the calling chat's tool card follows it)
    /// and encodes the outcome. A routed run (the Orchestrator's) parks a
    /// chat turn on a form, as Work Mode does: the call
    /// answers `awaiting_user` and the chat resumes with the result
    /// (`WorkflowWorkModeResume`). A custom agent's workflow tool keeps the
    /// turn and its form inline. `planning` is the inline Architect's draft,
    /// kept as the card's first step.
    static func follow(
        _ runID: UUID, workflow: InstalledWorkflow?, caller: WorkflowCaller, tool: String, routed: Bool = false,
        planning: WorkflowCallFeed.Planning? = nil
    ) async -> String {
        let liveFeed: WorkflowCallFeed? = await MainActor.run {
            guard let toolCallID = caller.toolCallID, !isHeadless, let workflow else { return nil }
            return WorkflowCallFeed.attach(
                runID: runID, toolCallID: toolCallID, workflow: workflow, caller: caller, planning: planning)
        }
        let parksChatTurn = routed && !caller.background && caller.sessionID != nil && caller.toolCallID != nil
        let run = await withTaskCancellationHandler {
            caller.background || parksChatTurn
                ? await WorkflowRunService.shared.settledOrParked(runID)
                : await WorkflowRunService.shared.result(of: runID)
        } onCancel: {
            Task { @MainActor in WorkflowRunService.shared.cancel(runID) }
        }
        await MainActor.run { liveFeed?.finish(run) }
        let name = workflow?.name ?? tool
        guard let run else {
            return ToolEnvelope.failure(
                kind: .executionError, message: "The workflow run was lost.", tool: tool,
                metadata: ["run_id": runID.uuidString])
        }
        auditFinished(run, caller: caller, workflow: name)
        return envelope(
            WorkflowCallResult(run: run), workflow: name, tool: tool,
            resumes: ChatExecutionContext.currentBackgroundId != nil || parksChatTurn,
            waitingOn: caller.onBehalfOf != nil ? .owner : .user)
    }

    /// The checks every call makes before a run starts (installed, open
    /// to the caller, set up, valid input), then the start itself.
    static func start(
        workflowID: UUID, input: JSONValue, caller: WorkflowCaller, tool: String
    ) async -> Result<UUID, WorkflowCallFailure> {
        await MainActor.run {
            guard let workflow = InstalledWorkflowStore.shared.workflow(id: workflowID) else {
                return .failure(.init(ToolEnvelope.failure(
                    kind: .unavailable, message: "This workflow is no longer installed.", tool: tool,
                    retryable: false)))
            }
            if caller.onBehalfOf != nil, !workflow.teammatesCanRun {
                auditTeammateRun(
                    .workflowRunRefused, caller: caller, workflow: workflow.name, runID: nil,
                    details: ["reason": "not_open_to_teammates"])
                return .failure(.init(teammateRefusal(workflow: workflow.name, tool: tool)))
            }
            let report = SetupChecker.check(
                workflow, secrets: .caller(caller.credentialAgentID), attended: caller.isAttended)
            guard report.blocking.isEmpty else {
                // A key this caller lacks is not the workflow's setup:
                // another agent, or the shared Keys, may have it.
                let keysOnly = SetupChecker.onlyKeysMissing(report)
                if !keysOnly { InstalledWorkflowStore.shared.setNeedsSetup(true, id: workflow.id) }
                return .failure(
                    .init(envelope(setupResult(report), workflow: workflow.name, tool: tool, keysOnly: keysOnly)))
            }
            if workflow.needsSetup { InstalledWorkflowStore.shared.setNeedsSetup(false, id: workflow.id) }
            let issues = JSONSchemaValidator.validate(input, against: workflow.definition.inputSchema)
            if let first = issues.first {
                return .failure(.init(ToolEnvelope.failure(
                    kind: .invalidArgs, message: issues.map(\.description).joined(separator: "; "),
                    field: first.path, tool: tool)))
            }
            let runID = WorkflowRunService.shared.start(workflow, input: input, caller: caller)
            auditTeammateRun(.workflowRunStarted, caller: caller, workflow: workflow.name, runID: runID)
            return .success(runID)
        }
    }

    static func setupResult(_ report: SetupReport) -> WorkflowCallResult {
        WorkflowCallResult(
            status: .needsSetup, reasons: report.blocking.map { "\($0.title): \($0.detail)" },
            noModel: report.blocking.contains(where: \.hasNoModel) ? true : nil)
    }

    static func auditFinished(_ run: WorkflowRun, caller: WorkflowCaller, workflow: String) {
        guard caller.onBehalfOf != nil else { return }
        auditTeammateRun(
            .workflowRunFinished, caller: caller, workflow: workflow, runID: run.id,
            details: [
                "status": run.status.rawValue,
                "success": run.status == .completed ? "true" : "false",
            ])
    }

    /// Who a parked run's form is waiting for: the person in this chat, or
    /// (on a teammate's shared run) the agent's owner on their Mac.
    enum FormAnswerer { case user, owner }

    /// Completed and parked runs are successes; everything else is a typed
    /// failure that still carries the run id and status. `resumes` is false
    /// for headless callers, which nothing continues when a parked run ends.
    static func envelope(
        _ result: WorkflowCallResult, workflow: String, tool: String, resumes: Bool = true, keysOnly: Bool = false,
        waitingOn: FormAnswerer = .user
    ) -> String {
        let payload = (try? JSONSerialization.jsonObject(with: Data(result.jsonString.utf8))) as? [String: Any] ?? [:]
        switch result.status {
        case .completed:
            guard let files = result.filesShown, !files.isEmpty else {
                return ToolEnvelope.success(tool: tool, result: payload)
            }
            var shown = payload
            shown["message"] =
                "The user already sees \(files.joined(separator: ", ")) as attachments in this chat. "
                + "Refer to them by name; do not share them again."
            return ToolEnvelope.success(tool: tool, result: shown)
        case .awaitingUser:
            var parked = payload
            parked["message"] =
                waitingOn == .owner
                ? "\(workflow) is waiting for this agent's owner to fill in a form on their Mac, and this call "
                    + "cannot wait for it. Tell the person you are talking to that the owner has to answer it; "
                    + "the run finishes on its own once they do."
                : resumes
                ? "\(workflow) is waiting for the user to fill in a form. This task resumes with the result when the run ends."
                : "\(workflow) is waiting for the user to fill in a form in Osaurus, and this call cannot wait for it. "
                    + "The run finishes on its own once the form is answered; tell the user it is waiting for them. "
                    + "GET /workflows/runs/\(result.runID?.uuidString ?? "{run_id}") returns the result when it ends."
            return ToolEnvelope.success(tool: tool, result: parked)
        case .needsSetup:
            let reasons = result.reasons ?? []
            let fix =
                keysOnly
                ? "The user adds the missing keys in Settings → Vault, shared by all agents or only for this agent."
                : result.noModel == true
                ? "No model is set up to run it. The user chooses one with Choose a Model on this card or in the "
                    + "chat's model picker, then asks again."
                : "The user finishes it in Main window → Workflows."
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "\(workflow) needs setup before it can run: \(reasons.joined(separator: "; ")). " + fix,
                tool: tool, retryable: false, metadata: payload)
        case .failed:
            let reason = result.error.map { e in e.nodeID.map { "[\($0)] \(e.reason)" } ?? e.reason } ?? "The run failed."
            return ToolEnvelope.failure(
                kind: .executionError, message: "\(workflow) failed: \(reason)", tool: tool, retryable: false,
                metadata: payload)
        case .cancelled:
            return ToolEnvelope.failure(
                kind: .executionError, message: "\(workflow) was cancelled.", tool: tool, retryable: false,
                metadata: payload)
        }
    }

    /// The run a workflow tool result refers to.
    static func runID(inResult result: String) -> UUID? {
        guard let object = JSONValue.parse(result)?.objectValue else { return nil }
        let raw = object["result"]?.objectValue?["run_id"]?.stringValue ?? object["run_id"]?.stringValue
        return raw.flatMap(UUID.init(uuidString:))
    }

    static func isWorkflowCall(_ toolName: String) -> Bool {
        toolName == RunWorkflowTool.toolName
            || (toolName.hasPrefix(WorkflowTool.namePrefix) && !ToolRegistry.architectToolNames.contains(toolName))
            // The Architect's handoff runs what it drafted.
            || toolName == ArchitectHandoffTool.toolName
    }

    /// Runs a teammate's hosted workflow on their Mac and waits for it.
    /// Only for this Mac's owner: a teammate driving one of this Mac's
    /// shared agents can't pass a run on to someone else's Mac.
    static func runHosted(link: HostedWorkflowLink, input: JSONValue, tool: String, trackID: UUID = UUID()) async -> String {
        guard sharedRunCaller == nil else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "\(link.name) runs on \(link.hostLabel) for this agent's owner only, so it did not run.",
                tool: tool, retryable: false)
        }
        let issues = JSONSchemaValidator.validate(input, against: link.inputs)
        if let first = issues.first {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: issues.map(\.description).joined(separator: "; "), field: first.path,
                tool: tool)
        }
        let target = HostedWorkflowClient.Target(
            ref: link.ref, remoteWorkflowID: link.remoteWorkflowID, name: link.name, agentName: link.agentName,
            hostLabel: link.hostLabel)
        await MainActor.run { _ = HostedWorkflowRunCenter.shared.begin(link, id: trackID) }
        let outcome = await HostedWorkflowClient.run(target, input: input) { status in
            await MainActor.run { HostedWorkflowRunCenter.shared.update(trackID, phase: status.phase) }
        }
        await MainActor.run { HostedWorkflowRunCenter.shared.end(trackID) }
        switch outcome {
        case .success(let status):
            guard let result = status.result else {
                return ToolEnvelope.failure(
                    kind: .executionError, message: "\(link.name) ended without a result.", tool: tool,
                    retryable: false)
            }
            return envelope(result, workflow: link.name, tool: tool, resumes: false, waitingOn: .owner)
        case .failure(let failure):
            let kind: ToolEnvelope.Kind
            switch failure {
            case .refused: kind = .rejected
            case .cancelled: kind = .executionError
            case .unreachable, .tooOld: kind = .unavailable
            }
            return ToolEnvelope.failure(
                kind: kind, message: "\(link.name) runs on \(link.hostLabel): \(failure.message)", tool: tool,
                retryable: { if case .unreachable = failure { return true } else { return false } }())
        }
    }

    struct WorkflowCallFailure: Error {
        let envelope: String
        init(_ envelope: String) { self.envelope = envelope }
    }
}

// MARK: - workflow_<slug>

final class WorkflowTool: OsaurusTool, ContextualPermissionedTool, @unchecked Sendable {
    static let namePrefix = "workflow_"

    let workflowID: UUID
    let name: String
    let description: String
    let parameters: JSONValue?
    var bypassRegistryTimeout: Bool { true }
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto

    func resolveContextualPermissionPolicy(argumentsJSON: String) async -> ToolPermissionPolicy {
        await WorkflowToolCall.sharedRunPolicy(workflowID: workflowID)
    }

    init(_ workflow: InstalledWorkflow) {
        workflowID = workflow.id
        name = workflow.toolName
        let summary = workflow.summary.map { " \($0)" } ?? ""
        description =
            "Run the workflow \"\(workflow.name)\".\(summary) Arguments are the workflow's input; "
            + "returns its output as JSON. It may ask the user to fill in a form while it runs."
        parameters = Self.parameters(for: workflow.definition.inputSchema)
    }

    /// The input schema as a tool schema: always an object, closed unless
    /// the workflow declares otherwise.
    static func parameters(for schema: JSONValue) -> JSONValue {
        var object = schema.objectValue ?? [:]
        object["type"] = .string("object")
        if object["properties"] == nil { object["properties"] = .object([:]) }
        if object["additionalProperties"] == nil { object["additionalProperties"] = .bool(false) }
        return .object(object)
    }

    @MainActor
    static func toolNames(enabled ids: [UUID]) -> [String] {
        ids.compactMap {
            InstalledWorkflowStore.shared.workflow(id: $0)?.toolName ?? HostedWorkflowLinkStore.shared.link(id: $0)?.toolName
        }
    }

    func execute(argumentsJSON: String) async throws -> String {
        let agentID = ChatExecutionContext.currentAgentId
        let enabled = await MainActor.run {
            agentID.flatMap { AgentManager.shared.agent(for: $0)?.settings.enabledWorkflowIDs.contains(workflowID) }
                ?? false
        }
        guard enabled else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "\(name) is not enabled for this agent.", tool: name, retryable: false)
        }
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = JSONValue.parse(trimmed.isEmpty ? "{}" : trimmed), input.objectValue != nil else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "Arguments must be a JSON object.", tool: name)
        }
        let caller = await WorkflowToolCall.caller(kind: .agent)
        return await WorkflowToolCall.run(workflowID: workflowID, input: input, caller: caller, tool: name)
    }
}

// MARK: - run_workflow

final class RunWorkflowTool: OsaurusTool, ContextualPermissionedTool, @unchecked Sendable {
    static let toolName = "run_workflow"
    let name = RunWorkflowTool.toolName
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto

    func resolveContextualPermissionPolicy(argumentsJSON: String) async -> ToolPermissionPolicy {
        guard WorkflowToolCall.sharedRunCaller != nil,
            let key = JSONValue.parse(argumentsJSON)?.objectValue?["workflow"]?.stringValue
        else { return .auto }
        let id = await MainActor.run { InstalledWorkflowStore.shared.workflow(named: key)?.id }
        return await WorkflowToolCall.sharedRunPolicy(workflowID: id)
    }
    let description =
        "Run a workflow by name and return its output. `status` lists the workflows you can run, with "
        + "their inputs."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "workflow": .object(["type": .string("string"), "description": .string("Workflow name.")]),
            "input": .object(["type": .string("object"), "additionalProperties": .bool(true)]),
        ]),
        "required": .array([.string("workflow")]),
    ])
    var bypassRegistryTimeout: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "Only the Orchestrator can call run_workflow.", tool: name,
                retryable: false)
        }
        let args = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        guard let key = args["workflow"]?.stringValue, !key.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`workflow` must name an installed workflow.", field: "workflow",
                tool: name)
        }
        // An ask button names its workflow by id: a first-run ask, or an
        // installed workflow (Research Brief for Scout's topic).
        if let id = UUID(uuidString: key) {
            let byID: (prepared: InstalledWorkflow?, installed: UUID?) = await MainActor.run {
                if let prepared = PreparedAskCatalog.installed(id: id) { return (prepared, nil) }
                let installed = InstalledWorkflowStore.shared.workflow(id: id)
                return (nil, installed?.orchestratorVisible == true ? installed?.id : nil)
            }
            let input = args["input"] ?? .object([:])
            guard input.objectValue != nil else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`input` must be a JSON object.", field: "input", tool: name)
            }
            let caller = await WorkflowToolCall.caller(kind: .orchestrator)
            if let prepared = byID.prepared {
                return await WorkflowToolCall.runPrepared(prepared, input: input, caller: caller, tool: name)
            }
            if let installed = byID.installed {
                return await WorkflowToolCall.run(
                    workflowID: installed, input: input, caller: caller, tool: name,
                    routed: true)
            }
        }
        let resolved:
            (id: UUID?, link: HostedWorkflowLink?, wrapper: AgentWrapper?, hidden: Bool, visible: [String]) =
                await MainActor.run {
                    let store = InstalledWorkflowStore.shared
                    let links = HostedWorkflowLinkStore.shared
                    let named = store.workflow(named: key)
                    let match = named.flatMap { $0.orchestratorVisible ? $0.id : nil }
                    let link = named == nil ? links.link(named: key) : nil
                    let wrapper = named == nil && link == nil ? AgentWrapperCatalog.wrapper(named: key) : nil
                    return (
                        match, link.flatMap { $0.orchestratorVisible ? $0 : nil }, wrapper,
                        (named != nil && match == nil) || (link != nil && link?.orchestratorVisible == false),
                        RoutableWorkflowCatalog.names()
                    )
                }
        if let wrapper = resolved.wrapper {
            let input = args["input"] ?? .object([:])
            guard input.objectValue != nil else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`input` must be a JSON object.", field: "input", tool: name)
            }
            let caller = await WorkflowToolCall.caller(kind: .orchestrator)
            return await WorkflowToolCall.runWrapper(wrapper, input: input, caller: caller, tool: name)
        }
        if let link = resolved.link {
            let input = args["input"] ?? .object([:])
            guard input.objectValue != nil else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`input` must be a JSON object.", field: "input", tool: name)
            }
            return await WorkflowToolCall.runHosted(link: link, input: input, tool: name)
        }
        guard let workflowID = resolved.id else {
            let hiddenLink = await MainActor.run { HostedWorkflowLinkStore.shared.link(named: key) }
            if let hiddenLink, !hiddenLink.orchestratorVisible {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: "\"\(key)\" runs on \(hiddenLink.hostLabel) but is not marked \"Osaurus can run this for "
                        + "you\". The user turns that on in Main window → Workflows → All → On teammates' Macs "
                        + "(right-click \(hiddenLink.name)).",
                    tool: name, retryable: false)
            }
            if resolved.hidden {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: "\"\(key)\" is installed but not marked \"Osaurus can run this for you\". The user turns "
                        + "that on in Main window → Workflows → \(key) → Who Can Start It. An automation can still "
                        + "run it (`automations:` entry with `workflow`).",
                    tool: name, retryable: false)
            }
            let list = resolved.visible.isEmpty ? "none" : resolved.visible.joined(separator: ", ")
            let offered = await MainActor.run { WorkspaceWorkflowCatalog.shared.offeredNames(matching: key) }
            let hint =
                offered.isEmpty
                ? ""
                : " \(offered.joined(separator: "; ")) is shared in a workspace but not added here. The user "
                    + "installs it or adds it in Main window → Workflows → Workspaces."
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No workflow named \"\(key)\" is visible to the Orchestrator. Visible workflows: \(list).\(hint)",
                field: "workflow", tool: name)
        }
        let input = args["input"] ?? .object([:])
        guard input.objectValue != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`input` must be a JSON object.", field: "input", tool: name)
        }
        let caller = await WorkflowToolCall.caller(kind: .orchestrator)
        return await WorkflowToolCall.run(
            workflowID: workflowID, input: input, caller: caller, tool: name, routed: true)
    }
}

// MARK: - workflow_<slug> for a hosted workflow

/// A teammate's workflow this Mac added from a workspace. Runs on their
/// Mac; enabled per agent like an install.
final class HostedWorkflowTool: OsaurusTool, @unchecked Sendable {
    let linkID: UUID
    let name: String
    let description: String
    let parameters: JSONValue?
    var bypassRegistryTimeout: Bool { true }
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto

    init(_ link: HostedWorkflowLink) {
        linkID = link.id
        name = link.toolName
        let summary = link.summary.map { " \($0)" } ?? ""
        description =
            "Run the workflow \"\(link.name)\" on \(link.hostLabel) (shared in a workspace).\(summary) Arguments are "
            + "the workflow's input; returns its output as JSON. Its owner approves each run first."
        parameters = WorkflowTool.parameters(for: link.inputs)
    }

    func execute(argumentsJSON: String) async throws -> String {
        let agentID = ChatExecutionContext.currentAgentId
        let link: HostedWorkflowLink? = await MainActor.run {
            guard let agentID, AgentManager.shared.agent(for: agentID)?.settings.enabledWorkflowIDs.contains(linkID) == true
            else { return nil }
            return HostedWorkflowLinkStore.shared.link(id: linkID)
        }
        guard let link else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "\(name) is not enabled for this agent.", tool: name, retryable: false)
        }
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = JSONValue.parse(trimmed.isEmpty ? "{}" : trimmed), input.objectValue != nil else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "Arguments must be a JSON object.", tool: name)
        }
        return await WorkflowToolCall.runHosted(link: link, input: input, tool: name)
    }
}
