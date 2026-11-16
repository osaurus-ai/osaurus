//
//  ToolNodeExecutor.swift
//  osaurus
//
//  Tool nodes: one call to an agent tool through `ToolRegistry.execute`,
//  so the call gets the same permission gate, approval card, argument
//  preflight, timeout, and file history as a chat tool call. The node's
//  bound input is the tool's arguments; a success envelope's `result` is
//  the node output, and a failure envelope fails the node with its kind,
//  message, and `retryable` flag. A call refused for naming a folder
//  outside the run's scopes asks the person to allow it and runs once more.
//  `share_artifact` adds the file to the run's files; its output is
//  `{filename, path}`.
//

import Foundation

enum ToolNodeExecutor {

    /// What the node needs from a registered tool.
    struct Resolved: Sendable {
        var spec: Tool
        var outputSchema: JSONValue?
    }

    /// The pieces the executor talks to, injectable for tests.
    struct Runtime: Sendable {
        var resolve: @Sendable (_ name: String) async -> Resolved?
        var execute: @Sendable (_ name: String, _ arguments: String, _ scope: ToolExecutionScope) async throws -> String
        /// The agent a step's `tool.agent` names, or nil when none here matches.
        var resolveAgent: @Sendable (_ reference: String) async -> WorkflowStepAgent.Match? = { reference in
            await MainActor.run { WorkflowStepAgent.resolveLive(reference) }
        }

        static let live = Runtime(
            resolve: { name in
                await MainActor.run {
                    WorkflowToolCatalog.ensureRegistered()
                    guard let spec = ToolRegistry.shared.specs(forTools: [name]).first else { return nil }
                    return Resolved(spec: spec, outputSchema: ToolRegistry.shared.outputSchema(forTool: name))
                }
            },
            execute: { name, arguments, scope in
                try await executeInScope(name: name, arguments: arguments, scope: scope)
            }
        )
    }

    /// Runs one tool through the registry with only that tool executable.
    /// Thrown gate refusals (policy deny, user deny, missing permission)
    /// become failure envelopes; cancellation propagates.
    static func executeInScope(name: String, arguments: String, scope: ToolExecutionScope) async throws -> String {
        do {
            return try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                try await ToolRegistry.shared.execute(name: name, argumentsJSON: arguments)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failureEnvelope(for: error, tool: name)
        }
    }

    static func failureEnvelope(for error: Error, tool: String) -> String {
        let ns = error as NSError
        let kind: ToolEnvelope.Kind
        if ns.domain == "ToolRegistry" {
            switch ns.code {
            case 3, 6: kind = .rejected
            case 4: kind = .userDenied
            case 7: kind = .permissionDenied
            default: kind = .executionError
            }
        } else {
            kind = .executionError
        }
        return ToolEnvelope.failure(kind: kind, message: WorkflowFailure.message(error), tool: tool, retryable: false)
    }

    /// Eval seam: the runtime for one step, so a fixture can stand in for a
    /// person's calendar or mail. Nil in the app.
    @TaskLocal static var runtimeOverride: (@Sendable (WorkflowNodeContext) -> Runtime)?

    static func run(spec: ToolNodeSpec, context: WorkflowNodeContext) async throws -> WorkflowNodeOutcome {
        try await run(spec: spec, context: context, runtime: runtimeOverride?(context) ?? .live)
    }

    static func run(spec: ToolNodeSpec, context: WorkflowNodeContext, runtime: Runtime) async throws
        -> WorkflowNodeOutcome
    {
        let name = spec.tool.name
        if WorkflowValidator.isExcludedFromWorkflows(name) {
            throw WorkflowNodeError.unsupported(L("\(name) cannot run as a workflow step."))
        }
        guard let resolved = await runtime.resolve(name) else {
            throw WorkflowNodeError.unsupported(L("The tool \(name) is not available on this Mac."))
        }
        var stepAgent: WorkflowStepAgent.Match?
        if let reference = spec.tool.agent {
            guard let match = await runtime.resolveAgent(reference) else {
                throw WorkflowNodeError.toolFailed(
                    tool: name, kind: "agent_missing", message: WorkflowStepAgent.missingMessage(reference),
                    retryable: false)
            }
            stepAgent = match
        }
        let arguments = context.input.isEmptyObject ? "{}" : context.input.compactJSONString
        let scope = ToolExecutionScope(exposed: [resolved.spec])
        var records: [WorkflowToolCallRecord] = []
        func call() async throws -> String {
            let started = Date()
            let result = try await asStepAgent(stepAgent, tool: name) { try await runtime.execute(name, arguments, scope) }
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            records.append(
                WorkflowToolCallRecord(
                    name: name, arguments: arguments, result: result, durationMs: durationMs,
                    isError: ToolEnvelope.isError(result)))
            return result
        }
        var result = try await call()

        if ToolEnvelope.isError(result), let path = WorkflowFolderGrant.requestedPath(in: result),
            let ask = context.requestFolderGrant
        {
            let access = WorkflowFolderGrant.requestedAccess(in: result)
            let decision: WorkflowFolderGrantDecision
            do {
                decision = try await ask(path, access)
            } catch {
                throw RecordedNodeFailure(underlying: error, toolCallRecords: records)
            }
            let folder = FolderRequirement.grantRoot(for: path)
            guard decision != .deny else {
                throw RecordedNodeFailure(
                    underlying: WorkflowNodeError.toolFailed(
                        tool: name, kind: "folder_denied",
                        message: access == .write
                            ? L("The person did not allow this workflow to save in \(folder.path).")
                            : L("The person did not allow this workflow to use \(folder.path)."),
                        retryable: false),
                    toolCallRecords: records)
            }
            let paths = (ChatExecutionContext.workflowGrantedPaths ?? context.grantedPaths) + [folder]
            let writable = ChatExecutionContext.workflowWritableRoots.map { access == .write ? $0 + [folder] : $0 }
            result = try await ChatExecutionContext.$workflowGrantedPaths.withValue(paths) {
                try await ChatExecutionContext.$workflowWritableRoots.withValue(writable) { try await call() }
            }
        }

        if ToolEnvelope.isError(result), WorkflowFolderGrant.isReplaceDenied(result) {
            throw RecordedNodeFailure(
                underlying: WorkflowNodeError.toolFailed(
                    tool: name, kind: "replace_denied", message: parseFailure(result).message, retryable: false),
                toolCallRecords: records)
        }

        if ToolEnvelope.isError(result) {
            let failure = parseFailure(result)
            throw RecordedNodeFailure(
                underlying: WorkflowNodeError.toolFailed(
                    tool: name, kind: failure.kind, message: failure.message, retryable: failure.retryable),
                toolCallRecords: records)
        }
        if let missing = commandNotFoundFailure(tool: name, envelope: result) {
            throw RecordedNodeFailure(
                underlying: WorkflowNodeError.toolFailed(
                    tool: name, kind: "command_not_found", message: missing, retryable: false),
                toolCallRecords: records)
        }
        let schema = context.node.effectiveOutputSchema(toolOutputSchema: resolved.outputSchema)
        var output = output(of: result, declaredSchema: schema.isEmptySchema ? nil : schema)
        var artifacts: [WorkflowArtifact] = []
        if name == WorkflowArtifactCollector.shareToolName {
            let shared = WorkflowArtifactCollector.share(
                result, nodeID: context.node.id, scope: WorkflowFileScope(context: context),
                into: OsaurusPaths.workflowRunArtifacts(workflowID: context.workflowID, runID: context.runID))
            if !records.isEmpty {
                records[records.count - 1] = WorkflowToolCallRecord(
                    name: name, arguments: arguments, result: shared.modelResult,
                    durationMs: records[records.count - 1].durationMs, isError: shared.artifact == nil)
            }
            guard let artifact = shared.artifact else {
                let failure = parseFailure(shared.modelResult)
                throw RecordedNodeFailure(
                    underlying: WorkflowNodeError.toolFailed(
                        tool: name, kind: failure.kind, message: failure.message, retryable: false),
                    toolCallRecords: records)
            }
            artifacts = [artifact]
            output = .object(["filename": .string(artifact.filename), "path": .string(artifact.path)])
        }
        let issues = JSONSchemaValidator.validate(output, against: schema)
        if !issues.isEmpty {
            throw RecordedNodeFailure(
                underlying: WorkflowNodeError.outputMismatch(issues.map(\.description)), toolCallRecords: records)
        }
        return WorkflowNodeOutcome(
            output: output, toolCalls: records.map(\.name), toolCallRecords: records, artifacts: artifacts)
    }

    /// Runs `body` as the step's agent. An Apple app tool then runs on that
    /// agent's own switch: the step's grant no longer authorizes it. A
    /// folder tool reads in the agent's working folder.
    static func asStepAgent<T>(
        _ agent: WorkflowStepAgent.Match?, tool: String, _ body: () async throws -> T
    ) async throws -> T {
        guard let agent else { return try await body() }
        var granted = ChatExecutionContext.workflowGrantedToolNames
        if AppleApp.app(forTool: tool) != nil { granted?.remove(tool) }
        let folder = AppleApp.app(forTool: tool) == nil ? agent.workingFolder : nil
        let root = folder ?? ChatExecutionContext.currentFolderRoot
        let paths = folder.map { (ChatExecutionContext.workflowGrantedPaths ?? []) + [$0] }
            ?? ChatExecutionContext.workflowGrantedPaths
        // The agent's own working folder stays as writable as it is in its chats.
        let writable = folder.flatMap { folder in ChatExecutionContext.workflowWritableRoots.map { $0 + [folder] } }
            ?? ChatExecutionContext.workflowWritableRoots
        return try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
            try await ChatExecutionContext.$workflowGrantedToolNames.withValue(granted) {
                try await ChatExecutionContext.$currentFolderRoot.withValue(root) {
                    try await ChatExecutionContext.$workflowGrantedPaths.withValue(paths) {
                        try await ChatExecutionContext.$workflowWritableRoots.withValue(writable) { try await body() }
                    }
                }
            }
        }
    }

    /// The node output of a success envelope: its `result`, with a string
    /// as `{text}`, another scalar as `{value}`, and null as `{}`. When a
    /// schema applies and the result is JSON as text (MCP servers mirror
    /// `structuredContent` that way), the decoded JSON, unless the schema
    /// itself declares `text`: then the text is the output.
    static func output(of envelope: String, declaredSchema: JSONValue?) -> JSONValue {
        guard let object = JSONValue.parse(envelope)?.objectValue else {
            return .object(["text": .string(envelope)])
        }
        let result = object["result"] ?? .null
        if let declaredSchema, declaredSchema.value(atPath: "properties.text") == nil,
            case .object(let fields) = result, fields.count == 1,
            let text = fields["text"]?.stringValue, let decoded = JSONValue.parse(text)
        {
            switch decoded {
            case .object, .array: return decoded
            default: break
            }
        }
        // Later nodes bind into the output by field, so scalars get one.
        switch result {
        case .object, .array: return result
        case .null: return .object([:])
        case .string: return .object(["text": result])
        default: return .object(["value": result])
        }
    }

    /// `shell_run` reports a missing or non-executable program as a
    /// success envelope with exit 127 / 126. Passing that downstream as a
    /// result hides the real problem, so the step fails with the shell's
    /// message and the fix: declare the program as a dependency.
    static func commandNotFoundFailure(tool: String, envelope: String) -> String? {
        guard tool == "shell_run", let object = JSONValue.parse(envelope)?.objectValue,
            let result = object["result"]?.objectValue,
            case .number(let code)? = result["exit_code"]
        else { return nil }
        let exit = Int(code)
        guard exit == 127 || exit == 126 else { return nil }
        let stderr = (result["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let detail = lastLine.isEmpty ? L("exit code \(exit)") : lastLine
        if exit == 127, let program = macOnlyProgram(namedIn: lastLine) {
            return L("\(detail). `\(program)` is a macOS program, and this step runs in the workflow's Linux sandbox; use a Linux program and declare it as a dependency.")
        }
        return exit == 127
            ? L("\(detail). The program is not installed where this step runs; declare it as a dependency so setup installs it.")
            : L("\(detail). The program cannot be executed where this step runs.")
    }

    /// The macOS-only program a shell's "<program>: not found" line names.
    private static func macOnlyProgram(namedIn line: String) -> String? {
        guard
            let match = line.range(
                of: #"[A-Za-z0-9_./-]+(?=: (?:command )?not found)"#, options: .regularExpression)
        else { return nil }
        let program = String(line[match].split(separator: "/").last ?? "")
        return WorkflowValidator.macOnlyPrograms.contains(program) ? program : nil
    }

    static func parseFailure(_ envelope: String) -> (kind: String, message: String, retryable: Bool) {
        let object = JSONValue.parse(envelope)?.objectValue ?? [:]
        let kind = object["kind"]?.stringValue ?? ToolEnvelope.Kind.executionError.rawValue
        var message =
            object["message"]?.stringValue ?? object["error"]?.stringValue ?? ToolEnvelope.failureMessage(envelope)
        // A tool's advice for this failure (search's "Try a broader query…")
        // is the only fix a later step or the person can act on.
        if let hint = object["hint"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty,
            !message.contains(hint)
        {
            message += " " + hint
        }
        let retryable: Bool
        if case .bool(let flag)? = object["retryable"] { retryable = flag } else { retryable = false }
        return (kind, message, retryable)
    }
}
