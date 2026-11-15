//
//  ArchitectTools.swift
//  osaurus
//
//  The Architect's draft tools. Each works on the draft bound to the
//  current chat and refuses outside an Architect turn; the composer also
//  keeps them out of every other agent's schema
//  (`ToolRegistry.architectToolNames`). `workflow_propose_save` never
//  saves: ChatView ends the run on success and shows a confirm card, and
//  only the user's click writes the template.
//

import Foundation

enum ArchitectToolGate {
    static func failure(tool: String) -> String? {
        guard ChatExecutionContext.currentAgentId == Agent.architectId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Workflow drafting tools are only available to the Architect.",
                tool: tool,
                retryable: false
            )
        }
        return nil
    }

    /// The current chat's draft, created on first use.
    @MainActor
    static func currentDraft() -> WorkflowDraft? {
        guard let sessionID = ChatExecutionContext.currentSessionId else { return nil }
        let store = WorkflowDraftStore.shared
        if let draft = store.draft(forSession: sessionID) { return draft }
        // A chat dispatched without a window (self-heal) carries the key of
        // the draft it should start from.
        if let id = UUID(uuidString: sessionID),
            let key = BackgroundTaskManager.shared.liveTask(forSessionId: id)?.externalSessionKey,
            let seeded = store.claimSeed(key: key, sessionID: sessionID)
        {
            return seeded
        }
        return store.create(sessionID: sessionID)
    }

    /// The run `run_id` names, or the draft's repair run. Only runs of
    /// installed workflows and the draft's own tests are readable.
    @MainActor
    static func run(_ args: [String: JSONValue], draft: WorkflowDraft?, tool: String) -> Result<WorkflowRun, ToolFailure> {
        let raw = args["run_id"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        guard let id = raw.flatMap(UUID.init(uuidString:)) ?? draft?.repairRunID else {
            return .failure(
                .init(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: raw == nil
                            ? "Pass `run_id` (from `workflow_runs` `list`); this chat has no run to fix."
                            : "`run_id` must be a run's UUID.",
                        field: "run_id", tool: tool)))
        }
        guard let run = WorkflowRunStore.shared.run(id: id), WorkflowRunsTool.readable(run, draft: draft) else {
            return .failure(
                .init(ToolEnvelope.failure(kind: .notFound, message: "No run with id \(id.uuidString).", tool: tool)))
        }
        return .success(run)
    }

    static func noSessionFailure(tool: String) -> String {
        ToolEnvelope.failure(
            kind: .unavailable,
            message: "There is no chat to attach a workflow draft to.",
            tool: tool,
            retryable: false
        )
    }

    static func arguments(_ json: String, tool: String) -> Result<[String: JSONValue], ToolFailure> {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let args = JSONValue.parse(trimmed.isEmpty ? "{}" : trimmed)?.objectValue else {
            return .failure(
                ToolFailure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs, message: "Arguments must be a JSON object.", tool: tool)))
        }
        return .success(args)
    }

    struct ToolFailure: Error {
        let envelope: String
        init(_ envelope: String) { self.envelope = envelope }
    }

    /// Foundation form of an encodable value for `ToolEnvelope.success`.
    static func foundation<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        return object
    }

    static func issueList(_ issues: [WorkflowIssue]) -> [[String: Any]] {
        issues.map { issue in
            var out: [String: Any] = ["message": issue.message]
            if let node = issue.nodeID { out["node_id"] = node }
            return out
        }
    }
}

// MARK: - workflow_draft

final class WorkflowDraftTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    static let toolName = "workflow_draft"
    let name = WorkflowDraftTool.toolName
    /// Runs on its own unless the person sets it to Ask or Deny in
    /// Settings → Architect → Permissions.
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto
    let description =
        "Read or change this chat's workflow draft. `get` returns the definition, every issue that would stop "
        + "it from saving or testing (placeholders included), what this Mac still needs before it can run "
        + "(`setup`), and what each step reaches (`risks`: hosts, files, shell or browser, cloud models). `patch` applies `ops` in order; if any op fails, nothing changes. One "
        + "patch can carry many ops, and each call costs a step: lay out the whole graph in one patch "
        + "(info, schemas, every `plan_placeholder`, every edge), then fill every placeholder with "
        + "`update_node` (set `kind` and its spec) in the next. `tools` "
        + "finds the tools a `tool` or agentic node can call on this Mac: with `query` (a few words), the "
        + "best matches with their argument `parameters` and, when declared, their `output_schema`; "
        + "without it, every tool by name and summary. `media_models` lists the image and video models a "
        + "`media` step can run on here, with what each can do and the limits of its fields."

    /// Matches `tools` returns with their full schemas.
    static let toolMatchLimit = 8

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("get"), .string("patch"), .string("tools"), .string("media_models"),
                ]),
            ]),
            "why": WorkflowDraftTool.stringField(
                "For `patch`: one sentence on why this change, in the person's terms (\"Adds a retry so a slow "
                    + "API doesn't fail the run\"). Shown beside the change in the draft's history."),
            "query": WorkflowDraftTool.stringField(
                "For `tools`: words to search names, descriptions, and providers for. Without it, `tools` lists "
                    + "every tool by name and summary; with it, the best matches with their argument schemas."),
            "ops": .object([
                "type": .string("array"),
                "description": .string(
                    "For `patch`. Each op is an object with `op`: plan_placeholder {id, name, intent?}; "
                        + "update_node {id, node: {the fields to change: name, kind and its spec, input, ...}} (only `id` sits beside `node`); remove_node {id}; add_edge {from, to, when?, on?}; "
                        + "remove_edge {from, to}; set_schemas {input_schema?, output_schema?}; set_output {output}; "
                        + "set_info {name?, summary?}; declare_slot {slot, preferred?, strictness?, locality?, "
                        + "needs_tool_use?}; declare_secret {key, label, help?, oauth2?}; declare_connection "
                        + "{provider? | service?, key?, label?, help?, scopes?, sign_in?, oauth2?} (providers: "
                        + "\(ConnectionProviders.summary)); declare_server {name, directory_id? | url? | command?, "
                        + "args?, transport?, auth?, remove?}; declare_dependency {manager, packages, binaries?}; "
                        + "declare_folder {key, label, help?, access?, hint?, remove?}; add_example {name, input} (or {name, remove: true}); "
                        + "detach {}. The node format is in your instructions."),
                // Every op field is declared: providers that follow the
                // schema strictly emit only declared properties.
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(true),
                    "properties": .object([
                        "op": .object([
                            "type": .string("string"),
                            "enum": .array(WorkflowDraftOp.names.map { .string($0) }),
                        ]),
                        "id": WorkflowDraftTool.stringField("Node id (slug)."),
                        "name": WorkflowDraftTool.stringField(
                            "Placeholder, workflow, example, or MCP server name (a node's new name goes inside `node`)."),
                        "intent": WorkflowDraftTool.stringField("One line: what the placeholder step does."),
                        "summary": WorkflowDraftTool.stringField("One-line workflow summary."),
                        "node": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(true),
                            "description": .string("Node fields; the spec sits under the key named by `kind`."),
                            "properties": .object([
                                "id": WorkflowDraftTool.stringField(nil),
                                "name": WorkflowDraftTool.stringField(nil),
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array(WorkflowNode.kindNames.map { .string($0) }),
                                ]),
                                "inference": WorkflowDraftTool.openObject(nil),
                                "dialog": WorkflowDraftTool.openObject(nil),
                                "code": WorkflowDraftTool.openObject(nil),
                                "tool": WorkflowDraftTool.openObject(nil),
                                "http": WorkflowDraftTool.openObject(nil),
                                "wait": WorkflowDraftTool.openObject(nil),
                                "map": WorkflowDraftTool.openObject(nil),
                                "workflow": WorkflowDraftTool.openObject(nil),
                                "state": WorkflowDraftTool.openObject(nil),
                                "reply": WorkflowDraftTool.openObject(nil),
                                "media": WorkflowDraftTool.openObject(nil),
                                "agent": WorkflowDraftTool.openObject(nil),
                                "mode": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("always"), .string("bypass")]),
                                ]),
                                "on_error": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("fail"), .string("continue"), .string("skip")]),
                                ]),
                                "join": .object([
                                    "type": .string("string"), "enum": .array([.string("any"), .string("all")]),
                                ]),
                                "input": .object(["description": .string("Binding: a {{...}} string, or an object whose fields are {{...}} strings or literal true/false, numbers, or null.")]),
                                "output_schema": WorkflowDraftTool.openObject(nil),
                                "timeout": .object(["type": .string("number")]),
                                "retry": WorkflowDraftTool.openObject("{max_attempts, backoff_seconds}"),
                            ]),
                        ]),
                        "from": WorkflowDraftTool.stringField("Edge source node id."),
                        "to": WorkflowDraftTool.stringField("Edge target node id."),
                        "when": WorkflowDraftTool.openObject("{path, op, value} or {all|any: [...]} or {not: {...}}"),
                        "on": .object([
                            "type": .string("string"),
                            "enum": .array([.string("success"), .string("error"), .string("always")]),
                        ]),
                        "input_schema": WorkflowDraftTool.openObject(nil),
                        "output_schema": WorkflowDraftTool.openObject(nil),
                        "output": .object(["description": .string("Binding: a {{...}} string, or an object whose fields are {{...}} strings or literal true/false, numbers, or null.")]),
                        "slot": WorkflowDraftTool.stringField("Model slot name."),
                        "preferred": WorkflowDraftTool.stringField("Model id, from `workflow_discover` `models`."),
                        "strictness": .object([
                            "type": .string("string"),
                            "enum": .array(ModelStrictness.allCases.map { .string($0.rawValue) }),
                            "description": .string(
                                "always: `preferred` is a prerequisite (setup blocks without it, no other model may "
                                    + "be picked). preferred (default): a suggestion the person may change at setup."),
                        ]),
                        "locality": .object([
                            "type": .string("string"),
                            "enum": .array(ModelLocality.allCases.map { .string($0.rawValue) }),
                            "description": .string("local_only: only models on this Mac. cloud_allowed (default): any."),
                        ]),
                        "needs_tool_use": .object(["type": .string("boolean")]),
                        "key": WorkflowDraftTool.stringField("Secret or folder key."),
                        "label": WorkflowDraftTool.stringField("Secret, connection, or folder label."),
                        "help": WorkflowDraftTool.stringField(nil),
                        "oauth2": WorkflowDraftTool.openObject(
                            "{authorize_url, token_url, scopes?, client_id?, requires_client_secret?, authorize_parameters?, "
                                + "scope_separator?, client_secret_basic?, json_token_body?}"),
                        "provider": WorkflowDraftTool.stringField("For `declare_connection`: a catalog provider id."),
                        "service": WorkflowDraftTool.stringField("For `declare_connection`: the API host of a service not in the catalog."),
                        "scopes": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "sign_in": .object([
                            "type": .string("boolean"),
                            "description": .string("For `declare_connection`: false takes a personal token instead of the browser sign-in."),
                        ]),
                        "directory_id": WorkflowDraftTool.stringField("For `declare_server`: an Osaurus MCP Directory id."),
                        "url": WorkflowDraftTool.stringField("For `declare_server`: the server's https URL."),
                        "command": WorkflowDraftTool.stringField("For `declare_server` with transport stdio."),
                        "args": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "transport": .object([
                            "type": .string("string"),
                            "enum": .array(MCPProviderTransport.allCases.map { .string($0.rawValue) }),
                        ]),
                        "auth": .object([
                            "type": .string("string"),
                            "enum": .array(MCPProviderAuthType.allCases.map { .string($0.rawValue) }),
                        ]),
                        "access": .object(["type": .string("string"), "enum": .array([.string("read"), .string("write")])]),
                        "hint": WorkflowDraftTool.stringField("For `declare_folder`: a suggested folder, e.g. ~/Documents/Invoices."),
                        "remove": .object(["type": .string("boolean")]),
                        "manager": .object([
                            "type": .string("string"), "enum": .array([.string("apk"), .string("pip"), .string("npm")]),
                        ]),
                        "packages": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "binaries": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        // Untyped: a node input misplaced here gets the
                        // op parser's "move it into `node`" answer.
                        "input": .object([
                            "description": .string(
                                "For `add_example`: the example input object. A node's input goes inside `node`.")
                        ]),
                    ]),
                    "required": .array([.string("op")]),
                ]),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    private static func stringField(_ description: String?) -> JSONValue {
        var field: [String: JSONValue] = ["type": .string("string")]
        if let description { field["description"] = .string(description) }
        return .object(field)
    }

    private static func openObject(_ description: String?) -> JSONValue {
        var field: [String: JSONValue] = ["type": .string("object"), "additionalProperties": .bool(true)]
        if let description { field["description"] = .string(description) }
        return .object(field)
    }

    func execute(argumentsJSON: String) async throws -> String {
        if let gate = ArchitectToolGate.failure(tool: name) { return gate }
        let args: [String: JSONValue]
        switch ArchitectToolGate.arguments(argumentsJSON, tool: name) {
        case .success(let a): args = a
        case .failure(let f): return f.envelope
        }
        let action = args["action"]?.stringValue ?? "get"
        let tool = name
        let query = args["query"]?.stringValue
        if action == "media_models" {
            let candidates = await MediaModelResolver.loadedLiveCandidates()
            return ToolEnvelope.success(tool: tool, result: Self.mediaModels(candidates))
        }
        return await MainActor.run {
            if action == "tools" {
                let entries = WorkflowToolCatalog.entries(query: query)
                let searched = !(query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let listed = searched ? entries.prefix(Self.toolMatchLimit).map(\.json) : entries.map(\.summaryJSON)
                return ToolEnvelope.success(
                    tool: tool,
                    result: [
                        "count": entries.count,
                        "tools": ArchitectToolGate.foundation(JSONValue.array(listed)),
                    ])
            }
            guard let draft = ArchitectToolGate.currentDraft() else {
                return ArchitectToolGate.noSessionFailure(tool: tool)
            }
            switch action {
            case "get":
                return ToolEnvelope.success(tool: tool, result: Self.describe(draft))
            case "patch":
                guard case .array(let raw)? = args["ops"], !raw.isEmpty else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: "`patch` needs a non-empty `ops` array.", field: "ops",
                        tool: tool)
                }
                var ops: [WorkflowDraftOp] = []
                for (index, item) in raw.enumerated() {
                    do {
                        ops.append(try WorkflowDraftOp.parse(item))
                    } catch let e as WorkflowDraftOp.ParseError {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs, message: "ops[\(index)]: \(e.message) No ops were applied.",
                            field: "ops", tool: tool)
                    } catch {
                        return ToolEnvelope.failure(kind: .invalidArgs, message: "\(error)", tool: tool)
                    }
                }
                do {
                    let result = try WorkflowDraftStore.shared.applyArchitectPatch(
                        draft.id, ops: ops, why: args["why"]?.stringValue)
                    let issues = WorkflowValidator.validate(result.definition, allowPlaceholders: true)
                    var out: [String: Any] = [
                        "applied": ops.count,
                        "touched_nodes": result.touchedNodeIDs,
                        "node_count": result.definition.nodes.count,
                        "placeholders": result.definition.nodes.filter { $0.kind == nil }.map(\.id),
                        "issues": ArchitectToolGate.issueList(issues),
                    ]
                    let warnings = WorkflowValidator.warnings(
                        result.definition, toolOutputSchema: WorkflowToolCatalog.publishedOutputSchema)
                    if !warnings.isEmpty { out["warnings"] = ArchitectToolGate.issueList(warnings) }
                    if let editing = ArchitectToolGate.currentDraft().flatMap(Self.editing) {
                        out["editing"] = editing
                    }
                    return ToolEnvelope.success(tool: tool, result: out)
                } catch let f as WorkflowDraftPatcher.Failure {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: "ops[\(f.index)]: \(f.message) No ops were applied.",
                        field: "ops", tool: tool)
                } catch {
                    return ToolEnvelope.failure(kind: .executionError, message: "\(error)", tool: tool)
                }
            default:
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`action` must be get, patch, tools, or media_models.",
                    field: "action", tool: tool)
            }
        }
    }

    /// What `media_models` returns: each ready model with the actions it
    /// can do, where it runs, and its field limits.
    static func mediaModels(_ candidates: [MediaModelCandidate]) -> [String: Any] {
        let ready = candidates.filter(\.ready)
        let models = ready.map { c -> [String: Any] in
            var m: [String: Any] = [
                "id": c.id,
                "name": c.displayName,
                "locality": c.isLocal ? "local" : "remote",
                "actions": MediaAction.allCases.filter(c.supports).map(\.rawValue),
            ]
            if let family = c.family { m["family"] = family }
            if !c.isLocal { m["billable"] = true }
            let limits = c.constraintsSummary
            if !limits.isEmpty { m["limits"] = ArchitectToolGate.foundation(JSONValue.object(limits)) }
            return m
        }
        var out: [String: Any] = ["count": models.count, "models": models]
        let missing = MediaAction.allCases.filter { action in !ready.contains { $0.supports(action) } }
        if !missing.isEmpty {
            out["unavailable"] = missing.map { action -> [String: Any] in
                let reason = MediaModelResolver.Failure.noneInstalled(action, action == .video ? .any : .local)
                return ["action": action.rawValue, "reason": reason.localizedDescription]
            }
        }
        return out
    }

    @MainActor
    static func describe(_ draft: WorkflowDraft) -> [String: Any] {
        let template = draft.template()
        let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
        let bindings = WorkflowDraftStore.shared.testBindings(draft.id)
        let report = SetupChecker.check(template, bindings: bindings, subjectId: draft.id, agentsByName: true)
        let catalog = ConfigModelReference.liveCatalog()
        let history = WorkflowStepRisk.history(from: draft.testRunIDs.compactMap { WorkflowRunStore.shared.run(id: $0) })
        var out: [String: Any] = [
            "name": draft.name,
            "summary": draft.summary,
            "definition": ArchitectToolGate.foundation(draft.definition),
            "valid": issues.isEmpty,
            "issues": ArchitectToolGate.issueList(issues),
            "requirements": ArchitectToolGate.foundation(template.requirements),
            "setup": report.items.map {
                ["title": $0.title, "detail": $0.detail, "value": $0.value, "blocking": $0.isBlocking] as [String: Any]
            },
            // What the person sees on each step card; mention the risky
            // ones when describing the workflow.
            "risks": WorkflowStepRisk.report(
                draft.definition,
                locality: { WorkflowStepRisk.locality(slot: $0, bindings: bindings, catalog: catalog) },
                history: history),
        ]
        let warnings = WorkflowValidator.warnings(
            draft.definition, toolOutputSchema: WorkflowToolCatalog.publishedOutputSchema)
        if !warnings.isEmpty { out["warnings"] = ArchitectToolGate.issueList(warnings) }
        if let editing = editing(draft) { out["editing"] = editing }
        if let last = draft.testRunIDs.last, let run = WorkflowRunStore.shared.run(id: last) {
            var summary = WorkflowTestTool.summary(run)
            let notes = WorkflowRunObservations.notes(run, definition: draft.definition)
            if !notes.isEmpty { summary["observations"] = notes }
            out["last_test"] = summary
        }
        return out
    }

    /// The saved workflow a save would make the next version of.
    @MainActor
    static func editing(_ draft: WorkflowDraft) -> [String: Any]? {
        DraftEditing(draft).map { ["name": $0.name, "base_version": $0.version] }
    }
}

// MARK: - workflow_test

final class WorkflowTestTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    static let toolName = "workflow_test"
    let name = WorkflowTestTool.toolName
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto
    let description =
        "Run the draft for real with the user's models and secrets and return every node's status, model, "
        + "duration, output, and error. Dialog nodes ask the user in this chat during the test, so `input` holds "
        + "only the workflow's input, never a dialog's answers. Leave folder and file input fields out of "
        + "`input`: the user picks them in a native picker in this chat (listed as `picked_inputs`), and later "
        + "tests reuse that pick (`reused_inputs`). Pass `input`, or `examples` to "
        + "run saved examples (added with the `add_example` op) in turn and report pass/fail for each. "
        + "`from_node` re-runs one step and everything after it, reusing the last test's (or `from_run`'s) input "
        + "and the results (and files) of the steps before it; it refuses when one of those steps changed since, "
        + "and names it. "
        + "`from_run` re-tests a failed run of the saved workflow: its input, starting at its failed step, with "
        + "the finished steps' real outputs pinned."
    let bypassRegistryTimeout = true
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "input": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "description": .string("Workflow input matching the input schema."),
            ]),
            "examples": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Run these saved examples one after another (`[\"*\"]` for all) and report each result. "
                        + "Cannot combine with `input`, `from_node`, or `from_run`."),
            ]),
            "from_run": .object([
                "type": .string("string"),
                "description": .string(
                    "A failed run's id (default: the run this chat was asked to fix; pass \"repair\" to say so). "
                        + "Uses its input, starts at its failed step, and pins the outputs of the steps that had "
                        + "finished. With `from_node`, the run whose earlier results are reused."),
            ]),
            "from_node": .object([
                "type": .string("string"),
                "description": .string(
                    "Node id to re-run from, reusing the last test's input and its results for the steps before "
                        + "it (or `from_run`'s). `input`, if given, must be that run's input."),
            ]),
            "fresh_state": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Empty the draft's `state` tables first, so the run sees what a first run would. Test runs "
                        + "share the draft's store, so a later test otherwise sees what earlier tests stored."),
            ]),
        ]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let gate = ArchitectToolGate.failure(tool: name) { return gate }
        var args: [String: JSONValue]
        switch ArchitectToolGate.arguments(argumentsJSON, tool: name) {
        case .success(let a): args = a
        case .failure(let f): return f.envelope
        }
        let tool = name
        if args["fresh_state"]?.boolValue == true {
            let cleared: Bool = await MainActor.run {
                guard let draft = ArchitectToolGate.currentDraft() else { return false }
                WorkflowStateStore.shared.deleteAll(workflow: draft.id)
                return true
            }
            guard cleared else { return ArchitectToolGate.noSessionFailure(tool: tool) }
        }
        if case .array(let names)? = args["examples"], !names.isEmpty {
            return await runExamples(names.compactMap(\.stringValue), args: args, tool: tool)
        }
        if let fromNode = args["from_node"]?.stringValue {
            return await runFromNode(fromNode, args: args, tool: tool)
        }
        var picks = PathPicks(input: args["input"] ?? .object([:]))
        if args["from_run"] == nil {
            switch await Self.pickPathInputs(picks.input, tool: tool) {
            case .success(let resolved): picks = resolved
            case .failure(let f): return f.envelope
            }
            args["input"] = picks.input
        }
        let start: Result<UUID, ArchitectToolGate.ToolFailure> = await MainActor.run {
            guard let draft = ArchitectToolGate.currentDraft() else {
                return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool)))
            }
            let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
            guard issues.isEmpty else { return .failure(.init(Self.invalidEnvelope(issues, tool: tool))) }
            var input = args["input"] ?? .object([:])
            var startAt: String?
            var pinned: [String: JSONValue] = [:]
            if let raw = args["from_run"]?.stringValue {
                var lookup = args
                lookup["run_id"] = raw.lowercased() == "repair" ? nil : .string(raw)
                switch ArchitectToolGate.run(lookup, draft: draft, tool: tool) {
                case .failure(let f): return .failure(f)
                case .success(let run):
                    let plan = Self.retestPlan(from: run, definition: draft.definition)
                    if args["input"] == nil { input = plan.input }
                    startAt = plan.startAt
                    pinned = plan.pinned
                }
            }
            return Self.start(draft: draft, input: input, startAt: startAt, pinned: pinned, tool: tool)
        }
        let runID: UUID
        switch start {
        case .success(let id): runID = id
        case .failure(let f): return f.envelope
        }
        guard let run = await Self.awaitResult(runID) else {
            return ToolEnvelope.failure(kind: .executionError, message: "The test run was lost.", tool: tool)
        }
        var result = Self.summary(run)
        picks.annotate(&result)
        if let hint = await MainActor.run(body: { Self.failureHint(run) }) { result["hint"] = hint }
        await Self.addObservations(run, to: &result)
        return ToolEnvelope.success(tool: tool, result: result)
    }

    /// The test input once its folder and file fields are filled.
    struct PathPicks {
        var input: JSONValue
        /// Field key → path an earlier test used.
        var reused: [String: String] = [:]
        /// Field key → path the person picked for this test.
        var picked: [String: String] = [:]

        func annotate(_ result: inout [String: Any]) {
            if !reused.isEmpty { result["reused_inputs"] = reused }
            if !picked.isEmpty { result["picked_inputs"] = picked }
        }
    }

    static let pathDialogNodeID = "input"

    /// Shows the picker card and waits for its answers. Replaced in tests.
    @MainActor static var presentPathDialog: (PendingDialog) async throws -> [String: JSONValue] = {
        try await DialogCoordinator.shared.present($0)
    }

    /// Fills the folder and file inputs `input` leaves out: with an earlier
    /// test's pick while it still exists, else with what the person picks
    /// in a form card in this chat.
    @MainActor
    private static func pickPathInputs(
        _ input: JSONValue, tool: String
    ) async -> Result<PathPicks, ArchitectToolGate.ToolFailure> {
        guard let draft = ArchitectToolGate.currentDraft() else {
            return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool)))
        }
        var picks = PathPicks(input: input)
        let missing = WorkflowDraftTester.missingPathFields(draft.definition, input: input)
        // A draft the test refuses says why before anyone is asked to pick.
        guard !missing.isEmpty, WorkflowDraftTester.isReady(draft) else { return .success(picks) }
        let previous = draft.testRunIDs.reversed().compactMap { WorkflowRunStore.shared.run(id: $0)?.input }
        var values = input.objectValue ?? [:]
        var ask: [DialogField] = []
        for field in missing {
            if let path = WorkflowDraftTester.reusablePick(field, previousInputs: previous) {
                values[field.key] = .string(path)
                picks.reused[field.key] = path
            } else {
                var required = field
                required.required = true
                ask.append(required)
            }
        }
        picks.input = .object(values)
        guard !ask.isEmpty else { return .success(picks) }
        let dialog = pathDialog(draft: draft, fields: ask)
        do {
            let answers = try await presentPathDialog(dialog)
            var values = picks.input.objectValue ?? [:]
            for field in dialog.fields {
                guard let path = answers[field.key]?.stringValue else { continue }
                values[field.key] = .string(path)
                picks.picked[field.key] = path
            }
            picks.input = .object(values)
            return .success(picks)
        } catch WorkflowNodeError.dialogDismissed {
            let labels = dialog.fields.map(\.label).joined(separator: ", ")
            return .failure(
                .init(
                    ToolEnvelope.failure(
                        kind: .userDenied,
                        message: "The person closed the picker for \(labels), so nothing ran. Do not ask them to "
                            + "type a path; ask whether they want to test now, and call `workflow_test` again "
                            + "when they do.",
                        tool: tool, retryable: false)))
        } catch {
            return .failure(
                .init(ToolEnvelope.failure(kind: .executionError, message: "The test was cancelled.", tool: tool)))
        }
    }

    /// The card that asks the person for a test's folders and files. It
    /// belongs to the draft, so it shows in this chat with the draft's
    /// other test forms.
    @MainActor
    static func pathDialog(draft: WorkflowDraft, fields: [DialogField]) -> PendingDialog {
        let name = draft.template().name
        return PendingDialog(
            id: UUID(), runID: UUID(), workflowID: draft.id, workflowName: name, nodeID: pathDialogNodeID,
            title: L("Choose what to test with"),
            message: L("Pick what this test of \(name) should use. Later tests use the same choice."),
            fields: fields, prefill: [:],
            caller: WorkflowCaller(kind: .test, sessionID: ChatExecutionContext.currentSessionId),
            createdAt: Date())
    }

    /// `from_node`: the last test again from one step, reusing what came
    /// before it.
    private func runFromNode(_ nodeID: String, args: [String: JSONValue], tool: String) async -> String {
        let started: Result<(UUID, [String]), ArchitectToolGate.ToolFailure> = await MainActor.run {
            guard let draft = ArchitectToolGate.currentDraft() else {
                return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool)))
            }
            let last: WorkflowRun
            if let raw = args["from_run"]?.stringValue {
                var lookup = args
                lookup["run_id"] = raw.lowercased() == "repair" ? nil : .string(raw)
                switch ArchitectToolGate.run(lookup, draft: draft, tool: tool) {
                case .failure(let f): return .failure(f)
                case .success(let run): last = run
                }
            } else if let run = draft.testRunIDs.last.flatMap({ WorkflowRunStore.shared.run(id: $0) }) {
                last = run
            } else {
                return .failure(
                    .init(
                        ToolEnvelope.failure(
                            kind: .rejected, message: "There is no earlier test to reuse. Run the whole test first.",
                            tool: tool)))
            }
            if let input = args["input"], input != last.input {
                return .failure(
                    .init(
                        ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message: "`from_node` reuses the input of run \(last.id.uuidString), "
                                + "\(last.input.compactJSONString.prefix(300)); the steps before `\(nodeID)` ran on "
                                + "it. Drop `input`, or run the whole test with the new input.",
                            field: "input", tool: tool)))
            }
            switch WorkflowDraftTester.reusePlan(from: last, nodeID: nodeID, definition: draft.definition) {
            case .failure(let refusal):
                var metadata: [String: Any] = ["last_test": last.id.uuidString]
                if case .changed(let ids) = refusal { metadata["changed"] = ids }
                if case .unfinished(let ids) = refusal { metadata["unfinished"] = ids }
                return .failure(
                    .init(
                        ToolEnvelope.failure(
                            kind: .rejected, message: refusal.message, field: "from_node", tool: tool,
                            metadata: metadata)))
            case .success(let plan):
                return Self.start(
                    draft: draft, input: plan.input, startAt: plan.startAt, pinned: plan.pinned, reusing: last,
                    tool: tool
                ).map { ($0, plan.reused) }
            }
        }
        let runID: UUID
        let reused: [String]
        switch started {
        case .success(let pair): (runID, reused) = pair
        case .failure(let f): return f.envelope
        }
        guard let run = await Self.awaitResult(runID) else {
            return ToolEnvelope.failure(kind: .executionError, message: "The test run was lost.", tool: tool)
        }
        var result = Self.summary(run)
        result["reused_nodes"] = reused
        if let hint = await MainActor.run(body: { Self.failureHint(run) }) { result["hint"] = hint }
        await Self.addObservations(run, to: &result)
        return ToolEnvelope.success(tool: tool, result: result)
    }

    /// The draft's view of `run`: steps that finished without doing their
    /// work. Advisory; the run's status is unchanged.
    @MainActor
    static func observations(_ run: WorkflowRun) -> [String] {
        guard let draft = WorkflowDraftStore.shared.draft(id: run.workflowID) else { return [] }
        return WorkflowRunObservations.notes(run, definition: draft.definition)
    }

    private static func addObservations(_ run: WorkflowRun, to result: inout [String: Any]) async {
        let (notes, draft) = await MainActor.run { (observations(run), WorkflowDraftStore.shared.draft(id: run.workflowID)) }
        if !notes.isEmpty { result["observations"] = notes }
        guard let draft else { return }
        addAccess(draft, run: run, to: &result)
    }

    /// What the draft reads and saves on this Mac, and what this run saved
    /// there, for the Architect to say in its own reply.
    static func addAccess(_ draft: WorkflowDraft, run: WorkflowRun?, to result: inout [String: Any]) {
        let scope = WorkflowAccessScope.derive(draft.definition)
        result["access"] = scope.payload
        guard let run, !run.hostWrites.isEmpty else { return }
        let roots = scope.resolved(input: run.input, dialogOutputs: [:], boundFolders: draft.bindings.folders).map(\.url)
        result["saved_on_mac"] = WorkflowHostWrite.summaries(run.hostWrites, roots: roots).map(\.text)
    }

    @MainActor
    private static func start(
        draft: WorkflowDraft, input: JSONValue, startAt: String?, pinned: [String: JSONValue],
        reusing: WorkflowRun? = nil, tool: String
    ) -> Result<UUID, ArchitectToolGate.ToolFailure> {
        switch WorkflowDraftTester.start(
            draftID: draft.id, input: input, startAt: startAt, pinned: pinned, reusing: reusing,
            sessionID: ChatExecutionContext.currentSessionId)
        {
        case .success(let runID):
            return .success(runID)
        case .failure(.missingDraft):
            return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool)))
        case .failure(.invalid(let issues)):
            return .failure(.init(invalidEnvelope(issues, tool: tool)))
        case .failure(.needsSetup(let blocking)):
            let reasons = blocking.map { "\($0.title): \($0.detail)" }
            return .failure(
                .init(
                    ToolEnvelope.failure(
                        kind: .unavailable,
                        message: "The draft needs setup on this Mac before it can run: "
                            + reasons.joined(separator: "; ")
                            + ". The setup wizard is open in the sidebar; ask the user to finish it, then test again.",
                        tool: tool, retryable: false,
                        metadata: ["status": "needs_setup", "reasons": reasons])))
        }
    }

    /// Waits for the run; cancelling the tool call cancels the run.
    private static func awaitResult(_ runID: UUID) async -> WorkflowRun? {
        await withTaskCancellationHandler {
            await WorkflowRunService.shared.result(of: runID)
        } onCancel: {
            Task { @MainActor in WorkflowRunService.shared.cancel(runID) }
        }
    }

    /// Runs saved examples one after another and reports each.
    private func runExamples(_ requested: [String], args: [String: JSONValue], tool: String) async -> String {
        for key in ["input", "from_node", "from_run"] where args[key] != nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`examples` cannot be combined with `\(key)`.", field: "examples", tool: tool)
        }
        let picked: Result<(WorkflowDraft, [WorkflowExample]), ArchitectToolGate.ToolFailure> = await MainActor.run {
            guard let draft = ArchitectToolGate.currentDraft() else {
                return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool)))
            }
            let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
            guard issues.isEmpty else { return .failure(.init(Self.invalidEnvelope(issues, tool: tool))) }
            let all = draft.definition.examples
            let examples: [WorkflowExample]
            if requested.contains("*") || requested.isEmpty {
                examples = all
            } else {
                var chosen: [WorkflowExample] = []
                for name in requested {
                    guard let example = all.first(where: { $0.name == name }) else {
                        return .failure(
                            .init(
                                ToolEnvelope.failure(
                                    kind: .invalidArgs, message: "No example named `\(name)`.", field: "examples",
                                    tool: tool)))
                    }
                    chosen.append(example)
                }
                examples = chosen
            }
            guard !examples.isEmpty else {
                return .failure(
                    .init(
                        ToolEnvelope.failure(
                            kind: .rejected,
                            message: "The draft has no examples yet. Add a few with the `add_example` op, then run them.",
                            tool: tool)))
            }
            return .success((draft, examples))
        }
        let draft: WorkflowDraft
        let examples: [WorkflowExample]
        switch picked {
        case .failure(let f): return f.envelope
        case .success(let pair): (draft, examples) = pair
        }
        var rows: [[String: Any]] = []
        var passed = 0
        var failures: [[String: Any]] = []
        for example in examples {
            if Task.isCancelled { break }
            let started: Result<UUID, ArchitectToolGate.ToolFailure> = await MainActor.run {
                Self.start(draft: draft, input: example.input, startAt: nil, pinned: [:], tool: tool)
            }
            guard case .success(let runID) = started else {
                if case .failure(let f) = started { return f.envelope }
                continue
            }
            guard let run = await Self.awaitResult(runID) else { continue }
            var row: [String: Any] = ["example": example.name, "run_id": run.id.uuidString, "status": run.status.rawValue]
            if let finished = run.finishedAt {
                row["duration_ms"] = Int(finished.timeIntervalSince(run.startedAt) * 1000)
            }
            if run.status == .completed {
                passed += 1
                if let output = run.output { row["output"] = Self.trimmed(output, limit: 1_000) }
                let notes = WorkflowRunObservations.notes(run, definition: draft.definition)
                if !notes.isEmpty { row["observations"] = notes }
            } else {
                if let failed = WorkflowRunsTool.failedStep(run) {
                    row["failed_step"] = failed.nodeID
                    row["error"] = failed.reason
                    if let failure = run.primaryFailure { row["fix_in"] = failure.fixIn.rawValue }
                } else if let error = run.error?.reason {
                    row["error"] = error
                }
                var detail = Self.summary(run)
                detail["example"] = example.name
                if let hint = await MainActor.run(body: { Self.failureHint(run) }) { detail["hint"] = hint }
                failures.append(detail)
            }
            rows.append(row)
        }
        var result: [String: Any] = [
            "status": passed == rows.count && rows.count == examples.count ? "completed" : "failed",
            "passed": passed,
            "failed": rows.count - passed,
            "examples": rows,
        ]
        if rows.count < examples.count { result["not_run"] = examples.count - rows.count }
        if !failures.isEmpty { result["failures"] = failures }
        Self.addAccess(draft, run: nil, to: &result)
        return ToolEnvelope.success(tool: tool, result: result)
    }

    struct RetestPlan: Equatable {
        var input: JSONValue
        var startAt: String?
        var pinned: [String: JSONValue]
    }

    /// How to re-run a failed run against the draft as it is now: its
    /// input, from its failed step, with the outputs of the steps that had
    /// finished pinned. Steps the draft no longer has are dropped; when the
    /// failed step is gone, or some ancestor of it has no output to pin,
    /// the run starts from the beginning with nothing pinned.
    static func retestPlan(from run: WorkflowRun, definition: WorkflowDefinition) -> RetestPlan {
        let ids = Set(definition.nodes.map(\.id))
        guard let failed = WorkflowRunsTool.failedStep(run)?.nodeID ?? run.error?.nodeID, ids.contains(failed) else {
            return RetestPlan(input: run.input, startAt: nil, pinned: [:])
        }
        var pinned: [String: JSONValue] = [:]
        for node in run.nodes where ids.contains(node.nodeID) && node.nodeID != failed {
            guard node.status == .done || node.status == .pinned, let output = node.output else { continue }
            pinned[node.nodeID] = output
        }
        let ancestors = WorkflowValidator.ancestorMap(definition)[failed] ?? []
        guard ancestors.allSatisfy({ pinned[$0] != nil }) else {
            return RetestPlan(input: run.input, startAt: nil, pinned: [:])
        }
        return RetestPlan(input: run.input, startAt: failed, pinned: pinned)
    }

    /// Failure kinds that mean "something on this Mac refused the step",
    /// not "the step is wrong".
    static let refusalKinds: Set<String> = [
        ToolEnvelope.Kind.rejected.rawValue, ToolEnvelope.Kind.permissionDenied.rawValue,
        ToolEnvelope.Kind.userDenied.rawValue, ToolEnvelope.Kind.unavailable.rawValue, folderDeniedKind,
    ]
    static let folderDeniedKind = "folder_denied"

    /// What actually fixes a refused step, so the Architect does not guess
    /// (agent toggles do not apply to workflow steps). Setup is checked
    /// again first: a refusal that setup now reports opens the wizard.
    @MainActor
    static func failureHint(_ run: WorkflowRun) -> String? {
        guard let classified = refusal(in: run) else { return nil }
        let drafts = WorkflowDraftStore.shared
        if let draft = drafts.draft(id: run.workflowID) {
            let report = SetupChecker.check(
                draft.template(), bindings: drafts.testBindings(draft.id), subjectId: draft.id, agentsByName: true)
            if report.hasBlockers {
                drafts.setupRequest = draft.id
                return setupHint(report.blocking)
            }
        }
        return refusalHint(kind: classified.kind, message: classified.message)
    }

    static func setupHint(_ blocking: [SetupItem]) -> String {
        "Needs setup on this Mac: " + blocking.map { "\($0.title): \($0.detail)" }.joined(separator: "; ")
            + ". The setup wizard is open in the Draft panel (Set Up Test Run); tell the person in one line "
            + "what it installs or grants, then test again after they finish."
    }

    /// The failing node's refusal kind and message, when it failed because
    /// something refused its tool call.
    static func refusal(in run: WorkflowRun) -> (kind: String, message: String)? {
        guard run.status == .failed, let nodeID = run.error?.nodeID,
            let node = run.nodes.first(where: { $0.nodeID == nodeID })
        else { return nil }
        var kind: String?
        var message = node.error ?? run.error?.reason ?? ""
        if node.error?.contains("(\(folderDeniedKind))") == true {
            kind = folderDeniedKind
        } else if let record = node.toolCallRecords.last(where: \.isError), let preview = record.resultPreview,
            let object = JSONValue.parse(preview)?.objectValue
        {
            kind = object["kind"]?.stringValue
            if let text = object["message"]?.stringValue { message = text }
        }
        if kind == nil, let error = node.error,
            let match = error.range(of: #" failed \(([a-z_]+)\)"#, options: .regularExpression)
        {
            kind = String(error[match]).replacingOccurrences(of: " failed (", with: "")
                .replacingOccurrences(of: ")", with: "")
        }
        guard let kind, refusalKinds.contains(kind) else { return nil }
        return (kind, message)
    }

    static func refusalHint(kind: String, message: String) -> String {
        let suffix = " Workflow steps do not use agent settings, so never ask the person to enable a feature on an agent."
        switch kind {
        case ToolEnvelope.Kind.userDenied.rawValue:
            return "The person declined the approval card for this step. Ask them whether to run it before testing again." + suffix
        case ToolEnvelope.Kind.permissionDenied.rawValue:
            return "A macOS permission is missing: \(message) Ask the person to grant it in System Settings → Privacy & Security, then test again." + suffix
        case ToolEnvelope.Kind.unavailable.rawValue:
            return "The step's tool could not start on this Mac: \(message) Fix what the message names, then test again." + suffix
        case folderDeniedKind:
            return "The person did not allow the workflow to use that folder. Do not write the path into the step: "
                + "declare the folder with `declare_folder` and use {{folders.<key>}}/<name> (the person picks it once "
                + "in Set Up Test Run), or ask for it with a `folder` input field." + suffix
        default:
            if message.contains("outside the folders this workflow may use") {
                return "The step named a path outside the run's folders: \(message) Declare the folder with "
                    + "`declare_folder` and use {{folders.<key>}}/<name>, or ask for it with a `folder` input field."
                    + suffix
            }
            if message.localizedCaseInsensitiveContains("denied by policy") {
                return "The step's tool is set to Deny in Tools & MCP. Ask the person to change it to Ask or Auto, then test again." + suffix
            }
            return "The step's tool refused the call: \(message) Change the step so it stays within what the message allows." + suffix
        }
    }

    private static func invalidEnvelope(_ issues: [WorkflowIssue], tool: String) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message: "The draft has issues to fix before it can run: "
                + issues.map { ($0.nodeID.map { "[\($0)] " } ?? "") + $0.message }.joined(separator: "; "),
            tool: tool)
    }

    /// Per-node results, outputs trimmed so a long run stays readable.
    static func summary(_ run: WorkflowRun) -> [String: Any] {
        var out: [String: Any] = [
            "run_id": run.id.uuidString,
            "status": run.status.rawValue,
            "nodes": run.nodes.map { node -> [String: Any] in
                var n: [String: Any] = ["id": node.nodeID, "status": node.status.rawValue]
                if node.reusedFrom != nil { n["reused"] = true }
                if let model = node.model { n["model"] = model }
                if let ms = node.durationMs { n["duration_ms"] = ms }
                if node.attempts > 1 { n["attempts"] = node.attempts }
                if let error = node.error { n["error"] = error }
                if let failure = node.failure { n["failure"] = ArchitectToolGate.foundation(failure) }
                if let output = node.output { n["output"] = trimmed(output) }
                if !node.logs.isEmpty {
                    n["logs"] = node.status == .failed ? node.logs : Array(node.logs.suffix(10))
                }
                if !node.fetches.isEmpty { n["fetches"] = node.fetches }
                if !node.toolCalls.isEmpty { n["tool_calls"] = node.toolCalls }
                return n
            },
        ]
        if let output = run.output { out["output"] = trimmed(output) }
        if !run.artifacts.isEmpty {
            out["files"] = run.artifacts.map { file -> [String: Any] in
                var f: [String: Any] = ["filename": file.filename, "source": file.source.rawValue]
                if let field = file.field { f["field"] = field }
                if let nodeID = file.nodeID { f["node"] = nodeID }
                if file.isAvailable { f["path"] = file.path }
                if let problem = file.problem { f["problem"] = problem }
                if file.isMedia { f["media"] = file.isVideo ? "video" : "image" }
                if let metadata = file.metadata {
                    f["settings"] = ArchitectToolGate.foundation(JSONValue.object(metadata.filter { $0.key != "sources" }))
                }
                return f
            }
        }
        if let error = run.error { out["error"] = ArchitectToolGate.foundation(error) }
        return out
    }

    static func trimmed(_ value: JSONValue, limit: Int = 4000) -> Any {
        let text = value.compactJSONString
        if text.count <= limit { return ArchitectToolGate.foundation(value) }
        return String(text.prefix(limit)) + "… (truncated)"
    }
}

// MARK: - workflow_propose_save

final class WorkflowProposeSaveTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "workflow_propose_save"
    let name = WorkflowProposeSaveTool.toolName
    let description =
        "Ask the user to save the draft as a template. Refused until a test run has passed since the steps "
        + "last changed (a change to only the name or summary needs none); the Save card shows that evidence. "
        + "This ends your turn; nothing is saved unless they click it."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "changelog": .object([
                "type": .string("string"),
                "description": .string("One line on what this version adds or changes."),
            ]),
            "trigger": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "description": .string(
                    "Only when the person asked for it to run on its own: the automation Save also creates. "
                        + "{name, source: {kind, ...}, input: {<input field>: \"{{schedule.scheduled_for}}\" | "
                        + "fixed text}}. Source by kind: schedule {frequency: once | every_n_minutes | hourly | "
                        + "daily | weekly | monthly | yearly | cron, frequency_value (cron: 5 fields `min hour dom "
                        + "month dow`, dow 0-6 with Sun = 0; weekly: MON..SUN), frequency_time_of_day \"HH:mm\"}; "
                        + "folder {path, recursive?}; webhook {provider?}; rss {url}; sse {url}; run_failed; app. "
                        + "Weekdays at 7: {kind: schedule, frequency: cron, frequency_value: \"0 7 * * 1-5\"}."),
            ]),
        ]),
        "required": .array([.string("changelog")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let gate = ArchitectToolGate.failure(tool: name) { return gate }
        let args: [String: JSONValue]
        switch ArchitectToolGate.arguments(argumentsJSON, tool: name) {
        case .success(let a): args = a
        case .failure(let f): return f.envelope
        }
        let changelog = (args["changelog"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = name
        guard !changelog.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`changelog` must be a non-empty line.", field: "changelog", tool: tool)
        }
        return await MainActor.run {
            guard let draft = ArchitectToolGate.currentDraft() else {
                return ArchitectToolGate.noSessionFailure(tool: tool)
            }
            guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ToolEnvelope.failure(
                    kind: .rejected, message: "Name the workflow first (`set_info`).", tool: tool)
            }
            let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
            guard issues.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: "Fix these before proposing a save: "
                        + issues.map(\.message).joined(separator: "; "),
                    tool: tool)
            }
            let evidence = WorkflowDraftStore.shared.testEvidence(draft.id)
            if let blocker = evidence.blocker {
                var metadata: [String: Any] = ["evidence": evidence.summary]
                metadata["hint"] = "Run `workflow_test` (with `examples: [\"*\"]` when the draft has examples) and fix what fails, then propose again."
                return ToolEnvelope.failure(kind: .rejected, message: blocker, tool: tool, metadata: metadata)
            }
            var trigger: WorkflowDraftTrigger?
            if let raw = args["trigger"], raw != .null {
                switch WorkflowDraftTrigger.parse(raw, draft: draft) {
                case .success(let parsed): trigger = parsed
                case .failure(let error):
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: error.message, field: "trigger", tool: tool)
                }
            }
            WorkflowDraftTrigger.setProposed(trigger, for: draft.id)
            let next = draft.templateID.flatMap { TemplateStore.shared.latest(id: $0)?.version }.map { $0 + 1 } ?? 1
            var out: [String: Any] = [
                "draft_id": draft.id.uuidString,
                "name": draft.name,
                "version": next,
                "changelog": changelog,
                "status": "waiting_for_user",
                "evidence": evidence.summary,
            ]
            if let trigger {
                out["trigger"] = "\(trigger.entry.name): \(trigger.summary). Created when the user saves."
            }
            if let editing = WorkflowDraftTool.editing(draft) { out["updates"] = editing["name"] }
            if let renames = WorkflowDraftSaver.renameNotice(for: draft) { out["renames"] = renames }
            WorkflowTestTool.addAccess(draft, run: nil, to: &out)
            if ChatExecutionContext.harnessTokenAgentId != nil {
                WorkflowDraftStore.shared.recordSaveProposal(
                    .init(
                        draftID: draft.id, name: draft.name, version: next, changelog: changelog,
                        updates: out["updates"] as? String))
            }
            return ToolEnvelope.success(tool: tool, result: out)
        }
    }

    static func parseChangelog(from argumentsJSON: String) -> String? {
        JSONValue.parse(argumentsJSON)?.objectValue?["changelog"]?.stringValue
    }
}

// MARK: - architect_handoff

final class ArchitectHandoffTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "architect_handoff"
    let name = ArchitectHandoffTool.toolName

    /// Test seams for the inline path.
    private let seams: ArchitectInlineHandoff.Seams

    init(seams: ArchitectInlineHandoff.Seams = .init()) {
        self.seams = seams
    }

    let description = "Build and run a small workflow now, for a request needing several steps or tools together."

    var parameters: JSONValue? { Self.inlineParameters }

    private static let inlineParameters: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "user_message": .object([
                "type": .string("string"),
                "description": .string("The user's message, exactly as written."),
            ]),
            "brief": .object([
                "type": .string("string"),
                "description": .string("One line: what it does."),
            ]),
            "keep_draft": .object([
                "type": .string("string"),
                "description": .string("Only after the user accepts a keep offer: its id."),
            ]),
        ]),
        "required": .array([.string("user_message"), .string("brief")]),
    ])

    /// The inline Architect drafts and runs inside the call.
    var bypassRegistryTimeout: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "Only the Orchestrator can hand off to the Architect.", tool: name,
                retryable: false)
        }
        return await executeInline(argumentsJSON: argumentsJSON)
    }

    private func executeInline(argumentsJSON: String) async -> String {
        if let key = JSONValue.parse(argumentsJSON)?.objectValue?["keep_draft"]?.stringValue,
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return await ArchitectInlineHandoff.keep(draftKey: key, tool: name)
        }
        let caller = CallerContext.current()
        let handoff: Handoff? = await MainActor.run {
            Handoff.fromToolArguments(
                argumentsJSON,
                turnUserText: ChatExecutionContext.currentUserRequest,
                state: SessionStateRegistry.shared.state(for: caller.sessionId),
                caller: caller)
        }
        guard let handoff else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`user_message` must carry the user's message.", field: "user_message",
                tool: name)
        }
        return await ArchitectInlineHandoff.run(handoff, tool: name, seams: seams)
    }
}
