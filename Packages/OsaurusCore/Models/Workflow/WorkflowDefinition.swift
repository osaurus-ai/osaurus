//
//  WorkflowDefinition.swift
//  osaurus
//
//  The payload of a workflow template: a directed acyclic graph of callable
//  nodes with a typed input and a typed output. Identity, version, author,
//  and requirements live on the `Template` envelope; this is only the graph.
//
//  JSON keys are snake_case to match the rest of the template format. The
//  Architect authors these through `workflow_draft` patch ops, so every
//  shape is a plain object with a string discriminator where needed.
//

import Foundation

public struct WorkflowDefinition: Codable, Equatable, Sendable {
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    /// How the workflow result is assembled from node outputs.
    public var output: WorkflowBinding
    /// Model slot declarations: preferred model, strictness, locality.
    /// Slots nodes use but never declare get defaults during derivation.
    public var modelSlots: [ModelRequirement]
    /// Secret labels and help text. Keys code nodes read but never declare
    /// still become requirements, labeled by key.
    public var secrets: [SecretRequirement]
    /// Designer notes on derived requirements, keyed by requirement id.
    public var requirementNotes: [String: String]
    /// Sample inputs that travel with the template, without secrets.
    public var examples: [WorkflowExample]
    /// Packages the shell steps need installed in the workflow's sandbox
    /// environment, one entry per package manager. Any entry makes the
    /// workflow's shell steps run in the sandbox.
    public var dependencies: [WorkflowDependency]
    /// Fixed folders the steps use, bound to a real folder on each Mac in
    /// the setup wizard and named in steps as `{{folders.<key>}}`.
    public var folders: [FolderRequirement]

    public init(
        inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])]),
        outputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])]),
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        output: WorkflowBinding = .object([:]),
        modelSlots: [ModelRequirement] = [],
        secrets: [SecretRequirement] = [],
        requirementNotes: [String: String] = [:],
        examples: [WorkflowExample] = [],
        dependencies: [WorkflowDependency] = [],
        folders: [FolderRequirement] = []
    ) {
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.nodes = nodes
        self.edges = edges
        self.output = output
        self.modelSlots = modelSlots
        self.secrets = secrets
        self.requirementNotes = requirementNotes
        self.examples = examples
        self.dependencies = dependencies
        self.folders = folders
    }

    enum CodingKeys: String, CodingKey {
        case nodes, edges, output, secrets, examples, dependencies, folders
        case inputSchema = "input_schema"
        case outputSchema = "output_schema"
        case modelSlots = "model_slots"
        case requirementNotes = "requirement_notes"
    }

    /// `dependencies` and `folders` are left out when empty so templates
    /// without any keep their content hash.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputSchema, forKey: .inputSchema)
        try c.encode(outputSchema, forKey: .outputSchema)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(edges, forKey: .edges)
        try c.encode(output, forKey: .output)
        try c.encode(modelSlots, forKey: .modelSlots)
        try c.encode(secrets, forKey: .secrets)
        try c.encode(requirementNotes, forKey: .requirementNotes)
        try c.encode(examples, forKey: .examples)
        if !dependencies.isEmpty { try c.encode(dependencies, forKey: .dependencies) }
        if !folders.isEmpty { try c.encode(folders, forKey: .folders) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .inputSchema) ?? .object([:])
        outputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .outputSchema) ?? .object([:])
        nodes = try c.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? []
        output = try c.decodeIfPresent(WorkflowBinding.self, forKey: .output) ?? .object([:])
        modelSlots = try c.decodeIfPresent([ModelRequirement].self, forKey: .modelSlots) ?? []
        secrets = try c.decodeIfPresent([SecretRequirement].self, forKey: .secrets) ?? []
        requirementNotes = try c.decodeIfPresent([String: String].self, forKey: .requirementNotes) ?? [:]
        examples = try c.decodeIfPresent([WorkflowExample].self, forKey: .examples) ?? []
        dependencies = try c.decodeIfPresent([WorkflowDependency].self, forKey: .dependencies) ?? []
        folders = try c.decodeIfPresent([FolderRequirement].self, forKey: .folders) ?? []
    }

    public func node(_ id: String) -> WorkflowNode? {
        nodes.first { $0.id == id }
    }

    /// Code nodes, for review screens that must show every script's source.
    public var codeNodes: [WorkflowNode] {
        nodes.filter { if case .code = $0.kind { return true } else { return false } }
    }

    /// Code nodes that run in the JavaScript helper (the rest run Python in
    /// the sandbox).
    public var javaScriptCodeNodes: [WorkflowNode] {
        codeNodes.filter { if case .code(let spec) = $0.kind { return spec.language == .javascript } else { return false } }
    }

    /// Steps that run Python, including map bodies.
    public var hasPythonNodes: Bool { nodes.contains(where: \.runsPython) }

    /// Steps that run in the workflow's sandbox: Python and shell steps.
    public var hasSandboxSteps: Bool { nodes.contains(where: \.needsSandbox) }

    public var hasPlaceholders: Bool { nodes.contains { $0.kind == nil } }

    /// The output schemas the model bound to `slot` must enforce: one per
    /// inference node that uses the slot.
    public func outputSchemas(forSlot slot: String) -> [JSONValue] {
        nodes.compactMap { node in
            guard case .inference(let spec) = node.kind, spec.modelSlot == slot else { return nil }
            return node.effectiveOutputSchema
        }
    }

    /// Every tool the workflow calls, first use first, one per name.
    public var calledTools: [ToolRef] {
        var seen = Set<String>()
        return nodes.flatMap(\.calledTools).filter { seen.insert($0.name).inserted }
    }

    /// Tools that every step calling them runs as a named agent (`tool.agent`).
    public var agentKeyedToolNames: Set<String> {
        let refs = nodes.flatMap(\.calledTools)
        let unkeyed = Set(refs.filter { $0.agent == nil }.map(\.name))
        return Set(refs.filter { $0.agent != nil }.map(\.name)).subtracting(unkeyed)
    }

    /// The tool steps that name an agent, with the agent they name.
    public var agentKeyedToolCalls: [(tool: String, agent: String)] {
        nodes.flatMap(\.calledTools).compactMap { ref in ref.agent.map { (ref.name, $0) } }
    }

    /// Whether the workflow's shell and Python steps run in its sandbox
    /// environment: when it declares dependencies or has a shell or Python
    /// step.
    public var usesSandbox: Bool { !dependencies.isEmpty || hasSandboxSteps }

    /// Steps that run other installed workflows, by the name they give.
    public var subworkflowNames: [String] { subworkflowCalls.map(\.workflow) }

    /// Each other workflow a step runs, once, with the first step that
    /// calls it.
    public var subworkflowCalls: [(workflow: String, step: String)] {
        var seen = Set<String>()
        return nodes.compactMap { node -> (workflow: String, step: String)? in
            switch node.kind {
            case .workflow(let spec): return (spec.workflow, node.name)
            case .map(let spec):
                if case .workflow(let inner) = spec.body(parentID: node.id).kind { return (inner.workflow, node.name) }
                return nil
            default: return nil
            }
        }.filter { seen.insert($0.workflow.lowercased()).inserted }
    }

    /// Whether the graph uses anything the first template format did not
    /// have: the `http`, `wait`, `map`, `workflow`, `state`, `reply`, and
    /// `media` steps, Python code steps, `on_error` other than fail, `join`,
    /// bypassed steps, error and
    /// always edges, condition groups, and the comparison ops beyond
    /// equals / not_equals / in / exists. A template that uses one of
    /// these is written as format 2 or later so an older Osaurus refuses it with
    /// "update to import" instead of mis-reading it (an old decoder would
    /// drop `on_error` and `on`, run Python as JavaScript, and fail on the
    /// new ops with a parse error).
    public var usesPostV1Features: Bool {
        nodes.contains(where: Self.nodeUsesPostV1Features)
            || edges.contains { edge in edge.on != .success || (edge.when.map(Self.conditionUsesPostV1Features) ?? false) }
    }

    /// Whether the graph uses a format-3 feature: the `media` step or a
    /// bypassed step, in the graph or a map step's body. Format 2 shipped
    /// without them, so a format-2 build would pass the version check and
    /// then fail on `media` or quietly run a bypassed step.
    public var usesFormat3Features: Bool { nodes.contains(where: Self.nodeUsesFormat3Features) }

    /// Whether the graph has an `agent` step (format 4). Format 3 shipped
    /// without it, so a format-3 build would fail on the unknown kind.
    public var usesFormat4Features: Bool { nodes.contains { if case .agent = $0.kind { true } else { false } } }

    /// Whether a tool step runs as a named agent (format 5). Format 4 would
    /// drop `tool.agent` and run the step under the workflow's own grants.
    public var usesFormat5Features: Bool { !agentKeyedToolCalls.isEmpty }

    /// The lowest template format that can carry this graph.
    public var requiredFormatVersion: Int {
        usesFormat5Features
            ? 5 : usesFormat4Features ? 4 : usesFormat3Features ? 3 : usesPostV1Features ? 2 : 1
    }

    /// The agents this workflow's agent steps hand work to, in step order.
    public var agentCalls: [(requirement: AgentRequirement, step: String)] {
        var out: [(requirement: AgentRequirement, step: String)] = []
        for node in nodes {
            guard case .agent(let spec) = node.kind else { continue }
            let req = spec.requirement
            if !out.contains(where: { $0.requirement.id == req.id }) { out.append((req, node.id)) }
        }
        return out
    }

    static func nodeUsesFormat3Features(_ node: WorkflowNode) -> Bool {
        if node.mode != .always { return true }
        switch node.kind {
        case .media?: return true
        case .map(let spec)?: return nodeUsesFormat3Features(spec.body(parentID: node.id))
        default: return false
        }
    }

    static func nodeUsesPostV1Features(_ node: WorkflowNode) -> Bool {
        if node.onError != .fail || node.join != .any { return true }
        if node.mode != .always { return true }
        switch node.kind {
        case .inference?, .dialog?, .tool?, nil: return false
        case .code(let spec)?: return spec.language != .javascript
        case .http?, .wait?, .map?, .workflow?, .state?, .reply?, .media?, .agent?: return true
        }
    }

    static let v1ConditionOps: Set<WorkflowCondition.Op> = [.equals, .notEquals, .in, .exists]

    static func conditionUsesPostV1Features(_ condition: WorkflowCondition) -> Bool {
        if condition.isGroup { return true }
        return !v1ConditionOps.contains(condition.op)
    }

    /// Whether a step (or a map step's body) posts into the triggering
    /// conversation itself.
    public var hasReplyStep: Bool {
        nodes.contains { node in
            if case .reply = node.kind { return true }
            if case .reply = node.mapBody?.kind { return true }
            return false
        }
    }

    /// Tool nodes that run a shell command, with the command text when it
    /// is a literal or template string. A map step whose body runs one is
    /// listed as the map step.
    public var shellSteps: [(node: WorkflowNode, command: String?)] {
        nodes.compactMap { node in
            let step = node.mapBody ?? node
            guard case .tool(let spec)? = step.kind, spec.tool.name == "shell_run" else { return nil }
            return (node, step.input.fieldTemplates?["command"])
        }
    }
}

public struct WorkflowExample: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var input: JSONValue
    public var id: String { name }

    public init(name: String, input: JSONValue) {
        self.name = name
        self.input = input
    }
}

// MARK: - Node

public struct WorkflowNode: Codable, Equatable, Sendable, Identifiable {
    /// Stable slug, e.g. "classify". Bindings reference nodes by this id.
    public let id: String
    public var name: String
    /// One-line intent. Planned placeholder nodes carry only this.
    public var intent: String?
    /// nil while the node is a planned placeholder in a draft. A saved
    /// template never has one: validation rejects placeholders.
    public var kind: NodeKind?
    public var input: WorkflowBinding
    public var outputSchema: JSONValue
    public var timeout: TimeInterval
    public var retry: RetryPolicy
    /// What the run does when this node fails for good (after retries).
    public var onError: NodeErrorPolicy
    /// How a node with several incoming edges decides it may run.
    public var join: NodeJoin
    /// Whether the node runs or hands its input straight on.
    public var mode: NodeMode

    public static let defaultTimeout: TimeInterval = 120
    /// Dialogs wait on a person, who may answer from another device later.
    public static let defaultDialogTimeout: TimeInterval = 24 * 60 * 60
    /// Sub-workflows and fan-outs do many steps' worth of work.
    public static let defaultCompositeTimeout: TimeInterval = 60 * 60
    /// A reply is one post into a conversation.
    public static let defaultReplyTimeout: TimeInterval = 60
    /// A first image load plus a batch of large images, or a queued video.
    public static let defaultMediaTimeout: TimeInterval = 30 * 60
    public init(
        id: String,
        name: String,
        intent: String? = nil,
        kind: NodeKind?,
        input: WorkflowBinding = .object([:]),
        outputSchema: JSONValue = .object(["type": .string("object")]),
        timeout: TimeInterval? = nil,
        retry: RetryPolicy = RetryPolicy(),
        onError: NodeErrorPolicy = .fail,
        join: NodeJoin = .any,
        mode: NodeMode = .always
    ) {
        self.mode = mode
        self.id = id
        self.name = name
        self.intent = intent
        self.kind = kind
        self.input = input
        self.outputSchema = outputSchema
        self.timeout = timeout ?? Self.defaultTimeout(forKind: kind.map { Self.kindName(of: $0) })
        self.retry = retry
        self.onError = onError
        self.join = join
    }

    enum CodingKeys: String, CodingKey {
        case id, name, intent, kind, input, timeout, retry, join, mode
        case inference, dialog, code, tool, wait, map, workflow, http, state, reply, media, agent
        case outputSchema = "output_schema"
        case onError = "on_error"
    }

    /// The node kind names the format accepts, in documentation order.
    public static let kindNames = [
        "inference", "dialog", "code", "tool", "http", "wait", "map", "workflow", "state", "reply", "media",
        "agent",
    ]

    /// The default timeout for a node of `kindName`.
    public static func defaultTimeout(forKind kindName: String?) -> TimeInterval {
        switch kindName {
        case "dialog": return defaultDialogTimeout
        case "map", "workflow", "agent": return defaultCompositeTimeout
        // The deadline is only a backstop for a wait; the wait itself is
        // bounded by `WaitSpec.maximumSeconds`.
        case "wait": return WaitSpec.maximumSeconds + 60
        case "reply": return defaultReplyTimeout
        case "media": return defaultMediaTimeout
        default: return defaultTimeout
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        input = try c.decodeIfPresent(WorkflowBinding.self, forKey: .input) ?? .object([:])
        outputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .outputSchema) ?? .object([:])
        retry = try c.decodeIfPresent(RetryPolicy.self, forKey: .retry) ?? RetryPolicy()
        onError = try c.decodeIfPresent(NodeErrorPolicy.self, forKey: .onError) ?? .fail
        join = try c.decodeIfPresent(NodeJoin.self, forKey: .join) ?? .any
        mode = try c.decodeIfPresent(NodeMode.self, forKey: .mode) ?? .always
        let kindName = try c.decodeIfPresent(String.self, forKey: .kind)
        switch kindName {
        case nil, "placeholder":
            kind = nil
        case "inference":
            kind = .inference(try c.decode(InferenceSpec.self, forKey: .inference))
        case "dialog":
            kind = .dialog(try c.decode(DialogSpec.self, forKey: .dialog))
        case "code":
            kind = .code(try c.decode(CodeSpec.self, forKey: .code))
        case "tool":
            kind = .tool(try c.decode(ToolNodeSpec.self, forKey: .tool))
        case "http":
            kind = .http(try c.decode(HTTPSpec.self, forKey: .http))
        case "wait":
            kind = .wait(try c.decode(WaitSpec.self, forKey: .wait))
        case "map":
            kind = .map(try c.decode(MapSpec.self, forKey: .map))
        case "workflow":
            kind = .workflow(try c.decode(SubworkflowSpec.self, forKey: .workflow))
        case "state":
            kind = .state(try c.decode(StateSpec.self, forKey: .state))
        case "reply":
            kind = .reply(try c.decode(ReplySpec.self, forKey: .reply))
        case "media":
            kind = .media(try c.decode(MediaSpec.self, forKey: .media))
        case "agent":
            kind = .agent(try c.decode(AgentNodeSpec.self, forKey: .agent))
        case let other?:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription:
                    "Unknown node kind `\(other)`. Use one of \(Self.kindNames.joined(separator: ", ")).")
        }
        timeout =
            try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? Self.defaultTimeout(forKind: kindName)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(intent, forKey: .intent)
        try c.encode(input, forKey: .input)
        try c.encode(outputSchema, forKey: .outputSchema)
        try c.encode(timeout, forKey: .timeout)
        try c.encode(retry, forKey: .retry)
        // Defaults are left out so templates written before these fields
        // existed keep their content hash.
        if onError != .fail { try c.encode(onError, forKey: .onError) }
        if join != .any { try c.encode(join, forKey: .join) }
        if mode != .always { try c.encode(mode, forKey: .mode) }
        switch kind {
        case nil:
            try c.encode("placeholder", forKey: .kind)
        case .inference(let spec):
            try c.encode("inference", forKey: .kind)
            try c.encode(spec, forKey: .inference)
        case .dialog(let spec):
            try c.encode("dialog", forKey: .kind)
            try c.encode(spec, forKey: .dialog)
        case .code(let spec):
            try c.encode("code", forKey: .kind)
            try c.encode(spec, forKey: .code)
        case .tool(let spec):
            try c.encode("tool", forKey: .kind)
            try c.encode(spec, forKey: .tool)
        case .http(let spec):
            try c.encode("http", forKey: .kind)
            try c.encode(spec, forKey: .http)
        case .wait(let spec):
            try c.encode("wait", forKey: .kind)
            try c.encode(spec, forKey: .wait)
        case .map(let spec):
            try c.encode("map", forKey: .kind)
            try c.encode(spec, forKey: .map)
        case .workflow(let spec):
            try c.encode("workflow", forKey: .kind)
            try c.encode(spec, forKey: .workflow)
        case .state(let spec):
            try c.encode("state", forKey: .kind)
            try c.encode(spec, forKey: .state)
        case .reply(let spec):
            try c.encode("reply", forKey: .kind)
            try c.encode(spec, forKey: .reply)
        case .media(let spec):
            try c.encode("media", forKey: .kind)
            try c.encode(spec, forKey: .media)
        case .agent(let spec):
            try c.encode("agent", forKey: .kind)
            try c.encode(spec, forKey: .agent)
        }
    }

    public var kindName: String { kind.map(Self.kindName(of:)) ?? "placeholder" }

    public static func kindName(of kind: NodeKind) -> String {
        switch kind {
        case .inference: return "inference"
        case .dialog: return "dialog"
        case .code: return "code"
        case .tool: return "tool"
        case .http: return "http"
        case .wait: return "wait"
        case .map: return "map"
        case .workflow: return "workflow"
        case .state: return "state"
        case .reply: return "reply"
        case .media: return "media"
        case .agent: return "agent"
        }
    }

    /// The schema this node's output is validated against. A dialog with no
    /// explicit schema returns exactly its fields.
    public var effectiveOutputSchema: JSONValue {
        if case .dialog(let spec) = kind, outputSchema.isEmptySchema {
            return spec.derivedOutputSchema
        }
        if case .inference(let spec) = kind, case .decide(let options) = spec.mode {
            return InferenceSpec.decideSchema(options: options)
        }
        // A tool result may be any JSON value, not only an object.
        if case .tool = kind, outputSchema.isEmptySchema { return .object([:]) }
        if case .wait = kind, outputSchema.isEmptySchema { return WaitSpec.outputSchema }
        if case .map = kind, outputSchema.isEmptySchema { return MapSpec.outputSchema }
        if case .http = kind, outputSchema.isEmptySchema { return HTTPSpec.outputSchema }
        // A sub-workflow's output is validated by that workflow's own schema.
        if case .workflow = kind, outputSchema.isEmptySchema { return .object([:]) }
        if case .state(let spec) = kind, outputSchema.isEmptySchema { return spec.outputSchema }
        if case .reply = kind, outputSchema.isEmptySchema { return ReplySpec.outputSchema }
        if case .media = kind, outputSchema.isEmptySchema { return MediaSpec.outputSchema }
        if case .agent = kind, outputSchema.isEmptySchema { return AgentNodeSpec.outputSchema }
        return outputSchema
    }

    /// The node a `map` step runs once per item, named for the run log.
    public var mapBody: WorkflowNode? {
        guard case .map(let spec) = kind else { return nil }
        return spec.body(parentID: id)
    }

    /// `effectiveOutputSchema`, with a tool node's empty schema replaced by
    /// the schema its tool declares (`toolOutputSchema`), when it has one.
    public func effectiveOutputSchema(toolOutputSchema: JSONValue?) -> JSONValue {
        if case .tool = kind, outputSchema.isEmptySchema, let declared = toolOutputSchema, !declared.isEmptySchema {
            return declared
        }
        return effectiveOutputSchema
    }

    /// The tool a tool node calls.
    public var toolRef: ToolRef? {
        if case .tool(let spec) = kind { return spec.tool }
        return nil
    }

    /// The tools this node calls: a tool node's tool, an agentic node's
    /// tools, and whatever a map step's body calls.
    public var calledTools: [ToolRef] {
        switch kind {
        case .tool(let spec): return [spec.tool]
        case .inference(let spec):
            if case .agentic(let tools, _) = spec.mode { return tools }
            return []
        case .map(let spec): return spec.body(parentID: id).calledTools
        case .code(let spec):
            // Python steps run through the shell tool in the sandbox.
            return spec.language == .python ? [ToolRef(name: "shell_run")] : []
        case .http, .wait, .workflow, .dialog, .state, .reply, .media, .agent, nil: return []
        }
    }

    /// Whether the node's work runs in the workflow's sandbox environment:
    /// Python steps, and any step that runs shell commands (a `shell_run`
    /// tool step, or an agentic step that may call it). A shell command
    /// from a workflow never runs on this Mac directly.
    public var needsSandbox: Bool {
        switch kind {
        case .code(let spec): return spec.language == .python
        case .tool(let spec): return spec.tool.isBuiltinShell
        case .inference(let spec):
            if case .agentic(let tools, _) = spec.mode { return tools.contains(where: \.isBuiltinShell) }
            return false
        case .map(let spec): return spec.body(parentID: id).needsSandbox
        default: return false
        }
    }

    /// Whether the node runs Python, including a map step's body.
    public var runsPython: Bool {
        switch kind {
        case .code(let spec): return spec.language == .python
        case .map(let spec): return spec.body(parentID: id).runsPython
        default: return false
        }
    }
}

public enum NodeKind: Equatable, Sendable {
    case inference(InferenceSpec)
    case dialog(DialogSpec)
    case code(CodeSpec)
    /// One call to an agent tool. The node's `input` is the tool's arguments
    /// and its output is the tool's `result`.
    case tool(ToolNodeSpec)
    /// One HTTP request, declared rather than coded: method, URL, headers,
    /// body, and the secret that authenticates it.
    case http(HTTPSpec)
    /// Pauses the run for a duration or until a moment.
    case wait(WaitSpec)
    /// Runs one step once per item of a list, with bounded concurrency.
    case map(MapSpec)
    /// Runs another installed workflow and takes its output.
    case workflow(SubworkflowSpec)
    /// Reads or writes the workflow's own stored data: values and tables
    /// that persist from run to run (counters, seen ids, caches).
    case state(StateSpec)
    /// Posts a message (and optionally a file) into the channel
    /// conversation that started the run.
    case reply(ReplySpec)
    /// Makes images (generate, edit, upscale) with an image model on this
    /// Mac, or a video with a connected provider.
    case media(MediaSpec)
    /// Hands one task to another agent (this Mac's, or a teammate's shared
    /// in a workspace) and takes its answer.
    case agent(AgentNodeSpec)
}

/// What a run does when a node fails after its last attempt.
public enum NodeErrorPolicy: String, Codable, Sendable, CaseIterable {
    /// Fail the run (the default).
    case fail
    /// Record the failure, bind the node's output as `{error: {...}}`, and
    /// go on: edges with `on: "error"` or `on: "always"` from it pass.
    case `continue`
    /// Treat the node as skipped: its output binds as null and only
    /// `on: "always"` edges from it pass.
    case skip
}

/// How a node with several incoming edges decides it may run.
public enum NodeJoin: String, Codable, Sendable, CaseIterable {
    /// Runs once every predecessor resolved and at least one edge passed.
    case any
    /// Runs only when every incoming edge passed; otherwise it is skipped.
    case all
}

// MARK: - Wait

public struct WaitSpec: Codable, Equatable, Sendable {
    /// Seconds to pause. A template string is rendered first.
    public var seconds: String?
    /// ISO 8601 moment to resume at. A template string is rendered first.
    public var until: String?

    public init(seconds: String? = nil, until: String? = nil) {
        self.seconds = seconds
        self.until = until
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Double.self, forKey: .seconds) {
            seconds = BindingRenderer.textValue(.number(n))
        } else {
            seconds = try c.decodeIfPresent(String.self, forKey: .seconds)
        }
        until = try c.decodeIfPresent(String.self, forKey: .until)
    }

    enum CodingKeys: String, CodingKey { case seconds, until }

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "waited_seconds": .object(["type": .string("number")]),
            "resumed_at": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("waited_seconds"), .string("resumed_at")]),
    ])

    /// The longest a single wait may be.
    public static let maximumSeconds: Double = 30 * 24 * 60 * 60
}

// MARK: - State

/// One operation on the workflow's stored data. Data is scoped to the
/// installed workflow (a draft's tests have their own) and organized in
/// named tables of key → value rows; `vars` is the default table.
public struct StateSpec: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        /// `{exists, value, updated_at}` for `key`.
        case get
        /// Stores `value` (rendered; a single reference keeps its type) under `key`.
        case set
        /// Adds `by` (default 1) to the number under `key`, starting from 0.
        case increment
        /// Removes `key`; `{deleted}`.
        case delete
        /// Rows of the table, most recently written first; `{rows, count}`.
        case list
        /// Removes every row of the table; `{count}`.
        case clear
    }

    public var action: Action
    /// Table name. A template string is rendered first. Default `vars`.
    public var table: String?
    /// Row key, for get/set/increment/delete. A template string is rendered first.
    public var key: String?
    /// For set: the value to store. Rendered; `{{…}}` alone keeps the referenced type.
    public var value: String?
    /// For increment: the amount. Rendered; default 1.
    public var by: String?
    /// For list: rows to return (default 100, at most `maximumListLimit`).
    public var limit: Int?

    public init(action: Action, table: String? = nil, key: String? = nil, value: String? = nil, by: String? = nil, limit: Int? = nil) {
        self.action = action
        self.table = table
        self.key = key
        self.value = value
        self.by = by
        self.limit = limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(Action.self, forKey: .action)
        table = try c.decodeIfPresent(String.self, forKey: .table)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        // A literal number or bool is a fine value too.
        if let text = try? c.decode(String.self, forKey: .value) {
            value = text
        } else if let raw = try c.decodeIfPresent(JSONValue.self, forKey: .value) {
            value = raw.compactJSONString
        }
        if let n = try? c.decode(Double.self, forKey: .by) {
            by = BindingRenderer.textValue(.number(n))
        } else {
            by = try c.decodeIfPresent(String.self, forKey: .by)
        }
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    }

    enum CodingKeys: String, CodingKey { case action, table, key, value, by, limit }

    public static let defaultTable = "vars"
    public static let defaultListLimit = 100
    public static let maximumListLimit = 1000

    /// What the step returns, by action.
    public var outputSchema: JSONValue {
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ])
        }
        let time: JSONValue = .object(["type": .array([.string("string"), .string("null")])])
        switch action {
        case .get:
            return object(["exists": .object(["type": .string("boolean")]), "value": .object([:]), "updated_at": time], required: ["exists"])
        case .set:
            return object(["value": .object([:]), "updated_at": .object(["type": .string("string")])], required: ["updated_at"])
        case .increment:
            return object(["value": .object(["type": .string("number")])], required: ["value"])
        case .delete:
            return object(["deleted": .object(["type": .string("boolean")])], required: ["deleted"])
        case .list:
            return object(
                [
                    "rows": .object([
                        "type": .string("array"),
                        "items": object(
                            ["key": .object(["type": .string("string")]), "value": .object([:]), "updated_at": .object(["type": .string("string")])],
                            required: ["key", "updated_at"]),
                    ]),
                    "count": .object(["type": .string("number")]),
                ], required: ["rows", "count"])
        case .clear:
            return object(["count": .object(["type": .string("number")])], required: ["count"])
        }
    }
}

// MARK: - Reply

/// One message into the conversation that started the run (a channel
/// message). A run nobody messaged — from a tab, an agent, a schedule —
/// has no conversation: the step reports `sent: false` and the run goes on.
public struct ReplySpec: Codable, Equatable, Sendable {
    /// The message. A template string is rendered first.
    public var text: String
    /// A file to send with it: a path inside the run's folders, or a
    /// binding to one. Only channels that take files send it.
    public var file: String?
    /// The file's caption. A template string is rendered first.
    public var caption: String?

    public init(text: String = "", file: String? = nil, caption: String? = nil) {
        self.text = text
        self.file = file
        self.caption = caption
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(caption, forKey: .caption)
    }

    enum CodingKeys: String, CodingKey { case text, file, caption }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasFile: Bool { !(file ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Messages one run (with the runs it starts) may post into its
    /// conversation; past it a reply is `sent: false, reason: reply_cap`.
    public static let maximumRepliesPerRun = 20

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "sent": .object(["type": .string("boolean")]),
            "platform": .object(["type": .array([.string("string"), .string("null")])]),
            "room_id": .object(["type": .array([.string("string"), .string("null")])]),
            "thread_id": .object(["type": .array([.string("string"), .string("null")])]),
            "attachment_sent": .object(["type": .string("boolean")]),
            "truncated": .object(["type": .string("boolean")]),
            "reason": .object(["type": .array([.string("string"), .string("null")])]),
        ]),
        "required": .array([.string("sent")]),
    ])
}

// MARK: - Map

public struct MapSpec: Codable, Equatable, Sendable {
    /// What the run does when one item's step fails.
    public enum ItemErrorPolicy: String, Codable, Sendable, CaseIterable {
        /// Stop the fan-out and fail the map node.
        case fail
        /// Leave the item out of `items` and list it under `failed`.
        case skip
    }

    /// Binding resolving to the list to iterate.
    public var items: String
    /// The step run once per item, as a node JSON object without `id`.
    /// Its `input`, instructions, and messages may use `{{item}}`,
    /// `{{item.field}}`, and `{{index}}`.
    public var step: JSONValue
    /// Items worked on at the same time.
    public var concurrency: Int
    public var onItemError: ItemErrorPolicy

    public static let defaultConcurrency = 4
    public static let maximumConcurrency = 16
    /// The most items one map step may fan out to.
    public static let maximumItems = 1_000

    public init(items: String, step: JSONValue, concurrency: Int = MapSpec.defaultConcurrency, onItemError: ItemErrorPolicy = .fail) {
        self.items = items
        self.step = step
        self.concurrency = max(1, concurrency)
        self.onItemError = onItemError
    }

    enum CodingKeys: String, CodingKey {
        case items, step, concurrency
        case onItemError = "on_item_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode(String.self, forKey: .items)
        step = try c.decodeIfPresent(JSONValue.self, forKey: .step) ?? .object([:])
        concurrency = max(1, try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? Self.defaultConcurrency)
        onItemError = try c.decodeIfPresent(ItemErrorPolicy.self, forKey: .onItemError) ?? .fail
    }

    /// Items that actually run at once. A media body runs one item at a time:
    /// each image job swaps the chat model out and back, and overlapping
    /// swaps unload and reload it repeatedly.
    public func effectiveConcurrency(body: WorkflowNode) -> Int {
        if case .media? = body.kind, body.mode == .always { return 1 }
        return concurrency
    }

    /// The body as a node. Its id is derived from the parent's so run
    /// records and logs name it (`<parent>.item`).
    public func body(parentID: String) -> WorkflowNode {
        var object = step.objectValue ?? [:]
        object["id"] = .string(parentID + ".item")
        if object["name"] == nil { object["name"] = .string("Item of \(parentID)") }
        if let data = try? JSONEncoder().encode(JSONValue.object(object)),
            let node = try? JSONDecoder().decode(WorkflowNode.self, from: data)
        {
            return node
        }
        // An unreadable step shows as a placeholder; validation names the problem.
        return WorkflowNode(id: parentID + ".item", name: "Item of \(parentID)", kind: nil)
    }

    /// Why `step` cannot be decoded as a node, when it cannot.
    public func stepDecodingIssue() -> String? {
        var object = step.objectValue ?? [:]
        guard !object.isEmpty else { return "map needs a `step` object: the node to run for each item" }
        object["id"] = .string("item")
        do {
            _ = try JSONDecoder().decode(WorkflowNode.self, from: try JSONEncoder().encode(JSONValue.object(object)))
            return nil
        } catch let DecodingError.dataCorrupted(ctx) {
            return "map step: \(ctx.debugDescription)"
        } catch let DecodingError.keyNotFound(key, _) {
            return "map step is missing `\(key.stringValue)`"
        } catch {
            return "map step is invalid: \(error.localizedDescription)"
        }
    }

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "items": .object(["type": .string("array")]),
            "count": .object(["type": .string("integer")]),
            "failed": .object(["type": .string("array")]),
        ]),
        "required": .array([.string("items"), .string("count"), .string("failed")]),
    ])
}

// MARK: - Sub-workflow

public struct SubworkflowSpec: Codable, Equatable, Sendable {
    /// The installed workflow's name (as shown in Main window → Workflows) or
    /// its tool slug (`workflow_<slug>`), either form.
    public var workflow: String

    public init(workflow: String) {
        self.workflow = workflow
    }

    /// Accepts `{workflow: "..."}` or a bare name.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            workflow = name
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workflow = try c.decodeIfPresent(String.self, forKey: .workflow) ?? c.decode(String.self, forKey: .name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workflow, forKey: .workflow)
    }

    enum CodingKeys: String, CodingKey { case workflow, name }

    /// How deep workflows may call workflows.
    public static let maximumDepth = 8
}

// MARK: - HTTP

public struct HTTPSpec: Codable, Equatable, Sendable {
    public var method: String
    /// Template string; bindings render before the request.
    public var url: String
    /// Header name -> template string.
    public var headers: [String: String]
    /// Query parameter name -> template string, appended to `url` and
    /// percent-encoded. Spares the author encoding values into the URL.
    public var query: [String: String]
    /// Request body: a template string, or an object of template strings
    /// sent as JSON. Nil sends no body.
    public var body: WorkflowBinding?
    /// How the request authenticates, from a declared secret.
    public var auth: HTTPAuth?
    /// Hosts the request may reach. Derived from `url` when it names a
    /// literal host; required when the host is bound.
    public var allowedHosts: [String]
    /// Response handling: `json` parses the body as JSON (the default),
    /// `text` keeps it as text.
    public var response: ResponseMode
    /// Non-2xx statuses fail the node unless this is false.
    public var failOnError: Bool
    /// Follow the API's pages and merge their items; nil makes one request.
    public var paginate: HTTPPagination?

    public enum ResponseMode: String, Codable, Sendable { case json, text }

    public static let defaultMethod = "GET"

    public init(
        method: String = HTTPSpec.defaultMethod, url: String, headers: [String: String] = [:],
        query: [String: String] = [:], body: WorkflowBinding? = nil, auth: HTTPAuth? = nil,
        allowedHosts: [String] = [], response: ResponseMode = .json, failOnError: Bool = true,
        paginate: HTTPPagination? = nil
    ) {
        self.method = method.uppercased()
        self.url = url
        self.headers = headers
        self.query = query
        self.body = body
        self.auth = auth
        self.allowedHosts = allowedHosts
        self.response = response
        self.failOnError = failOnError
        self.paginate = paginate
    }

    enum CodingKeys: String, CodingKey {
        case method, url, headers, query, body, auth, response, paginate
        case allowedHosts = "allowed_hosts"
        case failOnError = "fail_on_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = (try c.decodeIfPresent(String.self, forKey: .method) ?? Self.defaultMethod).uppercased()
        url = try c.decode(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        query = try c.decodeIfPresent([String: String].self, forKey: .query) ?? [:]
        body = try c.decodeIfPresent(WorkflowBinding.self, forKey: .body)
        auth = try c.decodeIfPresent(HTTPAuth.self, forKey: .auth)
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        response = try c.decodeIfPresent(ResponseMode.self, forKey: .response) ?? .json
        failOnError = try c.decodeIfPresent(Bool.self, forKey: .failOnError) ?? true
        paginate = try c.decodeIfPresent(HTTPPagination.self, forKey: .paginate)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        try c.encode(url, forKey: .url)
        if !headers.isEmpty { try c.encode(headers, forKey: .headers) }
        if !query.isEmpty { try c.encode(query, forKey: .query) }
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(auth, forKey: .auth)
        if !allowedHosts.isEmpty { try c.encode(allowedHosts, forKey: .allowedHosts) }
        if response != .json { try c.encode(response, forKey: .response) }
        if !failOnError { try c.encode(failOnError, forKey: .failOnError) }
        try c.encodeIfPresent(paginate, forKey: .paginate)
    }

    /// The host written literally in `url`, when there is one.
    public var literalHost: String? {
        let host = Self.hostPart(url)
        guard !host.isEmpty, !host.contains("{{") else { return nil }
        return host.lowercased()
    }

    static func hostPart(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return "" }
        let rest = url[schemeEnd.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var host = String(rest[..<end])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }

    /// Hosts the step may reach: the literal host plus `allowed_hosts`.
    public var hosts: [String] {
        var out: [String] = []
        if let literalHost { out.append(literalHost) }
        for host in allowedHosts.map({ $0.lowercased() }) where !out.contains(host) { out.append(host) }
        return out
    }

    /// The secret keys the request reads.
    public var secretKeys: [String] {
        guard let auth else { return [] }
        switch auth {
        case .bearer(let key), .connection(let key), .header(_, let key), .query(_, let key): return [key]
        case .basic(let user, let password): return [user, password].filter { !$0.isEmpty }
        }
    }

    /// Request headers that carry credentials. The validator refuses
    /// them in `headers` so the value has to come through `auth`, which
    /// reads a declared secret: the template never holds the value and
    /// the runner knows to scrub it from run records.
    public static let credentialHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "x-api-key", "api-key", "apikey", "x-auth-token",
        "x-access-token", "x-amz-security-token", "x-goog-api-key", "x-vault-token",
    ]

    /// Response headers dropped from the step's output: they carry
    /// session credentials, not data the next step needs.
    public static let droppedResponseHeaders: Set<String> = ["set-cookie", "set-cookie2"]

    /// Whether a header value reads as a credential typed into the
    /// template: a scheme word followed by a literal token, or a long
    /// opaque key with a well-known prefix. Bindings (`{{…}}`) pass.
    public static func looksLikePastedCredential(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("{{") else { return false }
        let lowered = text.lowercased()
        for scheme in ["bearer ", "basic ", "token ", "digest ", "apikey "] where lowered.hasPrefix(scheme) {
            return text.count > scheme.count
        }
        let prefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "xapp-", "glpat-", "ya29.", "AIza", "AKIA", "pk_live_", "shpat_", "lin_api_", "ntn_", "secret_"]
        return prefixes.contains(where: { text.hasPrefix($0) }) && text.count >= 16
    }

    public static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "status": .object(["type": .string("integer")]),
            "ok": .object(["type": .string("boolean")]),
            "headers": .object(["type": .string("object")]),
            "body": .object([:]),
            "pages": .object(["type": .string("integer")]),
            "complete": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("status"), .string("ok"), .string("body")]),
    ])
}

/// How an `http` step walks an API's pages. The step requests page after
/// page, collects the items each carries, and outputs them as one array
/// under `body` with `pages` (how many requests) and `complete` (false
/// when the page cap stopped it short). `status`, `ok`, and `headers`
/// are the last page's.
public struct HTTPPagination: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The body names the next cursor at `cursor_path`; send it as
        /// the `cursor_param` query parameter. Ends when it is missing or
        /// empty.
        case cursor
        /// The body names the next page's full URL at `next_url_path`.
        /// Ends when it is missing or null.
        case nextURL = "next_url"
        /// The `Link` response header carries `rel="next"` (GitHub,
        /// GitLab). Ends when it does not.
        case link
        /// Pages are numbered in the `page_param` query parameter from
        /// `start_page`. Ends at the first page with no items.
        case page
    }

    public var mode: Mode
    /// Dot path in each page's body to the array of items; empty when the
    /// body is the array.
    public var itemsPath: String
    public var cursorPath: String?
    public var cursorParam: String
    public var nextURLPath: String?
    public var pageParam: String
    public var startPage: Int
    /// Requests the step makes at most. Capped at `maximumPages`.
    public var maxPages: Int
    /// Stop once this many items are collected, when set.
    public var maxItems: Int?

    public static let defaultMaxPages = 10
    public static let maximumPages = 100
    public static let maximumItems = 10_000

    public init(
        mode: Mode, itemsPath: String = "", cursorPath: String? = nil, cursorParam: String = "cursor",
        nextURLPath: String? = nil, pageParam: String = "page", startPage: Int = 1,
        maxPages: Int = HTTPPagination.defaultMaxPages, maxItems: Int? = nil
    ) {
        self.mode = mode
        self.itemsPath = itemsPath
        self.cursorPath = cursorPath
        self.cursorParam = cursorParam
        self.nextURLPath = nextURLPath
        self.pageParam = pageParam
        self.startPage = startPage
        self.maxPages = maxPages
        self.maxItems = maxItems
    }

    /// The page cap the runner applies: at least one, at most `maximumPages`.
    public var effectiveMaxPages: Int { min(max(maxPages, 1), Self.maximumPages) }

    /// What is wrong with the declaration, if anything.
    public var issues: [String] {
        var out: [String] = []
        switch mode {
        case .cursor:
            if (cursorPath ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("paginate `cursor` needs `cursor_path`: where in the body the next cursor sits")
            }
            if cursorParam.trimmingCharacters(in: .whitespaces).isEmpty { out.append("paginate `cursor_param` is empty") }
        case .nextURL:
            if (nextURLPath ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("paginate `next_url` needs `next_url_path`: where in the body the next page's URL sits")
            }
        case .link:
            break
        case .page:
            if pageParam.trimmingCharacters(in: .whitespaces).isEmpty { out.append("paginate `page_param` is empty") }
        }
        if maxPages > Self.maximumPages { out.append("paginate `max_pages` is capped at \(Self.maximumPages)") }
        if let maxItems, maxItems < 1 { out.append("paginate `max_items` must be at least 1") }
        return out
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case itemsPath = "items_path"
        case cursorPath = "cursor_path"
        case cursorParam = "cursor_param"
        case nextURLPath = "next_url_path"
        case pageParam = "page_param"
        case startPage = "start_page"
        case maxPages = "max_pages"
        case maxItems = "max_items"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        itemsPath = try c.decodeIfPresent(String.self, forKey: .itemsPath) ?? ""
        cursorPath = try c.decodeIfPresent(String.self, forKey: .cursorPath)
        cursorParam = try c.decodeIfPresent(String.self, forKey: .cursorParam) ?? "cursor"
        nextURLPath = try c.decodeIfPresent(String.self, forKey: .nextURLPath)
        pageParam = try c.decodeIfPresent(String.self, forKey: .pageParam) ?? "page"
        startPage = try c.decodeIfPresent(Int.self, forKey: .startPage) ?? 1
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? Self.defaultMaxPages
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        if !itemsPath.isEmpty { try c.encode(itemsPath, forKey: .itemsPath) }
        try c.encodeIfPresent(cursorPath, forKey: .cursorPath)
        if cursorParam != "cursor" { try c.encode(cursorParam, forKey: .cursorParam) }
        try c.encodeIfPresent(nextURLPath, forKey: .nextURLPath)
        if pageParam != "page" { try c.encode(pageParam, forKey: .pageParam) }
        if startPage != 1 { try c.encode(startPage, forKey: .startPage) }
        if maxPages != Self.defaultMaxPages { try c.encode(maxPages, forKey: .maxPages) }
        try c.encodeIfPresent(maxItems, forKey: .maxItems)
    }
}

/// How an `http` step authenticates. Every form names declared secret
/// keys; values never appear in the template.
public enum HTTPAuth: Codable, Equatable, Sendable {
    /// `Authorization: Bearer <secret>`.
    case bearer(secret: String)
    /// The person's login to the service, declared with
    /// `declare_connection`: a sign-in's live access token or the
    /// personal token they chose, sent as `Authorization: Bearer`.
    case connection(secret: String)
    /// `Authorization: Basic base64(<user secret>:<password secret>)`.
    case basic(userSecret: String, passwordSecret: String)
    /// A named header carrying the secret.
    case header(name: String, secret: String)
    /// A query parameter carrying the secret.
    case query(name: String, secret: String)

    enum CodingKeys: String, CodingKey {
        case type, secret, name
        case userSecret = "user_secret"
        case passwordSecret = "password_secret"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "bearer":
            self = .bearer(secret: try c.decode(String.self, forKey: .secret))
        case "connection":
            self = .connection(secret: try c.decode(String.self, forKey: .secret))
        case "basic":
            self = .basic(
                userSecret: try c.decodeIfPresent(String.self, forKey: .userSecret) ?? "",
                passwordSecret: try c.decode(String.self, forKey: .passwordSecret))
        case "header":
            self = .header(name: try c.decode(String.self, forKey: .name), secret: try c.decode(String.self, forKey: .secret))
        case "query":
            self = .query(name: try c.decode(String.self, forKey: .name), secret: try c.decode(String.self, forKey: .secret))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown auth type `\(type)`. Use bearer, connection, basic, header, or query.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bearer(let secret):
            try c.encode("bearer", forKey: .type)
            try c.encode(secret, forKey: .secret)
        case .connection(let secret):
            try c.encode("connection", forKey: .type)
            try c.encode(secret, forKey: .secret)
        case .basic(let user, let password):
            try c.encode("basic", forKey: .type)
            if !user.isEmpty { try c.encode(user, forKey: .userSecret) }
            try c.encode(password, forKey: .passwordSecret)
        case .header(let name, let secret):
            try c.encode("header", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(secret, forKey: .secret)
        case .query(let name, let secret):
            try c.encode("query", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(secret, forKey: .secret)
        }
    }
}

// MARK: - Tool

public struct ToolNodeSpec: Codable, Equatable, Sendable {
    public var tool: ToolRef

    public init(tool: ToolRef) {
        self.tool = tool
    }

    /// Accepts `{name, server?, plugin?}`, the same nested under `tool`, or a
    /// bare tool name.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            tool = ToolRef(name: name)
        } else if let nested = try? decoder.container(keyedBy: CodingKeys.self),
            let ref = try? nested.decode(ToolRef.self, forKey: .tool)
        {
            tool = ref
        } else {
            tool = try ToolRef(from: decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try tool.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey { case tool }
}

public struct RetryPolicy: Codable, Equatable, Sendable {
    /// Total attempts, including the first. 1 means no retry.
    public var maxAttempts: Int
    public var backoffSeconds: Double

    public init(maxAttempts: Int = 1, backoffSeconds: Double = 1) {
        self.maxAttempts = max(1, maxAttempts)
        self.backoffSeconds = max(0, backoffSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case maxAttempts = "max_attempts"
        case backoffSeconds = "backoff_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxAttempts: try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 1,
            backoffSeconds: try c.decodeIfPresent(Double.self, forKey: .backoffSeconds) ?? 1)
    }
}

// MARK: - Inference

public struct InferenceSpec: Codable, Equatable, Sendable {
    /// The slot a step names when it leaves `model_slot` out: it runs on
    /// the person's default model unless the slot is declared.
    public static let defaultSlot = "main"

    public var modelSlot: String
    /// Rendered with bindings before the call.
    public var instructions: String
    public var mode: InferenceMode
    public var temperature: Double?

    public init(modelSlot: String, instructions: String, mode: InferenceMode = .generate, temperature: Double? = nil) {
        self.modelSlot = modelSlot
        self.instructions = instructions
        self.mode = mode
        self.temperature = temperature
    }

    enum CodingKeys: String, CodingKey {
        case instructions, mode, temperature, options, tools
        case modelSlot = "model_slot"
        case maxSteps = "max_steps"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelSlot = try c.decodeIfPresent(String.self, forKey: .modelSlot) ?? Self.defaultSlot
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        switch try c.decodeIfPresent(String.self, forKey: .mode) ?? "generate" {
        case "generate":
            mode = .generate
        case "decide":
            mode = .decide(options: try c.decodeIfPresent([String].self, forKey: .options) ?? [])
        case "agentic":
            mode = .agentic(
                tools: try c.decodeIfPresent([ToolRef].self, forKey: .tools) ?? [],
                maxSteps: try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: c,
                debugDescription: "Unknown inference mode `\(other)`. Use generate, decide, or agentic.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelSlot, forKey: .modelSlot)
        try c.encode(instructions, forKey: .instructions)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        switch mode {
        case .generate:
            try c.encode("generate", forKey: .mode)
        case .decide(let options):
            try c.encode("decide", forKey: .mode)
            try c.encode(options, forKey: .options)
        case .agentic(let tools, let maxSteps):
            try c.encode("agentic", forKey: .mode)
            try c.encode(tools, forKey: .tools)
            try c.encode(maxSteps, forKey: .maxSteps)
        }
    }

    /// Output schema of a decide node: exactly one of the options.
    public static func decideSchema(options: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "choice": .object(["type": .string("string"), "enum": .array(options.map { .string($0) })])
            ]),
            "required": .array([.string("choice")]),
            "additionalProperties": .bool(false),
        ])
    }
}

public enum InferenceMode: Equatable, Sendable {
    /// Free output within the node schema.
    case generate
    /// One of a fixed set; outgoing edges branch on it.
    case decide(options: [String])
    /// Bounded tool loop over MCP and plugin tools.
    case agentic(tools: [ToolRef], maxSteps: Int)
}

/// A tool an agentic node may call. `server` / `plugin` name the provider so
/// requirement derivation can list it; `name` is the tool name as registered.
public struct ToolRef: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var server: String?
    public var plugin: String?
    /// The agent whose permission a tool step's call uses: a teammate
    /// template id, an agent id, or an agent name. The step runs as that
    /// agent, so an Apple app tool runs only when the agent has the app on.
    /// Nil: the step's own grant authorizes the tool.
    public var agent: String?

    public init(name: String, server: String? = nil, plugin: String? = nil, agent: String? = nil) {
        self.name = name
        self.server = server
        self.plugin = plugin
        self.agent = agent
    }

    /// Osaurus's own `shell_run`, not an MCP or plugin tool of that name.
    public var isBuiltinShell: Bool { name == "shell_run" && server == nil && plugin == nil }
}

// MARK: - Dialog

public struct DialogSpec: Codable, Equatable, Sendable {
    public var title: String
    /// Rendered with bindings.
    public var message: String
    public var fields: [DialogField]

    public init(title: String, message: String = "", fields: [DialogField]) {
        self.title = title
        self.message = message
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        fields = try c.decodeIfPresent([DialogField].self, forKey: .fields) ?? []
    }

    enum CodingKeys: String, CodingKey { case title, message, fields }

    public var derivedOutputSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for field in fields { props[field.key] = field.type.schema(options: field.options) }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(fields.filter(\.required).map { .string($0.key) }),
        ])
    }
}

public struct DialogField: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    public var label: String
    public var type: DialogFieldType
    public var required: Bool
    public var defaultValue: JSONValue?
    public var persistence: DialogPersistence
    /// Choice fields only.
    public var options: [String]?
    public var help: String?

    public var id: String { key }

    public init(
        key: String, label: String, type: DialogFieldType = .text, required: Bool = true,
        defaultValue: JSONValue? = nil, persistence: DialogPersistence = .alwaysAsk(prefillLast: false),
        options: [String]? = nil, help: String? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.persistence = persistence
        self.options = options
        self.help = help
    }

    enum CodingKeys: String, CodingKey {
        case key, label, type, required, persistence, options, help
        case defaultValue = "default"
        case prefillLast = "prefill_last"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        type = try c.decodeIfPresent(DialogFieldType.self, forKey: .type) ?? .text
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        defaultValue = try c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        let prefill = try c.decodeIfPresent(Bool.self, forKey: .prefillLast) ?? false
        switch try c.decodeIfPresent(String.self, forKey: .persistence) ?? "always_ask" {
        case "remember": persistence = .remember
        case "always_ask": persistence = .alwaysAsk(prefillLast: prefill)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .persistence, in: c,
                debugDescription: "Unknown persistence `\(other)`. Use remember or always_ask.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        try c.encode(type, forKey: .type)
        try c.encode(required, forKey: .required)
        try c.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try c.encodeIfPresent(options, forKey: .options)
        try c.encodeIfPresent(help, forKey: .help)
        switch persistence {
        case .remember:
            try c.encode("remember", forKey: .persistence)
        case .alwaysAsk(let prefill):
            try c.encode("always_ask", forKey: .persistence)
            if prefill { try c.encode(true, forKey: .prefillLast) }
        }
    }
}

public enum DialogFieldType: String, Codable, Sendable, CaseIterable {
    case text
    case longText = "long_text"
    case number
    case bool
    case choice
    case date
    case file
    case folder
    case secret

    func schema(options: [String]?) -> JSONValue {
        switch self {
        case .number: return .object(["type": .string("number")])
        case .bool: return .object(["type": .string("boolean")])
        case .choice:
            var o: [String: JSONValue] = ["type": .string("string")]
            if let options, !options.isEmpty { o["enum"] = .array(options.map { .string($0) }) }
            return .object(o)
        case .file: return .object(["type": .string("string"), "format": .string("file")])
        case .folder: return .object(["type": .string("string"), "format": .string("folder")])
        default: return .object(["type": .string("string")])
        }
    }
}

public enum DialogPersistence: Equatable, Sendable {
    /// Ask once, store on this Mac, reuse on later calls.
    case remember
    /// Ask on every call.
    case alwaysAsk(prefillLast: Bool)
}

// MARK: - Code

public struct CodeSpec: Codable, Equatable, Sendable {
    public enum Language: String, Codable, Sendable, CaseIterable {
        /// `async function run(input, ctx)` in the sandboxed JavaScript host.
        case javascript
        /// `def run(input, ctx)` run by `python3` in the workflow's sandbox
        /// environment, where `pip` dependencies are installed.
        case python
    }

    public var language: Language
    /// Defines `async function run(input, ctx)` (JavaScript) or
    /// `def run(input, ctx)` (Python).
    public var source: String
    /// Hosts `ctx.fetch` may reach. Empty means no network.
    public var network: [String]
    /// Secret keys readable through `ctx.secrets.get`.
    public var secrets: [String]
    public var timeout: TimeInterval
    public var memoryLimitMB: Int?

    public static let defaultTimeout: TimeInterval = 30

    public init(
        language: Language = .javascript, source: String, network: [String] = [], secrets: [String] = [],
        timeout: TimeInterval = CodeSpec.defaultTimeout, memoryLimitMB: Int? = nil
    ) {
        self.language = language
        self.source = source
        self.network = network
        self.secrets = secrets
        self.timeout = timeout
        self.memoryLimitMB = memoryLimitMB
    }

    enum CodingKeys: String, CodingKey {
        case language, source, network, secrets, timeout
        case memoryLimitMB = "memory_limit_mb"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(Language.self, forKey: .language) ?? .javascript
        source = try c.decode(String.self, forKey: .source)
        network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
        secrets = try c.decodeIfPresent([String].self, forKey: .secrets) ?? []
        timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? Self.defaultTimeout
        memoryLimitMB = try c.decodeIfPresent(Int.self, forKey: .memoryLimitMB)
    }

    /// `language` is left out for JavaScript so older templates keep
    /// their content hash.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if language != .javascript { try c.encode(language, forKey: .language) }
        try c.encode(source, forKey: .source)
        try c.encode(network, forKey: .network)
        try c.encode(secrets, forKey: .secrets)
        try c.encode(timeout, forKey: .timeout)
        try c.encodeIfPresent(memoryLimitMB, forKey: .memoryLimitMB)
    }
}

// MARK: - Edges and bindings

public struct WorkflowEdge: Codable, Equatable, Sendable {
    /// Which outcome of the from-node the edge follows.
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        /// The node finished (the default).
        case success
        /// The node failed and its `on_error` is `continue`.
        case error
        /// The node finished, failed, or was skipped by `on_error: skip`.
        case always
    }

    public var from: String
    public var to: String
    /// Predicate on the from-node's output. nil always passes.
    public var when: WorkflowCondition?
    public var on: Trigger

    public init(from: String, to: String, when: WorkflowCondition? = nil, on: Trigger = .success) {
        self.from = from
        self.to = to
        self.when = when
        self.on = on
    }

    enum CodingKeys: String, CodingKey { case from, to, when, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        when = try c.decodeIfPresent(WorkflowCondition.self, forKey: .when)
        on = try c.decodeIfPresent(Trigger.self, forKey: .on) ?? .success
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encodeIfPresent(when, forKey: .when)
        if on != .success { try c.encode(on, forKey: .on) }
    }
}

/// A predicate over a node output. A leaf compares the value at `path`
/// (dot-separated into the output object: "choice", "client.tier"; empty
/// addresses the whole output) with `op` and `value`. A group combines
/// conditions with `all` (every one holds), `any` (at least one holds), or
/// `not` (the one condition does not hold).
public struct WorkflowCondition: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable, CaseIterable {
        case equals
        case notEquals = "not_equals"
        case `in`
        case notIn = "not_in"
        case exists
        case notExists = "not_exists"
        case isEmpty = "is_empty"
        case notEmpty = "not_empty"
        case isTrue = "is_true"
        case isFalse = "is_false"
        case greaterThan = "greater_than"
        case greaterOrEqual = "greater_or_equal"
        case lessThan = "less_than"
        case lessOrEqual = "less_or_equal"
        case contains
        case notContains = "not_contains"
        case startsWith = "starts_with"
        case endsWith = "ends_with"
        /// Regular expression over the value's text.
        case matches

        /// Whether the op compares against `value`.
        public var takesValue: Bool {
            switch self {
            case .exists, .notExists, .isEmpty, .notEmpty, .isTrue, .isFalse: return false
            default: return true
            }
        }
    }

    public var path: String
    public var op: Op
    public var value: JSONValue?
    /// Group forms. When one is set, `path`, `op`, and `value` are ignored.
    public var all: [WorkflowCondition]?
    public var any: [WorkflowCondition]?
    public var not: [WorkflowCondition]?

    public init(path: String, op: Op = .equals, value: JSONValue? = nil) {
        self.path = path
        self.op = op
        self.value = value
    }

    public static func all(_ conditions: [WorkflowCondition]) -> WorkflowCondition {
        var c = WorkflowCondition(path: "")
        c.all = conditions
        return c
    }

    public static func any(_ conditions: [WorkflowCondition]) -> WorkflowCondition {
        var c = WorkflowCondition(path: "")
        c.any = conditions
        return c
    }

    public static func not(_ condition: WorkflowCondition) -> WorkflowCondition {
        var c = WorkflowCondition(path: "")
        c.not = [condition]
        return c
    }

    public var isGroup: Bool { all != nil || any != nil || not != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "choice"
        op = try c.decodeIfPresent(Op.self, forKey: .op) ?? .equals
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        all = try c.decodeIfPresent([WorkflowCondition].self, forKey: .all)
        any = try c.decodeIfPresent([WorkflowCondition].self, forKey: .any)
        if let single = try? c.decode(WorkflowCondition.self, forKey: .not) {
            not = [single]
        } else {
            not = try c.decodeIfPresent([WorkflowCondition].self, forKey: .not)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let all { try c.encode(all, forKey: .all) }
        if let any { try c.encode(any, forKey: .any) }
        if let not, let first = not.first { try c.encode(first, forKey: .not) }
        if isGroup { return }
        try c.encode(path, forKey: .path)
        try c.encode(op, forKey: .op)
        try c.encodeIfPresent(value, forKey: .value)
    }

    enum CodingKeys: String, CodingKey { case path, op, value, all, any, not }

    /// Problems with the condition's shape; empty when it is well-formed.
    public var issues: [String] {
        var out: [String] = []
        let groups = [all != nil, any != nil, not != nil].filter { $0 }.count
        if groups > 1 { out.append("a condition is one of `all`, `any`, or `not`, not several") }
        if let all {
            if all.isEmpty { out.append("`all` needs at least one condition") }
            out += all.flatMap(\.issues)
        }
        if let any {
            if any.isEmpty { out.append("`any` needs at least one condition") }
            out += any.flatMap(\.issues)
        }
        if let not {
            if not.count != 1 { out.append("`not` takes exactly one condition") }
            out += not.flatMap(\.issues)
        }
        if groups == 0 {
            if op.takesValue, value == nil { out.append("`\(op.rawValue)` needs a `value`") }
            if op == .matches {
                if let pattern = value?.stringValue {
                    if (try? NSRegularExpression(pattern: pattern)) == nil {
                        out.append("`matches` value is not a valid regular expression")
                    }
                } else {
                    out.append("`matches` needs a string `value`")
                }
            }
            if op == .in || op == .notIn, let value, value.arrayValue == nil {
                out.append("`\(op.rawValue)` needs an array `value`")
            }
        }
        return out
    }

    public func evaluate(_ output: JSONValue) -> Bool {
        if let all { return all.allSatisfy { $0.evaluate(output) } }
        if let any { return any.contains { $0.evaluate(output) } }
        if let not { return !(not.first?.evaluate(output) ?? false) }
        let target = path.isEmpty ? output : output.value(atPath: path)
        switch op {
        case .exists:
            if let target, target != .null { return true }
            return false
        case .notExists:
            return target == nil || target == .null
        case .equals:
            return target == value
        case .notEquals:
            return target != value
        case .in:
            guard case .array(let list)? = value, let target else { return false }
            return list.contains(target)
        case .notIn:
            guard case .array(let list)? = value else { return false }
            guard let target else { return true }
            return !list.contains(target)
        case .isEmpty:
            return Self.isEmpty(target)
        case .notEmpty:
            return !Self.isEmpty(target)
        case .isTrue:
            return Self.truthy(target) == true
        case .isFalse:
            return Self.truthy(target) == false
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
            guard let target, let value else { return false }
            guard let order = Self.compare(target, value) else { return false }
            switch op {
            case .greaterThan: return order == .orderedDescending
            case .greaterOrEqual: return order != .orderedAscending
            case .lessThan: return order == .orderedAscending
            default: return order != .orderedDescending
            }
        case .contains, .notContains:
            let found = Self.contains(target, value)
            return op == .contains ? found : !found
        case .startsWith:
            guard let text = Self.text(target), let prefix = value?.stringValue else { return false }
            return text.hasPrefix(prefix)
        case .endsWith:
            guard let text = Self.text(target), let suffix = value?.stringValue else { return false }
            return text.hasSuffix(suffix)
        case .matches:
            guard let text = Self.text(target), let pattern = value?.stringValue,
                let regex = try? NSRegularExpression(pattern: pattern)
            else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    static func isEmpty(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return true
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a)?: return a.isEmpty
        case .object(let o)?: return o.isEmpty
        default: return false
        }
    }

    /// A boolean reading of a value: booleans as they are, "true"/"false"
    /// text, numbers by zero-ness. Nil for anything else.
    static func truthy(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?:
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Text for string ops; numbers and booleans render as text too.
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: return s
        case .number?, .bool?: return value.map(BindingRenderer.textValue)
        default: return nil
        }
    }

    /// Numbers compare as numbers (numeric text counts), ISO 8601 dates as
    /// dates, other strings lexically. Nil when the two are not comparable.
    static func compare(_ a: JSONValue, _ b: JSONValue) -> ComparisonResult? {
        if let x = number(a), let y = number(b) {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        if let x = date(a), let y = date(b) {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        if case .string(let x) = a, case .string(let y) = b {
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        }
        return nil
    }

    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func date(_ value: JSONValue) -> Date? {
        guard case .string(let s) = value else { return nil }
        let text = s.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) {
            return date
        }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: .iso8601.year().month().day().dateSeparator(.dash)) { return date }
        return nil
    }

    /// Arrays contain an element; strings contain a substring; objects
    /// contain a key.
    static func contains(_ target: JSONValue?, _ value: JSONValue?) -> Bool {
        guard let target, let value else { return false }
        switch target {
        case .array(let list): return list.contains(value)
        case .string(let s):
            guard let needle = text(value) else { return false }
            return s.contains(needle)
        case .object(let o):
            guard let key = value.stringValue else { return false }
            return o[key] != nil
        default: return false
        }
    }
}

/// How a node's input (or the workflow output) is assembled.
/// - `template`: one string with `{{input.x}}` / `{{nodes.id.output.y}}`
///   refs. A string that is exactly one ref yields the referenced value
///   unchanged (typed), otherwise refs are interpolated as text.
/// - `object`: named values, each a template string as above.
/// - `values`: named values where some are literal `true`/`false`,
///   numbers, or `null`, passed through with their type.
public enum WorkflowBinding: Codable, Equatable, Sendable {
    case template(String)
    case object([String: String])
    case values([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .template(s)
        } else if let o = try? c.decode([String: String].self) {
            self = .object(o)
        } else {
            let fields = try c.decode([String: JSONValue].self)
            for (key, value) in fields {
                switch value {
                case .string, .bool, .number, .null: continue
                default:
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: c.codingPath,
                            debugDescription:
                                "binding field `\(key)` is a list or object; a field is a {{...}} string, true/false, "
                                + "a number, or null. Build a structured value in a `code` step."))
                }
            }
            self = .values(fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .template(let s): try c.encode(s)
        case .object(let o): try c.encode(o)
        case .values(let v): try c.encode(v)
        }
    }

    /// The named fields' template strings; nil for a `template` binding.
    public var fieldTemplates: [String: String]? {
        switch self {
        case .template: return nil
        case .object(let o): return o
        case .values(let v): return v.compactMapValues(\.stringValue)
        }
    }

    /// The named fields; empty for a `template` binding.
    public var fieldNames: Set<String> {
        switch self {
        case .template: return []
        case .object(let o): return Set(o.keys)
        case .values(let v): return Set(v.keys)
        }
    }

    /// Every `{{ref}}` expression the binding uses.
    public var references: [String] {
        switch self {
        case .template(let s): return BindingRenderer.references(in: s)
        case .object, .values:
            let fields = fieldTemplates ?? [:]
            return fields.keys.sorted().flatMap { BindingRenderer.references(in: fields[$0] ?? "") }
        }
    }
}

// MARK: - JSONValue helpers

extension JSONValue {
    /// Dot-path lookup into objects and (numeric segments) arrays.
    public func value(atPath path: String) -> JSONValue? {
        let parts = path.split(separator: ".").map(String.init)
        var current: JSONValue = self
        for part in parts {
            switch current {
            case .object(let dict):
                guard let next = dict[part] else { return nil }
                current = next
            case .array(let list):
                guard let i = Int(part), list.indices.contains(i) else { return nil }
                current = list[i]
            default:
                return nil
            }
        }
        return current
    }

    var isEmptySchema: Bool {
        switch self {
        case .null: return true
        case .object(let o):
            if o.isEmpty { return true }
            if o.count == 1, o["type"] == .string("object") { return true }
            return false
        default: return false
        }
    }

    /// A copy with `transform` applied to every string, including object keys.
    public func scrubbingStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let s): return .string(transform(s))
        case .array(let items): return .array(items.map { $0.scrubbingStrings(transform) })
        case .object(let dict):
            var out: [String: JSONValue] = [:]
            for (key, value) in dict { out[transform(key)] = value.scrubbingStrings(transform) }
            return .object(out)
        default: return self
        }
    }

    /// Compact JSON text, keys sorted.
    public var compactJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public var prettyJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

extension Double {
    /// `Int(_:)` traps on NaN, infinity, and values past `Int`'s range, and a
    /// workflow's numbers are written by a model. NaN gives the lower bound.
    func clampedInt(_ rule: FloatingPointRoundingRule = .towardZero, in range: ClosedRange<Int> = Int.min...Int.max) -> Int {
        guard !isNaN else { return range.lowerBound }
        let value = rounded(rule)
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        return Int(value)
    }
}
