//
//  WorkflowRunService.swift
//  osaurus
//
//  Starts, tracks, and cancels workflow runs. Resolves an installed
//  workflow's slot models and secret accounts on the main actor, hands the
//  run to a `WorkflowRunner`, and records every state change in
//  `WorkflowRunStore`. Callers either wait for the run to finish or, in
//  Work Mode, until it parks on a dialog (`awaiting_user`) and keeps going
//  in the background.
//

import Foundation

/// Test and eval seam for the node executor. Task-scoped, so it reaches only
/// the runs started under it and parallel callers never share one.
enum WorkflowExecutorSeam {
    @TaskLocal static var override: (@Sendable () -> WorkflowNodeExecuting)?
}

@MainActor
public final class WorkflowRunService {
    public static let shared = WorkflowRunService()

    private var tasks: [UUID: Task<WorkflowRun, Never>] = [:]
    /// Lease keepalive per in-flight run (`WorkflowTaskRecorder.alive`).
    private var keepalives: [UUID: Task<Void, Never>] = [:]
    /// Live runs by the tool call that started them; finished runs are
    /// found through the `run_id` in the call's result.
    private var runsByToolCall: [String: UUID] = [:]
    /// Each in-flight run's step timeouts, by node id.
    private var stepTimeouts: [UUID: [String: TimeInterval]] = [:]
    private var parkWaiters: [UUID: [CheckedContinuation<WorkflowRun, Never>]] = [:]
    private var resumePassDone = false
    private var resumePassWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Starting

    /// Slot models for a template under `bindings`, as the setup checker
    /// resolves them.
    static func slotModels(for template: Template, bindings: InstallBindings) -> [String: String] {
        let env = SetupChecker.Environment.live()
        var out: [String: String] = [:]
        for slot in template.requirements.models {
            if let model = SetupChecker.resolvedModel(for: slot, bindings: bindings, environment: env) {
                out[slot.slot] = model
            }
        }
        return out
    }

    /// The folder a run's tool steps work in, when its caller has one.
    struct CallerFolder: Equatable {
        var url: URL
        /// Opened from a security-scoped bookmark for this run; closed
        /// when the run ends.
        var isScoped: Bool
    }

    /// The calling chat's folder, else the calling agent's working folder.
    /// Nil leaves tools in the run's workspace.
    static func callerFolder(
        _ caller: WorkflowCaller,
        agentFolder: (UUID) -> (bookmark: Data?, path: String?)? = { AgentManager.shared.workingFolder(for: $0) }
    ) -> CallerFolder? {
        if let path = caller.folderPath, !path.isEmpty {
            return CallerFolder(url: URL(fileURLWithPath: path, isDirectory: true), isScoped: false)
        }
        guard let agentID = caller.agentID, let folder = agentFolder(agentID) else { return nil }
        if let bookmark = folder.bookmark, let url = FolderContextService.resolveSecurityScopedURL(from: bookmark),
            url.startAccessingSecurityScopedResource()
        {
            return CallerFolder(url: url, isScoped: true)
        }
        guard let path = folder.path, !path.isEmpty else { return nil }
        return CallerFolder(url: URL(fileURLWithPath: path, isDirectory: true), isScoped: false)
    }

    @discardableResult
    public func start(
        _ workflow: InstalledWorkflow, input: JSONValue, caller: WorkflowCaller, runID: UUID = UUID()
    ) -> UUID {
        let folder = Self.callerFolder(caller)
        let request = Self.request(
            workflow, input: input, caller: caller, runID: runID, folderRoot: folder?.url, resuming: nil)
        return start(request, releasing: folder?.isScoped == true ? folder?.url : nil)
    }

    /// A run of an agent's wrapper: its one step hands `input.task` to the
    /// agent. Recorded with `wrapperAgentID`, so it stays out of workflow
    /// run history; the Tasks view still shows it.
    @discardableResult
    func startWrapper(_ wrapper: AgentWrapper, input: JSONValue, caller: WorkflowCaller) -> UUID {
        let folder = Self.callerFolder(caller)
        var request = Self.request(
            wrapper.installed, input: input, caller: caller, runID: UUID(), folderRoot: folder?.url, resuming: nil)
        request.wrapperAgentID = wrapper.agentID
        return start(request, releasing: folder?.isScoped == true ? folder?.url : nil)
    }

    private static func request(
        _ workflow: InstalledWorkflow, input: JSONValue, caller: WorkflowCaller, runID: UUID, folderRoot: URL?,
        resuming: WorkflowRun?
    ) -> WorkflowRunner.Request {
        var request = WorkflowRunner.Request(
            runID: runID, workflowID: workflow.id, workflowName: workflow.name,
            template: MCPServerResolution.liveRunnable(workflow.template, bindings: workflow.bindings),
            slotModels: Self.slotModels(for: workflow.template, bindings: workflow.bindings),
            secretAccounts: workflow.bindings.secrets, caller: caller, input: input, folderRoot: folderRoot,
            boundFolders: workflow.bindings.folders, folderGrants: workflow.bindings.folderGrants,
            persistFolderGrant: { [id = workflow.id] path, access in
                await MainActor.run { InstalledWorkflowStore.shared.addFolderGrant(path, access: access, id: id) }
            },
            resuming: resuming)
        request.folderReadGrants = workflow.bindings.folderReadGrants
        request.replaceGrants = workflow.bindings.replaceGrants
        request.persistReplaceGrant = { [id = workflow.id] path in
            await MainActor.run { InstalledWorkflowStore.shared.addReplaceGrant(path, id: id) }
        }
        request.agentBindings = workflow.bindings.agents
        request.agentStepsAllowed = workflow.agentStepsAllowed
        return request
    }

    // MARK: - Relaunch

    /// Picks up every run a previous launch left running or waiting on a
    /// form: the run keeps its id, input, caller, and the outputs of the
    /// nodes that had finished; unfinished nodes run again and a waiting
    /// form is shown again with the time it had left. Test runs, runs of a
    /// workflow that is gone or changed since, and runs whose workflow now
    /// needs setup are closed as cancelled instead. Returns the ids picked
    /// up. `limitedTo` narrows the pass to some runs (tests).
    @discardableResult
    public func resumeAbandonedRuns(limitedTo runIDs: Set<UUID>? = nil) -> [UUID] {
        var resumed: [UUID] = []
        for run in WorkflowRunStore.shared.abandonedRuns()
        where tasks[run.id] == nil && (runIDs?.contains(run.id) ?? true) {
            guard let reason = Self.reasonNotToResume(run) else {
                guard let workflow = InstalledWorkflowStore.shared.workflow(id: run.workflowID) else { continue }
                let folder = Self.callerFolder(run.caller)
                let request = Self.request(
                    workflow, input: run.input, caller: run.caller, runID: run.id, folderRoot: folder?.url,
                    resuming: run)
                start(request, releasing: folder?.isScoped == true ? folder?.url : nil)
                resumed.append(run.id)
                continue
            }
            WorkflowRunStore.shared.closeAbandonedRun(run, reason: reason)
        }
        if runIDs == nil {
            resumePassDone = true
            let waiters = resumePassWaiters
            resumePassWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        return resumed
    }

    /// Waits until the launch's `resumeAbandonedRuns()` pass has picked up
    /// or closed what the previous launch left open.
    func awaitResumePass() async {
        guard !resumePassDone else { return }
        await withCheckedContinuation { resumePassWaiters.append($0) }
    }

    /// Why an abandoned run is closed rather than picked up; nil when it
    /// can continue.
    static func reasonNotToResume(_ run: WorkflowRun) -> String? {
        if run.isTest { return L("Osaurus quit before the test run finished.") }
        if run.isDerived { return L("Osaurus quit before the run finished. Ask again in chat to run it again.") }
        guard let workflow = InstalledWorkflowStore.shared.workflow(id: run.workflowID) else {
            return L("Osaurus quit before the run finished, and the workflow is no longer installed.")
        }
        guard workflow.template.version == run.templateVersion, workflow.template.id == run.templateID else {
            return L("Osaurus quit before the run finished, and the workflow has changed since.")
        }
        guard
            SetupChecker.check(
                workflow, secrets: .caller(run.caller.credentialAgentID), attended: run.caller.isAttended
            ).blocking.isEmpty
        else {
            return L("Osaurus quit before the run finished, and the workflow needs setup.")
        }
        return nil
    }

    // MARK: - Retrying

    /// Why a failed run cannot continue from its failed step; nil when it
    /// can.
    public static func reasonNotToRetry(_ run: WorkflowRun) -> String? {
        guard run.status == .failed else { return L("Only a failed run can be retried from its failed step.") }
        if run.isTest { return L("Test runs are retried from the Architect with `workflow_test`.") }
        if run.isDerived { return L("This run was started from chat for one request. Ask again in chat instead.") }
        guard let workflow = InstalledWorkflowStore.shared.workflow(id: run.workflowID) else {
            return L("The workflow is no longer installed.")
        }
        guard workflow.template.version == run.templateVersion, workflow.template.id == run.templateID else {
            return L("The workflow has changed since this run; start a new run instead.")
        }
        let report = SetupChecker.check(
            workflow, secrets: .caller(run.caller.credentialAgentID), attended: run.caller.isAttended)
        guard report.blocking.isEmpty else {
            return SetupChecker.onlyKeysMissing(report)
                ? L("The workflow is missing keys: \(SetupChecker.missingKeys(report).joined(separator: ", ")). Add them in Settings → Vault.")
                : L("The workflow needs setup.")
        }
        return nil
    }

    /// Continues a failed run as a new run: steps that finished keep their
    /// outputs, the failed step and everything after it run again, in the
    /// same workspace. The new run records the old one as `retry_of`.
    /// Returns the new run id, or nil with `reasonNotToRetry`.
    @discardableResult
    public func retry(runID: UUID, caller: WorkflowCaller? = nil) -> UUID? {
        guard let previous = WorkflowRunStore.shared.run(id: runID), Self.reasonNotToRetry(previous) == nil,
            let workflow = InstalledWorkflowStore.shared.workflow(id: previous.workflowID)
        else { return nil }
        var retryCaller = caller ?? previous.caller
        retryCaller.taskId = nil
        if caller == nil {
            // The person asked; the chat that first called is not waiting.
            retryCaller.kind = retryCaller.kind == .workflow ? .user : retryCaller.kind
            retryCaller.toolCallID = nil
            retryCaller.background = false
        }
        let folder = Self.callerFolder(retryCaller)
        var request = Self.request(
            workflow, input: previous.input, caller: retryCaller, runID: UUID(), folderRoot: folder?.url,
            resuming: nil)
        request.retrying = previous
        return start(request, releasing: folder?.isScoped == true ? folder?.url : nil)
    }

    /// A test run of a draft. Results are labeled as tests.
    @discardableResult
    public func startTest(
        draftID: UUID, template: Template, bindings: InstallBindings, input: JSONValue,
        startAt: String? = nil, pinned: [String: JSONValue] = [:], reusing: WorkflowRun? = nil,
        sessionID: String? = nil
    ) -> UUID {
        var request = WorkflowRunner.Request(
            workflowID: draftID, workflowName: template.name,
            template: MCPServerResolution.liveRunnable(template, bindings: bindings),
            slotModels: Self.slotModels(for: template, bindings: bindings),
            secretAccounts: bindings.secrets,
            caller: WorkflowCaller(kind: .test, sessionID: sessionID), input: input,
            startAt: startAt, pinned: pinned, boundFolders: bindings.folders, folderGrants: bindings.folderGrants,
            persistFolderGrant: { path, access in
                await MainActor.run { WorkflowDraftStore.shared.addFolderGrant(path, access: access, draftID: draftID) }
            })
        Self.applyDraftGrants(bindings, draftID: draftID, to: &request)
        request.reusing = reusing
        request.agentBindings = bindings.agents
        return start(request)
    }

    /// A draft's read-only and replace grants, kept on the draft until it is saved.
    private static func applyDraftGrants(_ bindings: InstallBindings, draftID: UUID, to request: inout WorkflowRunner.Request) {
        request.folderReadGrants = bindings.folderReadGrants
        request.replaceGrants = bindings.replaceGrants
        request.persistReplaceGrant = { path in
            await MainActor.run { WorkflowDraftStore.shared.addReplaceGrant(path, draftID: draftID) }
        }
    }

    /// A run of an unsaved draft for one chat request (the Architect
    /// inline). The caller is the chat, not a test: its forms
    /// and tool cards are the chat's. Recorded as `ephemeral`, so it stays
    /// out of workflow run history, and on the draft as a test run, so it
    /// counts as evidence when the person keeps the workflow.
    @discardableResult
    func startEphemeral(
        draftID: UUID, template: Template, bindings: InstallBindings, input: JSONValue, caller: WorkflowCaller
    ) -> UUID {
        let folder = Self.callerFolder(caller)
        var request = WorkflowRunner.Request(
            workflowID: draftID, workflowName: template.name,
            template: MCPServerResolution.liveRunnable(template, bindings: bindings),
            slotModels: Self.slotModels(for: template, bindings: bindings),
            secretAccounts: bindings.secrets, caller: caller, input: input, folderRoot: folder?.url,
            boundFolders: bindings.folders, folderGrants: bindings.folderGrants,
            persistFolderGrant: { path, access in
                await MainActor.run { WorkflowDraftStore.shared.addFolderGrant(path, access: access, draftID: draftID) }
            })
        Self.applyDraftGrants(bindings, draftID: draftID, to: &request)
        request.ephemeral = true
        request.agentBindings = bindings.agents
        // Started from inside a handoff's tool call: the run's own agent
        // steps must not look nested under that handoff.
        let runID = SubagentSession.$activeKindId.withValue(nil) {
            start(request, releasing: folder?.isScoped == true ? folder?.url : nil)
        }
        WorkflowDraftStore.shared.recordTestRun(draftID, runID: runID)
        return runID
    }

    /// A run of a first-run ask (`PreparedAskCatalog`): built in memory, so
    /// it is recorded like an unsaved draft and kept out of run history.
    @discardableResult
    func startPrepared(_ workflow: InstalledWorkflow, input: JSONValue, caller: WorkflowCaller) -> UUID {
        let folder = Self.callerFolder(caller)
        var request = Self.request(
            workflow, input: input, caller: caller, runID: UUID(), folderRoot: folder?.url, resuming: nil)
        request.ephemeral = true
        return start(request, releasing: folder?.isScoped == true ? folder?.url : nil)
    }

    /// `releasing` is a security-scoped folder opened for the run.
    @discardableResult
    func start(_ request: WorkflowRunner.Request, releasing scopedFolder: URL? = nil) -> UUID {
        let executor = WorkflowExecutorSeam.override?() ?? LiveWorkflowNodeExecutor()
        let runner = WorkflowRunner(request: request, executor: executor) { run in
            await MainActor.run { WorkflowRunService.shared.observe(run) }
        }
        let runID = request.runID
        if let callID = request.caller.toolCallID { runsByToolCall[callID] = runID }
        stepTimeouts[runID] = Dictionary(
            (request.template.workflow?.nodes ?? []).map { ($0.id, $0.timeout) }, uniquingKeysWith: max)
        WorkflowActivityLogger.shared.begin(runID: runID, definition: request.template.workflow)
        WorkflowTaskRecorder.began(request, resuming: request.resuming != nil)
        FeatureTelemetry.workflowRunStarted(caller: request.caller.kind.rawValue, resumed: request.resuming != nil)
        let ownerTaskId = request.caller.taskId
        keepalives[runID]?.cancel()
        keepalives[runID] = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TaskLease.heartbeatInterval))
                guard !Task.isCancelled else { return }
                WorkflowTaskRecorder.alive(runID: runID, ownerTaskId: ownerTaskId)
            }
        }
        tasks[runID] = Task {
            let run = await runner.execute()
            if !WorkflowArtifactForwarder.forwardable(run).isEmpty {
                await Task.detached(priority: .userInitiated) { WorkflowArtifactForwarder.forward(run) }.value
            }
            scopedFolder?.stopAccessingSecurityScopedResource()
            await MainActor.run { WorkflowRunService.shared.finished(run) }
            return run
        }
        return runID
    }

    // MARK: - Observing

    private func observe(_ run: WorkflowRun) {
        WorkflowRunStore.shared.record(run)
        WorkflowActivityLogger.shared.observe(run)
        WorkflowTaskRecorder.observed(run)
        if run.status == .awaitingUser, let waiters = parkWaiters.removeValue(forKey: run.id) {
            waiters.forEach { $0.resume(returning: run) }
        }
    }

    private func finished(_ run: WorkflowRun) {
        WorkflowRunStore.shared.record(run)
        WorkflowActivityLogger.shared.finished(run)
        WorkflowTaskRecorder.finished(run)
        FeatureTelemetry.workflowRunFinished(
            caller: run.caller.kind.rawValue,
            status: run.status.rawValue,
            duration: run.finishedAt.map { $0.timeIntervalSince(run.startedAt) }
        )
        tasks[run.id] = nil
        stepTimeouts[run.id] = nil
        keepalives.removeValue(forKey: run.id)?.cancel()
        if let callID = run.caller.toolCallID { runsByToolCall[callID] = nil }
        parkWaiters.removeValue(forKey: run.id)?.forEach { $0.resume(returning: run) }
        if run.status == .completed { InstalledWorkflowStore.shared.clearStaleSetupFlags(ids: [run.workflowID]) }
        NotificationCenter.default.post(name: .workflowRunFinished, object: nil, userInfo: ["runID": run.id])
    }

    public func isActive(_ runID: UUID) -> Bool { tasks[runID] != nil }

    /// The longest timeout of a step now running in a run the chat
    /// `sessionID` started, or nil when it has none going. The runner fails
    /// a step at its timeout, so that bounds how long such a run stays quiet.
    func runningStepTimeout(sessionID: String) -> TimeInterval? {
        let runs = WorkflowRunStore.shared.live.values.filter {
            $0.caller.sessionID == sessionID && !$0.status.isTerminal && tasks[$0.id] != nil
        }
        var longest: TimeInterval?
        for run in runs {
            guard let timeouts = stepTimeouts[run.id] else { continue }
            let running = run.nodes.filter { $0.status == .running || $0.status == .awaitingUser }
            // A step the definition doesn't name (a map item) gets the longest the run allows.
            let timeout = running.isEmpty
                ? timeouts.values.max()
                : running.map { timeouts[$0.nodeID] ?? timeouts.values.max() ?? 0 }.max()
            if let timeout { longest = max(longest ?? 0, timeout) }
        }
        return longest
    }

    func liveRunID(forToolCall callID: String) -> UUID? { runsByToolCall[callID] }

    // MARK: - Waiting

    /// Waits for the run to finish.
    public func result(of runID: UUID) async -> WorkflowRun? {
        if let task = tasks[runID] { return await task.value }
        return WorkflowRunStore.shared.run(id: runID)
    }

    /// Waits for the run to finish, or to park on a dialog. A parked run
    /// keeps going; its result arrives later through `result(of:)`.
    public func settledOrParked(_ runID: UUID) async -> WorkflowRun? {
        guard tasks[runID] != nil else { return WorkflowRunStore.shared.run(id: runID) }
        if let live = WorkflowRunStore.shared.run(id: runID), live.status == .awaitingUser { return live }
        return await withCheckedContinuation { cont in
            parkWaiters[runID, default: []].append(cont)
        }
    }

    // MARK: - Cancelling

    public func cancel(_ runID: UUID) {
        tasks[runID]?.cancel()
        DialogCoordinator.shared.cancelAll(runID: runID)
    }

    /// Test seam: waits out every in-flight run.
    func drainForTesting() async {
        for task in tasks.values { _ = await task.value }
    }
}

extension Notification.Name {
    /// `userInfo["runID"]`: the run that reached a terminal state.
    public static let workflowRunFinished = Notification.Name("ai.osaurus.workflowRunFinished")
}
