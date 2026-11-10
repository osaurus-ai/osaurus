//
//  WorkflowRun.swift
//  osaurus
//
//  The local record of one workflow call: input, every node's input and
//  output, the model each inference node used, durations, usage, errors,
//  and the final output. Stored on this Mac only (`WorkflowRunStore`).
//

import Foundation

public enum WorkflowRunStatus: String, Codable, Sendable {
    case running
    case awaitingUser = "awaiting_user"
    case completed
    case failed
    case cancelled
    case needsSetup = "needs_setup"

    public var isTerminal: Bool {
        switch self {
        case .running, .awaitingUser: return false
        case .completed, .failed, .cancelled, .needsSetup: return true
        }
    }
}

public enum NodeRunStatus: String, Codable, Sendable {
    case pending
    case running
    case awaitingUser = "awaiting_user"
    case done
    case skipped
    case failed
    /// Output supplied by the caller (Architect `pinned`), not executed.
    case pinned
}

/// One tool call a tool or agentic node made: what it was asked, a preview
/// of what it returned, and how long it took. Arguments are scrubbed of
/// secrets before they are recorded.
public struct WorkflowToolCallRecord: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: String
    public var resultPreview: String?
    public var durationMs: Int?
    public var isError: Bool

    /// Characters of a result kept in the run record.
    public static let previewLimit = 4_000

    public init(name: String, arguments: String, result: String?, durationMs: Int?, isError: Bool) {
        self.name = name
        self.arguments = SecretArgumentScrubber.recordedArguments(toolName: name, argumentsJSON: arguments)
        self.resultPreview = result.map { String($0.prefix(Self.previewLimit)) }
        self.durationMs = durationMs
        self.isError = isError
    }

    enum CodingKeys: String, CodingKey {
        case name, arguments
        case resultPreview = "result_preview"
        case durationMs = "duration_ms"
        case isError = "is_error"
    }
}

/// Why a step failed, classified for whoever fixes it.
public struct NodeRunFailure: Codable, Sendable, Equatable {
    /// Where the fix belongs.
    public enum FixIn: String, Codable, Sendable {
        /// The step itself: its instructions, schema, arguments, code, or limits.
        case workflow
        /// What Set Up provides: a secret, connection, folder, program, or model slot.
        case setup
        /// An app setting: a model default, a permission, Memory Safety, model swapping.
        case settings
        /// Nothing to change; another attempt may succeed.
        case retry
        /// The person declined or dismissed something.
        case person
    }

    /// `snake_case`, e.g. `unavailable`, `output_mismatch`, `http_404`.
    public var kind: String
    public var retryable: Bool
    /// The thrown type and case, e.g. `SubagentError.unavailable`.
    public var errorType: String
    public var fixIn: FixIn
    /// The next thing to do, in one sentence.
    public var hint: String?
    /// The tool a tool step called, when the tool failed.
    public var tool: String?
    /// The tool step's `agent` reference, whose permission and folder it used.
    public var agent: String?

    public init(
        kind: String, retryable: Bool, errorType: String, fixIn: FixIn, hint: String? = nil, tool: String? = nil,
        agent: String? = nil
    ) {
        self.kind = kind
        self.retryable = retryable
        self.errorType = errorType
        self.fixIn = fixIn
        self.hint = hint
        self.tool = tool
        self.agent = agent
    }

    enum CodingKeys: String, CodingKey {
        case kind, retryable, hint, tool, agent
        case errorType = "error_type"
        case fixIn = "fix_in"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "error"
        retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        errorType = try c.decodeIfPresent(String.self, forKey: .errorType) ?? ""
        fixIn = (try? c.decodeIfPresent(FixIn.self, forKey: .fixIn)) ?? .workflow
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
    }
}

public struct NodeRun: Codable, Sendable, Equatable, Identifiable {
    public var nodeID: String
    public var status: NodeRunStatus
    public var input: JSONValue?
    public var output: JSONValue?
    public var error: String?
    /// What kind of failure `error` is and where its fix belongs.
    public var failure: NodeRunFailure?
    /// The resolved model id, for inference nodes.
    public var model: String?
    public var attempts: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    public var logs: [String]
    /// Requests a code node made, e.g. "GET api.clio.com/v4/matters".
    public var fetches: [String]
    /// Tool calls an agentic or tool node made, by tool name.
    public var toolCalls: [String]
    /// The same calls with arguments, result previews, and timings.
    public var toolCallRecords: [WorkflowToolCallRecord]
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The text an inference step has produced so far, while it runs; the
    /// runner clears it when the step ends, so it never reaches history.
    public var streamed: String?
    /// How far a long step (a media job) has got, while it runs; cleared
    /// when the step ends, like `streamed`.
    public var progress: WorkflowNodeProgress?
    /// Where each item of a running map step stands, in item order. Live
    /// only: not saved with the run, and cleared when the step ends.
    public var mapItems: [MapItemState]?
    /// A hash of the node's definition and its rendered input when it ran,
    /// so a later "test from this step" can tell whether it would run the
    /// same way.
    public var specHash: String?
    /// For a pinned node: the earlier run whose output (and files) this run
    /// reused instead of running the step again.
    public var reusedFrom: UUID?

    public var id: String { nodeID }

    public var durationMs: Int? {
        guard let startedAt, let finishedAt else { return nil }
        return Int(finishedAt.timeIntervalSince(startedAt) * 1000)
    }

    public init(nodeID: String, status: NodeRunStatus = .pending) {
        self.nodeID = nodeID
        self.status = status
        self.attempts = 0
        self.logs = []
        self.fetches = []
        self.toolCalls = []
        self.toolCallRecords = []
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case status, input, output, error, failure, model, attempts
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case logs, fetches
        case toolCalls = "tool_calls"
        case toolCallRecords = "tool_call_records"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case streamed, progress
        case specHash = "spec_hash"
        case reusedFrom = "reused_from"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        status = try c.decode(NodeRunStatus.self, forKey: .status)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        failure = try? c.decodeIfPresent(NodeRunFailure.self, forKey: .failure)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        logs = try c.decodeIfPresent([String].self, forKey: .logs) ?? []
        fetches = try c.decodeIfPresent([String].self, forKey: .fetches) ?? []
        toolCalls = try c.decodeIfPresent([String].self, forKey: .toolCalls) ?? []
        toolCallRecords = try c.decodeIfPresent([WorkflowToolCallRecord].self, forKey: .toolCallRecords) ?? []
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        streamed = try c.decodeIfPresent(String.self, forKey: .streamed)
        progress = try c.decodeIfPresent(WorkflowNodeProgress.self, forKey: .progress)
        specHash = try c.decodeIfPresent(String.self, forKey: .specHash)
        reusedFrom = try c.decodeIfPresent(UUID.self, forKey: .reusedFrom)
    }
}

/// One item of a map step.
public enum MapItemState: String, Sendable, Equatable {
    case pending, running, done, failed
}

/// A running step's progress: a fraction when the work reports steps, and
/// what it is doing ("Image step 12 of 30 · ~8s left").
public struct WorkflowNodeProgress: Codable, Sendable, Equatable {
    public var fraction: Double?
    public var detail: String
    /// The latest preview a media step drew (PNG). Live only: not saved
    /// with the run.
    public var previewPNG: Data? = nil

    public init(fraction: Double?, detail: String, previewPNG: Data? = nil) {
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.detail = detail
        self.previewPNG = previewPNG
    }

    enum CodingKeys: String, CodingKey { case fraction, detail }
}

/// Who started a run. Shown on the run and in the workflow's history.
public struct WorkflowCaller: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// An agent's `workflow_<slug>` tool.
        case agent
        /// The Orchestrator's `run_workflow`.
        case orchestrator
        /// A workflow tab or the Workflows screen.
        case user
        /// An Architect test run on a draft.
        case test
        /// A `workflow` step of another workflow's run.
        case workflow
        /// An event (schedule, folder, webhook, channel message) fired.
        case event
    }

    public var kind: Kind
    public var agentID: UUID?
    public var agentName: String?
    public var sessionID: String?
    /// For `kind == .workflow`: the run whose step started this one.
    public var parentRunID: UUID?
    /// For `kind == .workflow`: the installed workflows up the chain,
    /// outermost first. Bounds nesting and refuses a workflow that would
    /// call itself.
    public var ancestors: [UUID]
    /// True when no window shows the run's forms inline (a Work Mode task
    /// or an external caller): dialogs park and post a notification.
    public var background: Bool
    /// The tool call that started the run, so its chat row can open it.
    public var toolCallID: String?
    /// The call came from outside the app (HTTP agent run, MCP bridge).
    public var isExternalSurface: Bool
    /// The owner's paired phone can answer approvals for the call.
    public var hasRemoteReviewer: Bool
    /// A schedule or watcher run nobody is watching.
    public var isUnattendedDispatch: Bool
    /// The person is there to answer a macOS permission dialog.
    public var isAttended: Bool {
        !isUnattendedDispatch && !isExternalSurface && !background && onBehalfOf == nil
            && kind != .event && kind != .test
    }
    /// The calling chat's working folder, when it had one. Tool nodes run
    /// file and shell tools there.
    public var folderPath: String?
    /// For `kind == .event`: the event that fired.
    public var eventID: UUID?
    /// For `kind == .event`: the event's name when it fired.
    public var eventName: String?
    /// The channel conversation the run was started from, when a message
    /// did. `reply` steps and relayed dialogs talk back to it.
    public var channelReply: WorkflowChannelReplyTarget?
    /// The task that owns this run when a scheduler admitted it (an
    /// automation's workflow). nil runs are recorded as their own task.
    public var taskId: UUID?
    /// The person or remote agent who asked for this run through one of
    /// this Mac's shared agents (a workspace teammate, a guest, or their
    /// agent). nil when the owner, an automation, or a channel started it.
    /// Survives `nested`, so a subworkflow step is attributed the same way.
    public var onBehalfOf: Participant?
    /// The workspace `onBehalfOf` reached the shared agent through. nil for
    /// guests and when `onBehalfOf` is nil.
    public var workspaceId: String?

    public init(
        kind: Kind, agentID: UUID? = nil, agentName: String? = nil, sessionID: String? = nil,
        background: Bool = false, toolCallID: String? = nil, isExternalSurface: Bool = false,
        hasRemoteReviewer: Bool = false, isUnattendedDispatch: Bool = false, folderPath: String? = nil,
        parentRunID: UUID? = nil, ancestors: [UUID] = [], eventID: UUID? = nil, eventName: String? = nil,
        channelReply: WorkflowChannelReplyTarget? = nil
    ) {
        self.channelReply = channelReply
        self.kind = kind
        self.agentID = agentID
        self.agentName = agentName
        self.sessionID = sessionID
        self.background = background
        self.toolCallID = toolCallID
        self.isExternalSurface = isExternalSurface
        self.hasRemoteReviewer = hasRemoteReviewer
        self.isUnattendedDispatch = isUnattendedDispatch
        self.folderPath = folderPath
        self.parentRunID = parentRunID
        self.ancestors = ancestors
        self.eventID = eventID
        self.eventName = eventName
    }

    /// The agent whose own keys and sessions the run uses. nil (shared
    /// keys, default sessions) when there is no agent or the agent is a
    /// built-in one: the Orchestrator and Architect run workflows globally.
    public var credentialAgentID: UUID? {
        guard let agentID, agentID != Agent.defaultId, agentID != Agent.architectId else { return nil }
        return agentID
    }

    /// The caller a `workflow` step of this run hands the workflow it
    /// starts: the same person, agent, and surfaces, one level deeper.
    public func nested(parentRunID: UUID, parentWorkflowID: UUID) -> WorkflowCaller {
        var child = self
        child.kind = .workflow
        child.toolCallID = nil
        child.taskId = nil
        child.parentRunID = parentRunID
        child.ancestors = ancestors + [parentWorkflowID]
        return child
    }

    /// No window can show an approval card or a form for this call.
    public var isHeadless: Bool { isExternalSurface && !hasRemoteReviewer }

    enum CodingKeys: String, CodingKey {
        case kind
        case agentID = "agent_id"
        case agentName = "agent_name"
        case sessionID = "session_id"
        case background
        case toolCallID = "tool_call_id"
        case isExternalSurface = "external_surface"
        case hasRemoteReviewer = "remote_reviewer"
        case isUnattendedDispatch = "unattended"
        case folderPath = "folder_path"
        case parentRunID = "parent_run_id"
        case ancestors
        case eventID = "event_id"
        case eventName = "event_name"
        case channelReply = "channel_reply"
        case taskId = "task_id"
        case onBehalfOf = "on_behalf_of"
        case workspaceId = "workspace_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        isExternalSurface = try c.decodeIfPresent(Bool.self, forKey: .isExternalSurface) ?? false
        hasRemoteReviewer = try c.decodeIfPresent(Bool.self, forKey: .hasRemoteReviewer) ?? false
        isUnattendedDispatch = try c.decodeIfPresent(Bool.self, forKey: .isUnattendedDispatch) ?? false
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        parentRunID = try c.decodeIfPresent(UUID.self, forKey: .parentRunID)
        ancestors = try c.decodeIfPresent([UUID].self, forKey: .ancestors) ?? []
        eventID = try c.decodeIfPresent(UUID.self, forKey: .eventID)
        eventName = try c.decodeIfPresent(String.self, forKey: .eventName)
        channelReply = try c.decodeIfPresent(WorkflowChannelReplyTarget.self, forKey: .channelReply)
        taskId = try c.decodeIfPresent(UUID.self, forKey: .taskId)
        onBehalfOf = try c.decodeIfPresent(Participant.self, forKey: .onBehalfOf)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        try c.encodeIfPresent(agentName, forKey: .agentName)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encode(background, forKey: .background)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encode(isExternalSurface, forKey: .isExternalSurface)
        try c.encode(hasRemoteReviewer, forKey: .hasRemoteReviewer)
        try c.encode(isUnattendedDispatch, forKey: .isUnattendedDispatch)
        try c.encodeIfPresent(folderPath, forKey: .folderPath)
        try c.encodeIfPresent(parentRunID, forKey: .parentRunID)
        if !ancestors.isEmpty { try c.encode(ancestors, forKey: .ancestors) }
        try c.encodeIfPresent(eventID, forKey: .eventID)
        try c.encodeIfPresent(eventName, forKey: .eventName)
        try c.encodeIfPresent(channelReply, forKey: .channelReply)
        try c.encodeIfPresent(taskId, forKey: .taskId)
        try c.encodeIfPresent(onBehalfOf, forKey: .onBehalfOf)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
    }
}

public struct WorkflowRunError: Codable, Sendable, Equatable {
    public var nodeID: String?
    public var reason: String
    public var attempts: Int?
    /// Schema path for input validation failures.
    public var path: String?
    /// The failed step's classification, when a step failed.
    public var failure: NodeRunFailure?

    public init(
        nodeID: String? = nil, reason: String, attempts: Int? = nil, path: String? = nil,
        failure: NodeRunFailure? = nil
    ) {
        self.nodeID = nodeID
        self.reason = reason
        self.attempts = attempts
        self.path = path
        self.failure = failure
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case reason, attempts, path, failure
    }
}

public struct WorkflowRun: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The installed workflow, or the draft id for test runs.
    public var workflowID: UUID
    public var workflowName: String
    public var templateID: UUID
    public var templateVersion: Int
    public var status: WorkflowRunStatus
    public var caller: WorkflowCaller
    public var input: JSONValue
    public var output: JSONValue?
    public var error: WorkflowRunError?
    public var nodes: [NodeRun]
    /// Files the run hands the person: shared by steps, then the output's
    /// file fields.
    public var artifacts: [WorkflowArtifact]
    /// Files its steps created or replaced on this Mac outside the run's
    /// workspace, in order.
    public var hostWrites: [WorkflowHostWrite] = []
    public var startedAt: Date
    public var finishedAt: Date?
    /// The failed run this one continues from its failed step, keeping
    /// the steps that had finished.
    public var retryOf: UUID?
    /// The run whose scratch workspace this run works in, when not its
    /// own: a retry keeps the files the finished steps wrote.
    public var workspaceRunID: UUID?
    /// Messages its `reply` steps (or those of runs it started) posted
    /// into the channel conversation. Kept with the record so the rule's
    /// final post and the per-run cap hold across a relaunch.
    public var channelReplyCount: Int = 0
    /// The agent a derived wrapper run handed its task to
    /// (`AgentWrapperCatalog`). Set only on wrapper runs.
    public var wrapperAgentID: UUID?
    /// A run of an Architect draft that was never saved (step 3 of
    /// workflow routing).
    public var ephemeral: Bool = false

    public var isTest: Bool { caller.kind == .test }

    /// Not a run of an installed workflow: a wrapper or an ephemeral draft.
    /// Kept out of workflow run history and the Architect's
    /// `workflow_runs`; the Tasks view still shows it.
    public var isDerived: Bool { wrapperAgentID != nil || ephemeral }

    public init(
        id: UUID = UUID(), workflowID: UUID, workflowName: String, templateID: UUID, templateVersion: Int,
        caller: WorkflowCaller, input: JSONValue, nodeIDs: [String], startedAt: Date = Date()
    ) {
        self.id = id
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.status = .running
        self.caller = caller
        self.input = input
        self.nodes = nodeIDs.map { NodeRun(nodeID: $0) }
        self.artifacts = []
        self.startedAt = startedAt
    }

    public func node(_ id: String) -> NodeRun? { nodes.first { $0.nodeID == id } }

    /// The failed step's classification: the run error's, else the step's.
    var primaryFailure: NodeRunFailure? {
        guard status == .failed else { return nil }
        let failedNode = error?.nodeID.flatMap(node) ?? nodes.first { $0.status == .failed }
        return error?.failure ?? failedNode?.failure
    }

    public mutating func update(_ id: String, _ change: (inout NodeRun) -> Void) {
        guard let index = nodes.firstIndex(where: { $0.nodeID == id }) else { return }
        change(&nodes[index])
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workflowID = "workflow_id"
        case workflowName = "workflow_name"
        case templateID = "template_id"
        case templateVersion = "template_version"
        case status, caller, input, output, error, nodes, artifacts
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case retryOf = "retry_of"
        case workspaceRunID = "workspace_run_id"
        case channelReplyCount = "channel_reply_count"
        case wrapperAgentID = "wrapper_agent_id"
        case ephemeral
        case hostWrites = "host_writes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workflowID = try c.decode(UUID.self, forKey: .workflowID)
        workflowName = try c.decode(String.self, forKey: .workflowName)
        templateID = try c.decode(UUID.self, forKey: .templateID)
        templateVersion = try c.decode(Int.self, forKey: .templateVersion)
        status = try c.decode(WorkflowRunStatus.self, forKey: .status)
        caller = try c.decode(WorkflowCaller.self, forKey: .caller)
        input = try c.decode(JSONValue.self, forKey: .input)
        output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
        error = try c.decodeIfPresent(WorkflowRunError.self, forKey: .error)
        nodes = try c.decode([NodeRun].self, forKey: .nodes)
        artifacts = try c.decodeIfPresent([WorkflowArtifact].self, forKey: .artifacts) ?? []
        hostWrites = try c.decodeIfPresent([WorkflowHostWrite].self, forKey: .hostWrites) ?? []
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        retryOf = try c.decodeIfPresent(UUID.self, forKey: .retryOf)
        workspaceRunID = try c.decodeIfPresent(UUID.self, forKey: .workspaceRunID)
        channelReplyCount = try c.decodeIfPresent(Int.self, forKey: .channelReplyCount) ?? 0
        wrapperAgentID = try c.decodeIfPresent(UUID.self, forKey: .wrapperAgentID)
        ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workflowID, forKey: .workflowID)
        try c.encode(workflowName, forKey: .workflowName)
        try c.encode(templateID, forKey: .templateID)
        try c.encode(templateVersion, forKey: .templateVersion)
        try c.encode(status, forKey: .status)
        try c.encode(caller, forKey: .caller)
        try c.encode(input, forKey: .input)
        try c.encodeIfPresent(output, forKey: .output)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(nodes, forKey: .nodes)
        if !artifacts.isEmpty { try c.encode(artifacts, forKey: .artifacts) }
        if !hostWrites.isEmpty { try c.encode(hostWrites, forKey: .hostWrites) }
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(retryOf, forKey: .retryOf)
        try c.encodeIfPresent(workspaceRunID, forKey: .workspaceRunID)
        if channelReplyCount > 0 { try c.encode(channelReplyCount, forKey: .channelReplyCount) }
        try c.encodeIfPresent(wrapperAgentID, forKey: .wrapperAgentID)
        if ephemeral { try c.encode(ephemeral, forKey: .ephemeral) }
    }
}

/// What a caller (tool, tab, Work Mode) receives.
public struct WorkflowCallResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case completed
        case failed
        case needsSetup = "needs_setup"
        case awaitingUser = "awaiting_user"
        case cancelled
    }

    public var status: Status
    public var output: JSONValue?
    public var runID: UUID?
    public var error: WorkflowRunError?
    /// Setup reasons when `status == .needsSetup`.
    public var reasons: [String]?
    /// Filenames the calling chat already shows as attachments.
    public var filesShown: [String]?
    /// Set up is blocked by a model slot that runs on nothing.
    public var noModel: Bool?

    public init(
        status: Status, output: JSONValue? = nil, runID: UUID? = nil, error: WorkflowRunError? = nil,
        reasons: [String]? = nil, filesShown: [String]? = nil, noModel: Bool? = nil
    ) {
        self.status = status
        self.output = output
        self.runID = runID
        self.error = error
        self.reasons = reasons
        self.filesShown = filesShown
        self.noModel = noModel
    }

    public init(run: WorkflowRun) {
        let status: Status
        switch run.status {
        case .completed: status = .completed
        case .failed, .running: status = .failed
        case .cancelled: status = .cancelled
        case .awaitingUser: status = .awaitingUser
        case .needsSetup: status = .needsSetup
        }
        let shown = WorkflowArtifactForwarder.forwardable(run).map(\.filename)
        self.init(
            status: status, output: run.output, runID: run.id, error: run.error,
            filesShown: shown.isEmpty ? nil : shown)
    }

    enum CodingKeys: String, CodingKey {
        case status, output
        case runID = "run_id"
        case error, reasons
        case filesShown = "files_shown"
        case noModel = "no_model"
    }

    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{\"status\":\"failed\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}
