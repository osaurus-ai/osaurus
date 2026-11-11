//
//  WorkflowRunner.swift
//  osaurus
//
//  Executes one workflow run. Input is validated against the input schema
//  before any node runs. Nodes are scheduled from the graph: a node starts
//  once every predecessor has resolved, and runs when at least one
//  incoming edge passed (its source completed and its `when` holds); with
//  none passing it is skipped and binds as null, which in turn may skip its
//  own successors. Independent nodes run concurrently.
//
//  Each attempt runs under the node's timeout; failed attempts retry per
//  the node's policy with exponential backoff. The first node that fails
//  for good cancels everything in flight and fails the run. Cancelling the
//  calling task cancels the run.
//
//  Test runs (The Architect) may pin node outputs and start at one node:
//  nodes outside the start node's descendants are then pinned or skipped,
//  and every ancestor must be pinned.
//

import Foundation

public actor WorkflowRunner {

    public struct Request: Sendable {
        public var runID: UUID
        public var workflowID: UUID
        public var workflowName: String
        public var template: Template
        /// Model slot -> resolved model id.
        public var slotModels: [String: String]
        /// Secret key -> Keychain account.
        public var secretAccounts: [String: String]
        public var caller: WorkflowCaller
        public var input: JSONValue
        public var startAt: String?
        public var pinned: [String: JSONValue]
        public var maxConcurrentNodes: Int
        /// Overrides the per-run workspace location (tests).
        public var workspace: URL?
        /// Where file and shell tools run. nil uses the run workspace.
        public var folderRoot: URL?
        /// Run shell steps in the workflow's own sandbox environment. On by
        /// default when the template declares dependencies; the run
        /// workspace then lives under the VirtioFS share so the host and
        /// the VM see one directory.
        public var usesSandbox: Bool
        /// Declared folder key -> the folder bound on this Mac.
        public var boundFolders: [String: String]
        /// Folders the person allowed every run of this workflow to read
        /// and save in.
        public var folderGrants: [String]
        /// Folders the person allowed every run to read only.
        public var folderReadGrants: [String] = []
        /// Folders where every run may replace existing files.
        public var replaceGrants: [String] = []
        /// Saves a folder the person chose "Always allow" for: to read it,
        /// or to save in it.
        public var persistFolderGrant: (@Sendable (String, FolderRequirement.Access) async -> Void)?
        /// Saves a folder the person chose "Always allow" replacing files in.
        public var persistReplaceGrant: (@Sendable (String) async -> Void)?
        /// `AgentRequirement.id` -> the agent chosen for it on this Mac
        /// (`InstallBindings.agents`).
        public var agentBindings: [String: String] = [:]
        /// `InstalledWorkflow.agentStepsAllowed`.
        public var agentStepsAllowed = false
        /// Set on a derived wrapper run: the agent its one step hands the
        /// task to. Recorded as `WorkflowRun.wrapperAgentID`; a built-in
        /// worker runs only under this marker.
        public var wrapperAgentID: UUID?
        /// A run of an unsaved Architect draft (`WorkflowRun.ephemeral`).
        public var ephemeral = false
        /// Reads a secret bound to a shared connection
        /// (`WorkflowSecretsKeychain.connectionBinding`): the pasted value
        /// or a fresh OAuth access token. nil means "not a connection".
        public var connectionSecret: @Sendable (String) async throws -> String? = { binding in
            try await WorkflowConnectionResolver.resolve(binding: binding)
        }
        /// The record of a run a previous launch left open. The runner picks
        /// it up: finished nodes keep their outputs and are not run again,
        /// unfinished ones run again, and a form that was waiting keeps the
        /// time it had left. The run id, start time, and caller are the
        /// record's.
        public var resuming: WorkflowRun?
        /// The record of a failed run to continue as a new run: steps that
        /// finished keep their outputs and are not run again; the failed
        /// step and everything after it run again. The new run notes the
        /// old one as `retryOf`.
        public var retrying: WorkflowRun?
        /// An earlier test whose results the pinned nodes are: each keeps
        /// that run's input, spec hash, and files, and notes it as
        /// `reusedFrom` (Test From This Step).
        public var reusing: WorkflowRun?

        /// Folders the run may use beyond its working folder and workspace.
        public var grantedFolders: [URL] {
            InstallBindings(folders: boundFolders, folderGrants: folderGrants, folderReadGrants: folderReadGrants)
                .grantedFolderURLs
        }

        public init(
            runID: UUID = UUID(), workflowID: UUID, workflowName: String, template: Template,
            slotModels: [String: String] = [:], secretAccounts: [String: String] = [:],
            caller: WorkflowCaller, input: JSONValue, startAt: String? = nil,
            pinned: [String: JSONValue] = [:], maxConcurrentNodes: Int = 4, workspace: URL? = nil,
            folderRoot: URL? = nil, usesSandbox: Bool? = nil, boundFolders: [String: String] = [:],
            folderGrants: [String] = [],
            persistFolderGrant: (@Sendable (String, FolderRequirement.Access) async -> Void)? = nil,
            resuming: WorkflowRun? = nil, retrying: WorkflowRun? = nil
        ) {
            self.folderRoot = folderRoot
            self.boundFolders = boundFolders
            self.folderGrants = folderGrants
            self.persistFolderGrant = persistFolderGrant
            self.resuming = resuming
            self.retrying = retrying
            self.usesSandbox =
                usesSandbox ?? (template.requirements.usesSandbox || template.workflow?.usesSandbox == true)
            self.runID = resuming?.id ?? runID
            self.workflowID = workflowID
            self.workflowName = workflowName
            self.template = template
            self.slotModels = slotModels
            self.secretAccounts = secretAccounts
            self.caller = caller
            self.input = input
            self.startAt = startAt
            self.pinned = pinned
            self.maxConcurrentNodes = max(1, maxConcurrentNodes)
            self.workspace = workspace
        }
    }

    public typealias Observer = @Sendable (WorkflowRun) async -> Void

    private let request: Request
    private let executor: WorkflowNodeExecuting
    private let observer: Observer
    private var run: WorkflowRun
    private var outputs: [String: JSONValue] = [:]
    /// The model the latest finished inference step ran on. A local media
    /// step may swap it out, since this run loaded it.
    private var lastInferenceModel: String?
    private var awaitingNodes: Set<String> = []
    private var lastProgressPublish = Date.distantPast
    /// "Allow for This Task" approvals, shared by every node of the run.
    private let permissionScope = ToolPermissionRunScope()
    /// Folders the person allowed while this run was going.
    private var runtimeGrants: [URL] = []
    /// The ones among them the person allowed saving in.
    private var runtimeWriteGrants: [URL] = []
    /// Folders where the person allowed this run to replace existing files.
    private var replaceApproved: [URL] = []
    /// Replace cards on screen, by folder, so steps running at once share one.
    private var replaceRequests: [String: Task<Bool, Error>] = [:]
    /// What the definition touches on this Mac.
    private let accessScope: WorkflowAccessScope
    /// Every secret value this run has handled, by the key or field it
    /// came from: install secrets resolved for code nodes and secret
    /// dialog answers. Nothing published or returned contains them.
    private var knownSecrets: [String: String] = [:]
    /// Seconds a form that was waiting when a previous launch quit still
    /// has, by node id (runs picked up with `Request.resuming`).
    private var resumedTimeouts: [String: TimeInterval] = [:]
    /// Seconds a wait step had already spent when a previous launch quit,
    /// by node id, so it waits only the rest.
    private var resumedElapsed: [String: TimeInterval] = [:]

    public init(request: Request, executor: WorkflowNodeExecuting, observer: @escaping Observer = { _ in }) {
        self.request = request
        self.executor = executor
        self.observer = observer
        self.accessScope = WorkflowAccessScope.derive(request.template.workflow ?? WorkflowDefinition())
        if let previous = request.resuming {
            let seeded = Self.resumed(previous, definition: request.template.workflow)
            self.run = seeded.run
            self.outputs = seeded.outputs
            self.resumedTimeouts = seeded.timeouts
            self.resumedElapsed = seeded.elapsed
        } else if let previous = request.retrying {
            let seeded = Self.retried(
                previous, definition: request.template.workflow, runID: request.runID, caller: request.caller)
            self.run = seeded.run
            self.outputs = seeded.outputs
        } else {
            self.run = WorkflowRun(
                id: request.runID, workflowID: request.workflowID, workflowName: request.workflowName,
                templateID: request.template.id, templateVersion: request.template.version,
                caller: request.caller, input: request.input,
                nodeIDs: request.template.workflow?.nodes.map(\.id) ?? [])
            self.run.wrapperAgentID = request.wrapperAgentID
            self.run.ephemeral = request.ephemeral
        }
    }

    /// The record of an open run made ready to continue: `done`, `pinned`,
    /// and `skipped` nodes stay as they were and seed `outputs`; every other
    /// node goes back to pending. A dialog node that was running or waiting
    /// keeps `node.timeout` less the time already spent, so a form the
    /// person never answered times out when it would have (at once, when
    /// that time has passed). Nodes the definition no longer has are
    /// dropped; new ones start pending.
    static func resumed(_ previous: WorkflowRun, definition: WorkflowDefinition?) -> (
        run: WorkflowRun, outputs: [String: JSONValue], timeouts: [String: TimeInterval],
        elapsed: [String: TimeInterval]
    ) {
        var run = previous
        run.status = .running
        run.error = nil
        run.output = nil
        run.finishedAt = nil
        var outputs: [String: JSONValue] = [:]
        var timeouts: [String: TimeInterval] = [:]
        var elapsed: [String: TimeInterval] = [:]
        let nodes = definition?.nodes ?? []
        let byID = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.nodeID, $0) })
        run.nodes = nodes.map { node in
            guard var record = byID[node.id] else { return NodeRun(nodeID: node.id) }
            switch record.status {
            case .done, .pinned:
                outputs[node.id] = record.output ?? .null
                return record
            case .skipped:
                outputs[node.id] = .null
                return record
            case .running, .awaitingUser:
                if case .dialog = node.kind, let started = record.startedAt {
                    timeouts[node.id] = max(0, node.timeout - Date().timeIntervalSince(started))
                }
                if case .wait = node.kind, let started = record.startedAt {
                    elapsed[node.id] = max(0, Date().timeIntervalSince(started))
                }
                fallthrough
            case .pending, .failed:
                record.status = .pending
                record.error = nil
                record.finishedAt = nil
                if record.attempts > 0 { record.logs.append(L("Picked up again after Osaurus relaunched.")) }
                record.attempts = 0
                return record
            }
        }
        return (run, outputs, timeouts, elapsed)
    }

    /// A new run that continues a failed one from its failed step: nodes
    /// that were `done` or `pinned` keep their records and seed `outputs`;
    /// every other node (the failed one, the ones skipped because the run
    /// stopped, and branch skips, which the scheduler derives again)
    /// starts pending. Files the finished steps shared stay with the run.
    static func retried(
        _ previous: WorkflowRun, definition: WorkflowDefinition?, runID: UUID, caller: WorkflowCaller
    ) -> (run: WorkflowRun, outputs: [String: JSONValue]) {
        let nodes = definition?.nodes ?? []
        var run = WorkflowRun(
            id: runID, workflowID: previous.workflowID, workflowName: previous.workflowName,
            templateID: previous.templateID, templateVersion: previous.templateVersion, caller: caller,
            input: previous.input, nodeIDs: nodes.map(\.id))
        run.retryOf = previous.id
        run.workspaceRunID = previous.workspaceRunID ?? previous.id
        run.artifacts = previous.artifacts
        var outputs: [String: JSONValue] = [:]
        let byID = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.nodeID, $0) })
        let failedAt = previous.error?.nodeID
        run.nodes = nodes.map { node in
            guard let record = byID[node.id] else { return NodeRun(nodeID: node.id) }
            switch record.status {
            case .done, .pinned:
                outputs[node.id] = record.output ?? .null
                return record
            case .failed, .skipped, .pending, .running, .awaitingUser:
                var fresh = NodeRun(nodeID: node.id)
                if node.id == failedAt {
                    fresh.logs.append(L("Running again; the last run failed here."))
                }
                return fresh
            }
        }
        return (run, outputs)
    }

    public var snapshot: WorkflowRun { redacted(run) }

    /// The run whose workspace this run works in: its own, or for a retry
    /// the run it continues, so files finished steps wrote are still there.
    private var workspaceRunID: UUID { run.workspaceRunID ?? request.runID }

    private var workspaceURL: URL {
        if let workspace = request.workspace { return workspace }
        if request.usesSandbox {
            return OsaurusPaths.workflowSandboxRunWorkspace(environmentID: request.template.id, runID: workspaceRunID)
        }
        return OsaurusPaths.workflowRunWorkspace(workflowID: request.workflowID, runID: workspaceRunID)
    }

    /// The sandbox every shell and Python step of this run executes in.
    /// Keyed by template id, like the environment the setup wizard
    /// installed into.
    private var sandboxContext: WorkflowSandboxContext? {
        guard request.usesSandbox else { return nil }
        return WorkflowSandboxContext.forRun(environmentID: request.template.id, runID: workspaceRunID)
    }

    /// Folders and files the person picked for this run: `folder` / `file`
    /// fields of the input form (`format: "folder"` / `"file"` on the input
    /// schema) and of every answered dialog. Host file tools may use them.
    static func grantedPaths(
        input: JSONValue, inputSchema: JSONValue, definition: WorkflowDefinition?, outputs: [String: JSONValue]
    ) -> [URL] {
        var paths: [URL] = []
        func add(_ value: JSONValue?) {
            guard let path = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                path.hasPrefix("/")
            else { return }
            let url = URL(fileURLWithPath: path).standardized
            if !paths.contains(url) { paths.append(url) }
        }
        let props = inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        for (key, prop) in props {
            guard let format = prop.objectValue?["format"]?.stringValue, format == "folder" || format == "file"
            else { continue }
            add(input.objectValue?[key])
        }
        for node in definition?.nodes ?? [] {
            guard case .dialog(let spec)? = node.kind, let output = outputs[node.id]?.objectValue else { continue }
            for field in spec.fields where field.type == .folder || field.type == .file {
                add(output[field.key])
            }
        }
        return paths
    }

    private var bindingContext: BindingContext {
        BindingContext(
            input: request.input, outputs: outputs,
            run: BindingContext.runValue(id: request.runID, workspace: workspaceURL),
            caller: BindingContext.callerValue(request.caller),
            folders: BindingContext.foldersValue(request.boundFolders))
    }

    /// Every host path a node's file tools may use beyond the working
    /// folder: picked folders and files, bound folders, standing grants,
    /// and folders allowed during this run.
    private var nodeGrantedPaths: [URL] {
        var paths = Self.grantedPaths(
            input: request.input, inputSchema: request.template.workflow?.inputSchema ?? .object([:]),
            definition: request.template.workflow, outputs: outputs)
        for url in request.grantedFolders + runtimeGrants {
            let standardized = url.standardized
            if !paths.contains(standardized) { paths.append(standardized) }
        }
        return paths
    }

    /// Where under `nodeGrantedPaths` file tools may save: each write target
    /// the definition declares (`WorkflowAccessScope`), folders the person
    /// allowed saving in, and the run's workspace (added when bound).
    private var nodeWritableRoots: [URL] {
        let resolved = accessScope.resolved(
            input: request.input, dialogOutputs: outputs, boundFolders: request.boundFolders)
        var roots: [URL] = []
        let candidates =
            resolved.flatMap(\.writableURLs) + request.folderGrants.map { URL(fileURLWithPath: $0, isDirectory: true) }
            + runtimeWriteGrants
        for url in candidates {
            let standardized = url.standardized
            if !roots.contains(standardized) { roots.append(standardized) }
        }
        return roots
    }

    /// The folders the person picked or bound for this run, as named in
    /// its result summary.
    var accessRoots: [URL] {
        accessScope.resolved(input: request.input, dialogOutputs: outputs, boundFolders: request.boundFolders)
            .map(\.url)
    }

    private func hostFileHooks(for node: WorkflowNode, workspace: URL) -> WorkflowHostFileHooks {
        let canAsk = WorkflowFolderGrantCoordinator.canAsk(request.caller)
        return WorkflowHostFileHooks(
            workspace: workspace,
            approveReplace: { [weak self] folder, file in
                guard let self else { throw CancellationError() }
                return try await self.approveReplace(node, folder: folder, file: file, canAsk: canAsk)
            },
            record: { [weak self] file, replaced in
                await self?.recordHostWrite(file, replaced: replaced)
            })
    }

    private func recordHostWrite(_ file: URL, replaced: Bool) {
        run.hostWrites.append(WorkflowHostWrite(path: file.path, replaced: replaced))
    }

    /// Whether this run may replace `file` in `folder`: allowed already
    /// (this run or always), else the person decides on a card. Steps that
    /// hit the same folder at once share the card.
    private func approveReplace(_ node: WorkflowNode, folder: URL, file: URL, canAsk: Bool) async throws -> Bool {
        let standing = request.replaceGrants.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if FolderToolHelpers.isWithin(file, anyOf: replaceApproved + standing) { return true }
        guard canAsk else { return false }
        let key = folder.standardized.path
        if let pending = replaceRequests[key] { return try await pending.value }
        let task = Task { try await self.askReplace(node, folder: folder.standardized, file: file) }
        replaceRequests[key] = task
        defer { replaceRequests[key] = nil }
        return try await task.value
    }

    private func askReplace(_ node: WorkflowNode, folder: URL, file: URL) async throws -> Bool {
        let dialog = WorkflowFolderGrantCoordinator.replaceDialog(
            runID: request.runID, workflowID: request.workflowID, workflowName: request.workflowName, node: node,
            folder: folder, file: file, caller: request.caller)
        await setAwaitingUser(node.id, waiting: true)
        let decision: WorkflowFolderGrantDecision
        do {
            decision = try await WorkflowFolderGrantCoordinator.request(dialog)
        } catch {
            await setAwaitingUser(node.id, waiting: false)
            throw error
        }
        await setAwaitingUser(node.id, waiting: false)
        switch decision {
        case .deny:
            run.update(node.id) { $0.logs.append(L("Not allowed to replace files in \(folder.path).")) }
        case .allowOnce, .allowAlways:
            if !replaceApproved.contains(folder) { replaceApproved.append(folder) }
            if decision == .allowAlways { await request.persistReplaceGrant?(folder.path) }
            run.update(node.id) {
                $0.logs.append(
                    decision == .allowAlways
                        ? L("Always allowed replacing files in \(folder.path).")
                        : L("Allowed replacing files in \(folder.path) for this run."))
            }
        }
        await publish()
        return decision != .deny
    }

    private func folderGrantRequest(for node: WorkflowNode) -> WorkflowFolderGrantRequest? {
        guard WorkflowFolderGrantCoordinator.canAsk(request.caller) else { return nil }
        return { [weak self] path, access in
            guard let self else { throw CancellationError() }
            return try await self.grantFolder(node, path: path, access: access)
        }
    }

    /// Shows the folder card for `node` and records the answer.
    private func grantFolder(
        _ node: WorkflowNode, path: String, access: FolderRequirement.Access
    ) async throws -> WorkflowFolderGrantDecision {
        let dialog = WorkflowFolderGrantCoordinator.dialog(
            runID: request.runID, workflowID: request.workflowID, workflowName: request.workflowName, node: node,
            path: path, access: access, caller: request.caller)
        await setAwaitingUser(node.id, waiting: true)
        let decision: WorkflowFolderGrantDecision
        do {
            decision = try await WorkflowFolderGrantCoordinator.request(dialog)
        } catch {
            await setAwaitingUser(node.id, waiting: false)
            throw error
        }
        await setAwaitingUser(node.id, waiting: false)
        let folder = FolderRequirement.grantRoot(for: path)
        switch decision {
        case .deny:
            run.update(node.id) { $0.logs.append(L("Not allowed to use \(folder.path).")) }
        case .allowOnce, .allowAlways:
            if !runtimeGrants.contains(folder) { runtimeGrants.append(folder) }
            if access == .write, !runtimeWriteGrants.contains(folder) { runtimeWriteGrants.append(folder) }
            if decision == .allowAlways { await request.persistFolderGrant?(folder.path, access) }
            run.update(node.id) {
                $0.logs.append(
                    decision == .allowAlways
                        ? L("Always allowed \(folder.path).") : L("Allowed \(folder.path) for this run."))
            }
        }
        await publish()
        return decision
    }

    // MARK: - Entry

    public func execute() async -> WorkflowRun {
        await publish()
        guard let def = request.template.workflow else {
            return await finish(.failed, error: WorkflowRunError(reason: L("This template is not a workflow.")))
        }
        let inputIssues = JSONSchemaValidator.validate(request.input, against: def.inputSchema)
        if let first = inputIssues.first {
            return await finish(
                .failed,
                error: WorkflowRunError(
                    reason: L("Input does not match the workflow's input schema: ")
                        + inputIssues.map(\.description).joined(separator: "; "),
                    path: first.path))
        }
        let structural = WorkflowValidator.validate(def, allowPlaceholders: run.isTest, checkSandboxCommands: false)
        if !structural.isEmpty {
            return await finish(
                .failed,
                error: WorkflowRunError(reason: structural.map(\.message).joined(separator: "; ")))
        }
        guard let order = WorkflowValidator.topologicalOrder(def) else {
            return await finish(.failed, error: WorkflowRunError(reason: L("The workflow graph has a cycle.")))
        }
        if let failure = applyPinsAndStart(def) {
            return await finish(.failed, error: failure)
        }

        if request.usesSandbox {
            // A container restart loses Linux users; the bootstrap is
            // idempotent. pip/npm live on the host share; apk packages an
            // eviction removed are reinstalled from the declared list.
            do {
                let environmentID = request.template.id
                try await WorkflowSandboxEnvironment.shared.ensureProvisioned(
                    environmentID: environmentID, dependencies: request.template.requirements.dependencies)
            } catch {
                return await finish(
                    .failed,
                    error: WorkflowRunError(
                        reason: L("The sandbox this workflow runs in could not start: \(WorkflowFailure.message(error))"),
                        failure: NodeRunFailure(
                            kind: "sandbox_unavailable", retryable: true, errorType: WorkflowFailure.typeName(error),
                            fixIn: .setup,
                            hint: L("Open Set Up to check the workflow's dependencies, or retry once the sandbox is available."))))
            }
        }

        let workspace = workspaceURL
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let failure = await schedule(def, order: order, workspace: workspace)
        if Task.isCancelled {
            markUnfinished(.skipped)
            return await finish(.cancelled, error: WorkflowRunError(reason: L("Cancelled.")))
        }
        if let failure {
            markUnfinished(.skipped)
            return await finish(.failed, error: failure)
        }

        let output = BindingRenderer.render(def.output, in: bindingContext)
        let outputIssues = JSONSchemaValidator.validate(output, against: def.outputSchema)
        if !outputIssues.isEmpty {
            run.output = output
            return await finish(
                .failed,
                error: WorkflowRunError(
                    reason: L("The assembled output does not match the output schema: ")
                        + outputIssues.map(\.description).joined(separator: "; "),
                    path: outputIssues.first?.path))
        }
        run.output = output
        let scope = WorkflowFileScope(
            folderRoot: request.folderRoot ?? workspace, workspace: workspace, granted: nodeGrantedPaths,
            sandbox: sandboxContext)
        run.artifacts += WorkflowArtifactCollector.outputFiles(output, schema: def.outputSchema, scope: scope)
        return await finish(.completed, error: nil)
    }

    // MARK: - Test pins

    /// Resolves pinned nodes and the start-at subgraph. Returns a failure
    /// when a pin names an unknown node or the start node's ancestors are
    /// not all pinned.
    private func applyPinsAndStart(_ def: WorkflowDefinition) -> WorkflowRunError? {
        let ids = Set(def.nodes.map(\.id))
        for id in request.pinned.keys where !ids.contains(id) {
            return WorkflowRunError(nodeID: id, reason: L("Pinned node \"\(id)\" is not in the workflow."))
        }
        var runnable = ids
        if let start = request.startAt {
            guard ids.contains(start) else {
                return WorkflowRunError(nodeID: start, reason: L("Start node \"\(start)\" is not in the workflow."))
            }
            runnable = Self.descendants(of: start, in: def).union([start])
            let ancestors = WorkflowValidator.ancestorMap(def)[start] ?? []
            let missing = ancestors.filter { request.pinned[$0] == nil }.sorted()
            if !missing.isEmpty {
                return WorkflowRunError(
                    nodeID: start,
                    reason: L("Starting at \"\(start)\" needs pinned outputs for: \(missing.joined(separator: ", ")).")
                )
            }
        }
        for node in def.nodes {
            if let value = request.pinned[node.id] {
                outputs[node.id] = value
                let reused = request.reusing.flatMap { $0.node(node.id) == nil ? nil : $0 }
                run.update(node.id) {
                    $0.status = .pinned
                    $0.output = value
                    if let reused, let earlier = reused.node(node.id) {
                        $0.reusedFrom = reused.id
                        $0.input = earlier.input
                        $0.specHash = earlier.specHash
                        $0.model = earlier.model
                    }
                }
                if let reused {
                    run.artifacts += reused.artifacts.filter { $0.nodeID == node.id && $0.source != .output }
                }
            } else if !runnable.contains(node.id) {
                outputs[node.id] = .null
                run.update(node.id) { $0.status = .skipped }
            }
        }
        return nil
    }

    static func descendants(of id: String, in def: WorkflowDefinition) -> Set<String> {
        var out = Set<String>()
        var stack = [id]
        while let current = stack.popLast() {
            for edge in def.edges where edge.from == current && out.insert(edge.to).inserted {
                stack.append(edge.to)
            }
        }
        return out
    }

    // MARK: - Scheduling

    private enum Resolution {
        case ran
        case skipped
    }

    /// A node has resolved once it finished, was pinned, was skipped, or
    /// failed with `on_error: continue` (a failure that stops the run never
    /// reaches the scheduler again).
    private func isResolved(_ id: String) -> Bool {
        switch run.node(id)?.status {
        case .done?, .skipped?, .pinned?, .failed?: return true
        default: return false
        }
    }

    /// Whether an edge carries: its `on` matches how the source ended
    /// (`success` after done or pinned, `error` after a continued failure,
    /// `always` for either) and its `when`, if any, holds on the source's
    /// output (for a failed source, `{error: {message, kind, retryable, fix_in, attempts}}`).
    private func edgePassed(_ edge: WorkflowEdge) -> Bool {
        guard let status = run.node(edge.from)?.status else { return false }
        switch status {
        case .done, .pinned:
            guard edge.on == .success || edge.on == .always else { return false }
        case .failed:
            guard edge.on == .error || edge.on == .always else { return false }
        case .pending, .running, .awaitingUser, .skipped:
            return false
        }
        guard let when = edge.when else { return true }
        return when.evaluate(outputs[edge.from] ?? .null)
    }

    /// Whether a node whose predecessors all resolved should run: with
    /// `join: any` (the default) when at least one incoming edge passed,
    /// with `join: all` when every one did.
    private func joinSatisfied(_ node: WorkflowNode, incoming: [WorkflowEdge]) -> Bool {
        if incoming.isEmpty { return true }
        switch node.join {
        case .any: return incoming.contains(where: edgePassed)
        case .all: return incoming.allSatisfy(edgePassed)
        }
    }

    /// Nodes ready to start, after marking every node whose incoming edges
    /// all resolved without satisfying its join as skipped.
    private func readyNodes(
        _ def: WorkflowDefinition, order: [String], nodesByID: [String: WorkflowNode], running: Set<String>
    ) -> [String] {
        var changed = true
        while changed {
            changed = false
            for id in order where run.node(id)?.status == .pending && !running.contains(id) {
                guard let node = nodesByID[id] else { continue }
                let incoming = def.edges.filter { $0.to == id }
                guard incoming.allSatisfy({ isResolved($0.from) }) else { continue }
                if !joinSatisfied(node, incoming: incoming) {
                    outputs[id] = .null
                    run.update(id) { $0.status = .skipped }
                    changed = true
                }
            }
        }
        return order.filter { id in
            guard run.node(id)?.status == .pending, !running.contains(id) else { return false }
            let incoming = def.edges.filter { $0.to == id }
            return incoming.allSatisfy { isResolved($0.from) }
        }
    }

    private struct Launch: Sendable {
        let node: WorkflowNode
        let input: JSONValue
        let bindings: BindingContext
    }

    /// Marks ready nodes running, up to the concurrency limit.
    private func startReady(
        _ def: WorkflowDefinition, order: [String], nodesByID: [String: WorkflowNode], running: inout Set<String>
    ) -> [Launch] {
        var launches: [Launch] = []
        for id in readyNodes(def, order: order, nodesByID: nodesByID, running: running) {
            guard running.count < request.maxConcurrentNodes, let node = nodesByID[id] else { break }
            let bindings = bindingContext
            let input = BindingRenderer.render(node.input, in: bindings)
            run.update(id) {
                $0.status = .running
                $0.input = input
                $0.startedAt = Date()
                $0.model = Self.slot(of: node).flatMap { request.slotModels[$0] }
                $0.specHash = node.specHash(input: input)
            }
            running.insert(id)
            launches.append(Launch(node: node, input: input, bindings: bindings))
        }
        return launches
    }

    private func record(_ id: String, _ result: Result<WorkflowNodeOutcome, Error>, node: WorkflowNode?)
        -> WorkflowRunError?
    {
        run.update(id) {
            $0.progress = nil
            $0.mapItems = nil
        }
        switch result {
        case .success(let outcome):
            outputs[id] = outcome.output
            if node.flatMap(Self.slot(of:)) != nil, let model = outcome.model { lastInferenceModel = model }
            for (key, value) in Self.secretAnswers(outcome.output, node: node) { knownSecrets[key] = value }
            let recorded = Self.redactingSecrets(outcome.output, node: node)
            run.update(id) {
                $0.status = .done
                $0.output = recorded
                $0.model = outcome.model ?? $0.model
                $0.logs += outcome.logs
                $0.fetches += outcome.fetches
                $0.toolCalls += outcome.toolCalls
                $0.toolCallRecords += outcome.toolCallRecords
                $0.inputTokens = outcome.inputTokens
                $0.outputTokens = outcome.outputTokens
                $0.finishedAt = Date()
            }
            run.artifacts += outcome.artifacts
            return nil
        case .failure(let error):
            if error is CancellationError || Task.isCancelled {
                run.update(id) {
                    $0.status = .skipped
                    $0.finishedAt = Date()
                }
                return nil
            }
            let attempts = run.node(id)?.attempts
            let message = WorkflowFailure.message(error)
            var failure = WorkflowFailure.classify(error)
            if case .tool(let spec)? = node?.kind { failure.agent = spec.tool.agent }
            switch node?.onError ?? .fail {
            case .fail:
                run.update(id) {
                    $0.status = .failed
                    $0.error = message
                    $0.failure = failure
                    $0.finishedAt = Date()
                }
                return WorkflowRunError(nodeID: id, reason: message, attempts: attempts, failure: failure)
            case .continue:
                let output = Self.errorOutput(error, attempts: attempts)
                outputs[id] = output
                run.update(id) {
                    $0.status = .failed
                    $0.error = message
                    $0.failure = failure
                    $0.output = output
                    $0.logs.append(L("Failed; the run goes on because this step has on_error: continue."))
                    $0.finishedAt = Date()
                }
                return nil
            case .skip:
                outputs[id] = .null
                run.update(id) {
                    $0.status = .skipped
                    $0.error = message
                    $0.failure = failure
                    $0.logs.append(L("Failed; the step was skipped because it has on_error: skip."))
                    $0.finishedAt = Date()
                }
                return nil
            }
        }
    }

    /// What a step that failed with `on_error: continue` binds as, so
    /// later steps and `when` conditions can read what went wrong.
    static func errorOutput(_ error: Error, attempts: Int?) -> JSONValue {
        let failure = WorkflowFailure.classify(error)
        var fields: [String: JSONValue] = [
            "message": .string(WorkflowFailure.message(error)),
            "kind": .string(failure.kind),
            "retryable": .bool(failure.retryable),
            "fix_in": .string(failure.fixIn.rawValue),
        ]
        if let attempts { fields["attempts"] = .number(Double(attempts)) }
        return .object(["error": .object(fields)])
    }

    private func schedule(_ def: WorkflowDefinition, order: [String], workspace: URL) async -> WorkflowRunError? {
        let nodesByID = Dictionary(uniqueKeysWithValues: def.nodes.map { ($0.id, $0) })
        return await withTaskGroup(of: (String, Result<WorkflowNodeOutcome, Error>).self, isolation: self) {
            group in
            var running = Set<String>()
            var failure: WorkflowRunError?
            var launches = startReady(def, order: order, nodesByID: nodesByID, running: &running)
            while true {
                for launch in launches {
                    group.addTask { [self] in
                        (
                            launch.node.id,
                            await attemptNode(
                                launch.node, input: launch.input, bindings: launch.bindings, workspace: workspace)
                        )
                    }
                }
                await publish()
                guard let (id, result) = await group.next() else { break }
                running.remove(id)
                if let error = record(id, result, node: nodesByID[id]) {
                    if failure == nil { failure = error }
                    group.cancelAll()
                } else if case .failure(let error) = result, error is CancellationError || Task.isCancelled {
                    group.cancelAll()
                }
                launches =
                    failure != nil || Task.isCancelled
                    ? [] : startReady(def, order: order, nodesByID: nodesByID, running: &running)
            }
            return failure
        }
    }

    /// Secret dialog answers flow to downstream nodes but never into the
    /// stored run record.
    static func redactingSecrets(_ output: JSONValue, node: WorkflowNode?) -> JSONValue {
        guard case .dialog(let spec)? = node?.kind, case .object(var fields) = output else { return output }
        for field in spec.fields where field.type == .secret && fields[field.key] != nil {
            fields[field.key] = .string("••••••")
        }
        return .object(fields)
    }

    /// The secret answers a dialog node produced, by field key.
    static func secretAnswers(_ output: JSONValue, node: WorkflowNode?) -> [String: String] {
        guard case .dialog(let spec)? = node?.kind, case .object(let fields) = output else { return [:] }
        var out: [String: String] = [:]
        for field in spec.fields where field.type == .secret {
            if let value = fields[field.key]?.stringValue, !value.isEmpty { out[field.key] = value }
        }
        return out
    }

    // MARK: - Secrets

    /// The install secrets a code or http node declares, and only those.
    /// A binding must name a shared connection or this workflow's own
    /// account for the key; any other account is refused. Values come from
    /// the Keys store (the calling agent's value, else the shared one).
    private func resolveSecrets(for node: WorkflowNode) async throws -> [String: String] {
        let keys: [String]
        switch node.kind {
        case .code(let spec): keys = spec.secrets
        case .http(let spec): keys = spec.secretKeys
        default: return [:]
        }
        var values: [String: String] = [:]
        for key in keys {
            if let bound = request.secretAccounts[key], WorkflowSecretsKeychain.isConnectionAccount(bound) {
                // A shared connection: the person chose it in setup for
                // this key, so the workflow may read it, or the caller
                // agent's own session for the same service.
                let session = WorkflowConnectionSessions.binding(for: bound, agentId: request.caller.credentialAgentID)
                do {
                    if let value = try await request.connectionSecret(session), !value.isEmpty {
                        values[key] = value
                        knownSecrets[key] = value
                    }
                } catch {
                    throw WorkflowNodeError.unsupported(error.localizedDescription)
                }
                continue
            }
            if let bound = request.secretAccounts[key],
                !WorkflowSecretsKeychain.isSecretAccount(bound, scope: request.workflowID, key: key)
            {
                throw WorkflowNodeError.unsupported(
                    L("The secret \(key) is bound to an account outside this workflow. Open Set Up and enter it again."))
            }
            if let value = WorkflowCredentials.value(
                scope: request.workflowID, key: key, agentId: request.caller.credentialAgentID),
                !value.isEmpty
            {
                values[key] = value
                knownSecrets[key] = value
            }
        }
        return values
    }

    /// `run` with every known secret value replaced, for anything that
    /// leaves the runner: observers, the store, and the returned result.
    private func redacted(_ run: WorkflowRun) -> WorkflowRun {
        Self.redact(run, secrets: knownSecrets)
    }

    static func redact(_ run: WorkflowRun, secrets: [String: String]) -> WorkflowRun {
        let live = secrets.filter { $0.value.count >= SecretScrubber.minimumValueLength }
        guard !live.isEmpty else { return run }
        func text(_ s: String) -> String { SecretScrubber.scrub(s, secrets: live) }
        func value(_ v: JSONValue?) -> JSONValue? { v.map { $0.scrubbingStrings(text) } }
        var copy = run
        copy.input = value(run.input) ?? run.input
        copy.output = value(run.output)
        if var error = run.error {
            error.reason = text(error.reason)
            copy.error = error
        }
        copy.nodes = run.nodes.map { node in
            var n = node
            n.input = value(node.input)
            n.output = value(node.output)
            n.error = node.error.map(text)
            n.logs = node.logs.map(text)
            n.streamed = node.streamed.map(text)
            n.fetches = node.fetches.map(text)
            n.toolCallRecords = node.toolCallRecords.map { record in
                var r = record
                r.arguments = text(record.arguments)
                r.resultPreview = record.resultPreview.map(text)
                return r
            }
            return n
        }
        return copy
    }

    private static func slot(of node: WorkflowNode) -> String? {
        if case .inference(let spec) = node.kind { return spec.modelSlot }
        return nil
    }

    // MARK: - One node

    private func attemptNode(
        _ node: WorkflowNode, input: JSONValue, bindings: BindingContext, workspace: URL
    ) async -> Result<WorkflowNodeOutcome, Error> {
        if node.mode == .bypass {
            let output = node.bypassOutput(input: input, bindings: bindings)
            let issues = JSONSchemaValidator.validate(output, against: node.effectiveOutputSchema)
            guard issues.isEmpty else {
                let detail = issues.map(\.description).joined(separator: "; ")
                return .failure(
                    WorkflowNodeError.unsupported(
                        L("This step is bypassed, but the input it hands on doesn't match its output schema: \(detail). Turn bypass off, or give the step input shaped like its output.")))
            }
            return .success(
                WorkflowNodeOutcome(
                    output: output, logs: [L("Bypassed: the step did not run and handed its input on.")]))
        }
        if case .map(let spec) = node.kind {
            return await runMap(node, spec: spec, bindings: bindings, workspace: workspace)
        }
        // A form picked up after a relaunch has only the time it had left.
        let timeout = resumedTimeouts[node.id] ?? node.timeout
        return await attempt(
            node, recordAs: node.id, input: input, bindings: bindings, workspace: workspace, timeout: timeout,
            item: nil)
    }

    /// Runs one node's attempts with its retry policy. `recordAs` is the
    /// node record that takes attempts, logs, and tool calls: the node
    /// itself, or for an item of a map step, the map node (then `item`
    /// numbers the item in its logs and attempts are not counted).
    private func attempt(
        _ node: WorkflowNode, recordAs recordID: String, input: JSONValue, bindings: BindingContext,
        workspace: URL, timeout: TimeInterval, item: Int?
    ) async -> Result<WorkflowNodeOutcome, Error> {
        let schema = node.effectiveOutputSchema
        let model = Self.slot(of: node).flatMap { request.slotModels[$0] }
        let secrets: [String: String]
        do { secrets = try await resolveSecrets(for: node) } catch { return .failure(error) }
        let prefix = item.map { L("Item \($0 + 1): ") } ?? ""
        var lastError: Error = WorkflowNodeError.placeholder
        for attempt in 1 ... node.retry.maxAttempts {
            if Task.isCancelled { return .failure(CancellationError()) }
            if item == nil { run.update(recordID) { $0.attempts = attempt } }
            await publish()
            // Tokens from an inference step flow through an ordered stream
            // into the node record (a map item's would interleave with its
            // siblings', so items do not stream).
            let streaming = item == nil && Self.slot(of: node) != nil ? makeDeltaSink(recordID) : nil
            let context = WorkflowNodeContext(
                runID: request.runID, workflowID: request.workflowID, workflowName: request.workflowName,
                node: node, input: input, bindings: bindings, model: model,
                secretAccounts: request.secretAccounts, secrets: secrets, agentBindings: request.agentBindings,
                agentStepsAllowed: request.agentStepsAllowed, caller: request.caller, workspace: workspace,
                folderRoot: request.folderRoot ?? workspace, sandbox: sandboxContext,
                grantedPaths: nodeGrantedPaths,
                writableRoots: nodeWritableRoots,
                hostFiles: hostFileHooks(for: node, workspace: workspace),
                permissionScope: permissionScope,
                requestFolderGrant: folderGrantRequest(for: node),
                attempt: attempt, timeout: timeout,
                elapsedBeforeResume: resumedElapsed[node.id] ?? 0,
                residentParentModel: lastInferenceModel,
                wrapperAgentID: request.wrapperAgentID,
                onDelta: streaming?.onDelta,
                onProgress: makeProgressSink(recordID, item: item))
            defer {
                if let streaming {
                    streaming.finish()
                    run.update(recordID) { $0.streamed = nil }
                }
                if item == nil { run.update(recordID) { $0.progress = nil } }
            }
            let executor = self.executor
            let awaiting: WorkflowAwaitingUserHandler = { [weak self] waiting in
                await self?.setAwaitingUser(recordID, waiting: waiting)
            }
            // The step's time limit counts its own work, not a person
            // reading an approval card it raised.
            let clock = DeadlineClock()
            let outer = ChatExecutionContext.approvalWaitObserver
            let approvalWait = clock.observer(chainingTo: { waiting in
                await awaiting(waiting)
                await outer?(waiting)
            })
            do {
                let outcome = try await valueWithDeadline(seconds: timeout, clock: clock, operationName: node.name) {
                    try await ChatExecutionContext.$approvalWait.withValue(.init(notify: approvalWait)) {
                        try await executor.execute(context, awaitingUser: awaiting)
                    }
                }
                let issues = JSONSchemaValidator.validate(outcome.output, against: schema)
                guard issues.isEmpty else { throw WorkflowNodeError.outputMismatch(issues.map(\.description)) }
                return .success(outcome)
            } catch is DeadlineExceededError {
                lastError = WorkflowNodeError.timedOut(seconds: timeout.clampedInt(.toNearestOrAwayFromZero))
            } catch let recorded as RecordedNodeFailure {
                run.update(recordID) {
                    $0.toolCalls += recorded.toolCallRecords.map(\.name)
                    $0.toolCallRecords += recorded.toolCallRecords
                }
                lastError = recorded.underlying
            } catch {
                lastError = error
            }
            await setAwaitingUser(recordID, waiting: false)
            if lastError is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
            run.update(recordID) {
                $0.logs.append(prefix + L("Attempt \(attempt) failed: \(WorkflowFailure.message(lastError))"))
            }
            guard attempt < node.retry.maxAttempts, WorkflowNodeError.isRetryable(lastError) else { break }
            let delay = node.retry.backoffSeconds * pow(2, Double(attempt - 1))
            try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).clampedInt(in: 0...Int.max)))
        }
        return .failure(lastError)
    }

    // MARK: - Map steps

    /// Runs a map node: its `items` binding must be an array; its step runs
    /// once per item, `concurrency` at a time, with `{{item}}` and
    /// `{{index}}` bound, each item under the step's own timeout and retry
    /// policy and the whole under the map node's timeout. The output is
    /// `{items, count, failed}`, items in input order; with
    /// `on_item_error: skip` a failed item is null and listed under
    /// `failed`, otherwise the first failed item fails the step.
    private func runMap(
        _ node: WorkflowNode, spec: MapSpec, bindings: BindingContext, workspace: URL
    ) async -> Result<WorkflowNodeOutcome, Error> {
        let rendered = BindingRenderer.renderValue(spec.items, in: bindings)
        guard case .array(let items) = rendered else {
            return .failure(
                WorkflowNodeError.unsupported(
                    L("`items` must bind to an array; \(spec.items) gave \(Self.describe(rendered)).")))
        }
        guard items.count <= MapSpec.maximumItems else {
            return .failure(
                WorkflowNodeError.unsupported(
                    L("`items` has \(items.count) entries; a map step handles at most \(MapSpec.maximumItems).")))
        }
        let body = spec.body(parentID: node.id)
        run.update(node.id) { $0.attempts = 1 }
        if items.isEmpty {
            run.update(node.id) { $0.logs.append(L("No items; nothing to do.")) }
            return .success(WorkflowNodeOutcome(output: Self.mapOutput(results: [], failed: [])))
        }
        let concurrency = spec.effectiveConcurrency(body: body)
        run.update(node.id) {
            $0.logs.append(
                concurrency < spec.concurrency
                    ? L("Running \(items.count) media items one at a time.")
                    : L("Running \(items.count) items, up to \(concurrency) at a time."))
        }
        let timeout = node.timeout
        let started = Date()
        var results = [JSONValue](repeating: .null, count: items.count)
        var failed: [(index: Int, error: String)] = []
        var merged = WorkflowNodeOutcome(output: .null)
        var firstError: Error?
        var cancelled = false
        var settled = 0
        run.update(node.id) { $0.mapItems = Array(repeating: .pending, count: items.count) }

        await withTaskGroup(of: (Int, Result<WorkflowNodeOutcome, Error>).self, isolation: self) { group in
            var next = 0
            var inFlight = 0
            func launch() {
                while next < items.count, inFlight < concurrency {
                    let index = next
                    next += 1
                    inFlight += 1
                    setMapItem(node.id, index, .running)
                    let itemBindings = bindings.forItem(items[index], index: index)
                    let input = BindingRenderer.render(body.input, in: itemBindings)
                    let remaining = max(1, timeout - Date().timeIntervalSince(started))
                    group.addTask { [self] in
                        (
                            index,
                            await attempt(
                                body, recordAs: node.id, input: input, bindings: itemBindings, workspace: workspace,
                                timeout: min(body.timeout, remaining), item: index)
                        )
                    }
                }
            }
            launch()
            lastProgressPublish = Date()
            await publish()
            while let (index, result) = await group.next() {
                inFlight -= 1
                settled += 1
                switch result {
                case .success(let outcome):
                    setMapItem(node.id, index, .done)
                    results[index] = outcome.output
                    merged.logs += outcome.logs.map { L("Item \(index + 1): ") + $0 }
                    merged.fetches += outcome.fetches
                    merged.toolCalls += outcome.toolCalls
                    merged.toolCallRecords += outcome.toolCallRecords
                    merged.artifacts += outcome.artifacts
                    if let tokens = outcome.inputTokens { merged.inputTokens = (merged.inputTokens ?? 0) + tokens }
                    if let tokens = outcome.outputTokens { merged.outputTokens = (merged.outputTokens ?? 0) + tokens }
                    if merged.model == nil { merged.model = outcome.model }
                case .failure(let error):
                    if error is CancellationError {
                        setMapItem(node.id, index, .pending)
                        // Items we cancelled ourselves after a failure are
                        // not a cancellation of the run.
                        if firstError == nil && !cancelled {
                            cancelled = true
                            group.cancelAll()
                        }
                    } else if spec.onItemError == .skip {
                        setMapItem(node.id, index, .failed)
                        let message = WorkflowFailure.message(error)
                        failed.append((index, message))
                        run.update(node.id) {
                            $0.logs.append(L("Item \(index + 1) failed and was skipped: \(message)"))
                        }
                    } else {
                        setMapItem(node.id, index, .failed)
                        if firstError == nil { firstError = error }
                        group.cancelAll()
                    }
                }
                if firstError == nil, !cancelled, Date().timeIntervalSince(started) < timeout { launch() }
                await publishMapItems()
            }
        }
        if cancelled || Task.isCancelled { return .failure(CancellationError()) }
        if let firstError { return .failure(firstError) }
        if settled < items.count {
            return .failure(WorkflowNodeError.timedOut(seconds: timeout.clampedInt(.toNearestOrAwayFromZero)))
        }
        merged.output = Self.mapOutput(results: results, failed: failed)
        return .success(merged)
    }

    private func setMapItem(_ nodeID: String, _ index: Int, _ state: MapItemState) {
        run.update(nodeID) { record in
            guard var items = record.mapItems, items.indices.contains(index) else { return }
            items[index] = state
            record.mapItems = items
        }
    }

    /// Publishes item states at most every `streamPublishInterval`; the
    /// step's own completion carries the last of them in its output.
    private func publishMapItems() async {
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= Self.streamPublishInterval else { return }
        lastProgressPublish = now
        await publish()
    }

    static func mapOutput(results: [JSONValue], failed: [(index: Int, error: String)]) -> JSONValue {
        .object([
            "items": .array(results),
            "count": .number(Double(results.count)),
            "failed": .array(
                failed.sorted { $0.index < $1.index }.map {
                    .object(["index": .number(Double($0.index)), "error": .string($0.error)])
                }),
        ])
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .string: return "a string"
        case .number: return "a number"
        case .bool: return "a boolean"
        case .object: return "an object"
        case .array: return "an array"
        }
    }

    private func setAwaitingUser(_ id: String, waiting: Bool) async {
        if waiting {
            guard awaitingNodes.insert(id).inserted else { return }
            run.update(id) { $0.status = .awaitingUser }
        } else {
            guard awaitingNodes.remove(id) != nil else { return }
            run.update(id) { if $0.status == .awaitingUser { $0.status = .running } }
        }
        run.status = awaitingNodes.isEmpty ? .running : .awaitingUser
        await publish()
    }

    // MARK: - Finishing

    private func markUnfinished(_ status: NodeRunStatus) {
        for node in run.nodes where node.status == .pending || node.status == .running || node.status == .awaitingUser {
            run.update(node.nodeID) {
                $0.status = status
                $0.mapItems = nil
                if $0.finishedAt == nil, $0.startedAt != nil { $0.finishedAt = Date() }
            }
        }
    }

    private func finish(_ status: WorkflowRunStatus, error: WorkflowRunError?) async -> WorkflowRun {
        run.status = status
        run.error = error
        run.finishedAt = Date()
        awaitingNodes.removeAll()
        await publish()
        return redacted(run)
    }

    private func publish() async {
        await observer(redacted(run))
    }

    // MARK: - Streaming

    struct DeltaSink {
        let onDelta: @Sendable (String) -> Void
        let finish: @Sendable () -> Void
    }

    /// Seconds between publishes while a step streams; the final text
    /// arrives with the step's completion regardless.
    static let streamPublishInterval: TimeInterval = 0.15

    /// A sink whose deltas are appended, in order, to `recordID`'s
    /// `streamed` text, publishing at most every `streamPublishInterval`.
    private func makeDeltaSink(_ recordID: String) -> DeltaSink {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { [weak self] in
            var lastPublish = Date.distantPast
            for await delta in stream {
                // Finished steps take no more text: a delta still buffered
                // when the step ended must not land on its record.
                guard let self, !Task.isCancelled else { return }
                let publishNow = await self.appendStreamed(recordID, delta, since: lastPublish)
                if publishNow { lastPublish = Date() }
            }
        }
        return DeltaSink(
            onDelta: { delta in continuation.yield(delta) },
            finish: {
                continuation.finish()
                consumer.cancel()
            })
    }

    /// Progress reports for `recordID`, published at most every
    /// `streamPublishInterval`. An item of a map step reports on the map's
    /// record, prefixed with its number.
    private func makeProgressSink(_ recordID: String, item: Int?) -> @Sendable (WorkflowNodeProgress) -> Void {
        { [weak self] progress in
            Task { await self?.setProgress(recordID, progress, item: item) }
        }
    }

    private func setProgress(_ recordID: String, _ progress: WorkflowNodeProgress, item: Int?) async {
        guard let status = run.node(recordID)?.status, status == .running || status == .awaitingUser else { return }
        var progress = progress
        if let item { progress.detail = L("Item \(item + 1): ") + progress.detail }
        run.update(recordID) { $0.progress = progress }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= Self.streamPublishInterval || progress.fraction == 1 else {
            return
        }
        lastProgressPublish = now
        await publish()
    }

    /// Appends `delta` and publishes when `since` is long enough ago.
    private func appendStreamed(_ recordID: String, _ delta: String, since: Date) async -> Bool {
        guard !Task.isCancelled else { return false }
        run.update(recordID) { $0.streamed = ($0.streamed ?? "") + delta }
        guard Date().timeIntervalSince(since) >= Self.streamPublishInterval else { return false }
        await publish()
        return true
    }
}
