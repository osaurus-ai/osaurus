//
//  WorkflowRunsTool.swift
//  osaurus
//
//  The Architect's window onto what workflows did: the runs of installed
//  workflows and of this chat's draft, one run in full (every step's
//  input, output, logs, tool calls), and the failures of a workflow
//  grouped by step and reason across its history. Read-only; records come
//  from `WorkflowRunStore`.
//

import Foundation

final class WorkflowRunsTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "workflow_runs"
    let name = WorkflowRunsTool.toolName
    let description =
        "Read what saved workflows did. `workflows` lists the installed workflows with their recent run "
        + "counts. `list` lists a workflow's runs newest first (status, who started it, the failed step). "
        + "`get` returns one run in full: input, every step's input, output, error, logs, tool calls, and "
        + "timings; pass `node` for one step with nothing trimmed. `failures` groups a workflow's failed "
        + "runs by step and reason, with counts, first and last seen, and the weekdays they fall on. "
        + "Without `workflow`, the workflow this draft edits; without `run_id`, the run this chat was "
        + "asked to fix."

    static let defaultListLimit = 20
    static let maxListLimit = 50
    static let defaultFailureScan = 100
    /// Characters of a value kept in `list` and `get` without `node`.
    static let trimLimit = 4_000
    /// Characters of a value kept in `get` with `node`.
    static let nodeTrimLimit = 16_000

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("workflows"), .string("list"), .string("get"), .string("failures")]),
            ]),
            "workflow": .object([
                "type": .string("string"),
                "description": .string(
                    "For `list` and `failures`: an installed workflow's name. `draft` means this chat's test runs. "
                        + "Default: the workflow this draft edits, else the draft's tests."),
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("completed"), .string("failed"), .string("cancelled"), .string("awaiting_user"),
                    .string("running"), .string("needs_setup"),
                ]),
                "description": .string("For `list`: only runs with this status."),
            ]),
            "since": .object([
                "type": .string("string"),
                "description": .string(
                    "For `list` and `failures`: only runs started after this ISO 8601 time, or within the last "
                        + "`<n>d`/`<n>h` (e.g. \"7d\")."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("For `list`: runs to return (default 20, max 50). For `failures`: runs to scan (default 100)."),
            ]),
            "run_id": .object([
                "type": .string("string"),
                "description": .string("For `get`: the run's id. Default: the run this chat was asked to fix."),
            ]),
            "node": .object([
                "type": .string("string"),
                "description": .string("For `get`: return only this step, with its full input, output, logs, and tool calls."),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let gate = ArchitectToolGate.failure(tool: name) { return gate }
        let args: [String: JSONValue]
        switch ArchitectToolGate.arguments(argumentsJSON, tool: name) {
        case .success(let a): args = a
        case .failure(let f): return f.envelope
        }
        let tool = name
        return await MainActor.run {
            let draft = ArchitectToolGate.currentDraft()
            let action = args["action"]?.stringValue ?? "list"
            switch action {
            case "workflows":
                return ToolEnvelope.success(tool: tool, result: ["workflows": Self.workflowsSummary()])
            case "list":
                switch Self.scope(args, draft: draft, tool: tool) {
                case .failure(let f): return f.envelope
                case .success(let scope):
                    let since = Self.since(args["since"]?.stringValue)
                    let limit = min(max(args["limit"]?.numberValue.map { Int($0) } ?? Self.defaultListLimit, 1), Self.maxListLimit)
                    let status = args["status"]?.stringValue.flatMap(WorkflowRunStatus.init(rawValue:))
                    let runs = scope.runs(limit: Self.maxListLimit * 4)
                        .filter { run in since.map { run.startedAt >= $0 } ?? true }
                        .filter { run in status.map { run.status == $0 } ?? true }
                        .prefix(limit)
                    return ToolEnvelope.success(
                        tool: tool,
                        result: [
                            "workflow": scope.label,
                            "count": runs.count,
                            "runs": runs.map { Self.row($0, definition: scope.definition) },
                        ])
                }
            case "get":
                switch ArchitectToolGate.run(args, draft: draft, tool: tool) {
                case .failure(let f): return f.envelope
                case .success(let run):
                    let definition = Self.definition(for: run, draft: draft)
                    if let nodeID = args["node"]?.stringValue {
                        guard let node = run.node(nodeID) else {
                            return ToolEnvelope.failure(
                                kind: .notFound, message: "Run \(run.id.uuidString) has no step `\(nodeID)`.",
                                field: "node", tool: tool)
                        }
                        return ToolEnvelope.success(
                            tool: tool,
                            result: [
                                "run_id": run.id.uuidString,
                                "node": Self.nodeDetail(node, definition: definition, limit: Self.nodeTrimLimit, logs: nil),
                            ])
                    }
                    return ToolEnvelope.success(tool: tool, result: Self.detail(run, definition: definition))
                }
            case "failures":
                switch Self.scope(args, draft: draft, tool: tool) {
                case .failure(let f): return f.envelope
                case .success(let scope):
                    let since = Self.since(args["since"]?.stringValue)
                    let scan = min(max(args["limit"]?.numberValue.map { Int($0) } ?? Self.defaultFailureScan, 1), 500)
                    let runs = scope.runs(limit: scan).filter { run in since.map { run.startedAt >= $0 } ?? true }
                    var out = Self.failureReport(runs, definition: scope.definition)
                    out["workflow"] = scope.label
                    return ToolEnvelope.success(tool: tool, result: out)
                }
            default:
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`action` must be workflows, list, get, or failures.",
                    field: "action", tool: tool)
            }
        }
    }

    // MARK: - Scope

    /// Whose runs a call reads: an installed workflow's or the draft's tests.
    struct Scope {
        var label: String
        var workflowID: UUID
        var definition: WorkflowDefinition?

        @MainActor
        func runs(limit: Int) -> [WorkflowRun] {
            WorkflowRunStore.shared.runs(workflowID: workflowID, limit: limit)
        }
    }

    @MainActor
    static func scope(_ args: [String: JSONValue], draft: WorkflowDraft?, tool: String) -> Result<Scope, ArchitectToolGate.ToolFailure> {
        let installed = InstalledWorkflowStore.shared
        if let name = args["workflow"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if name.lowercased() == "draft" {
                guard let draft else { return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool))) }
                return .success(Scope(label: "draft", workflowID: draft.id, definition: draft.definition))
            }
            guard let workflow = installed.workflow(named: name) else {
                let names = installed.workflows.map(\.name).sorted()
                return .failure(
                    .init(
                        ToolEnvelope.failure(
                            kind: .notFound,
                            message: "No installed workflow named \"\(name)\"."
                                + (names.isEmpty ? "" : " Installed: " + names.joined(separator: ", ") + "."),
                            field: "workflow", tool: tool)))
            }
            return .success(Scope(label: workflow.name, workflowID: workflow.id, definition: workflow.definition))
        }
        if let draft {
            if let templateID = draft.templateID, let workflow = installed.workflow(templateID: templateID) {
                return .success(Scope(label: workflow.name, workflowID: workflow.id, definition: workflow.definition))
            }
            if let repair = draft.repairRunID.flatMap({ WorkflowRunStore.shared.run(id: $0) }),
                let workflow = installed.workflow(id: repair.workflowID)
            {
                return .success(Scope(label: workflow.name, workflowID: workflow.id, definition: workflow.definition))
            }
            return .success(Scope(label: "draft", workflowID: draft.id, definition: draft.definition))
        }
        return .failure(.init(ArchitectToolGate.noSessionFailure(tool: tool)))
    }

    /// Runs the Architect may read: an installed workflow's, or the
    /// draft's own tests.
    @MainActor
    static func readable(_ run: WorkflowRun, draft: WorkflowDraft?) -> Bool {
        if let draft, run.workflowID == draft.id { return true }
        return InstalledWorkflowStore.shared.workflow(id: run.workflowID) != nil
    }

    @MainActor
    static func definition(for run: WorkflowRun, draft: WorkflowDraft?) -> WorkflowDefinition? {
        if let draft, run.workflowID == draft.id { return draft.definition }
        return InstalledWorkflowStore.shared.workflow(id: run.workflowID)?.definition
    }

    /// "7d", "12h", or an ISO 8601 instant.
    static func since(_ raw: String?, now: Date = Date()) -> Date? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        if let unit = text.last, "dh".contains(unit), let amount = Double(text.dropLast()) {
            return now.addingTimeInterval(-amount * (unit == "d" ? 86_400 : 3_600))
        }
        let upper = text.uppercased()
        if let date = try? Date(upper, strategy: .iso8601) { return date }
        if let date = try? Date(upper, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(upper, strategy: .iso8601.year().month().day()) { return date }
        return nil
    }

    // MARK: - Rendering

    @MainActor
    static func workflowsSummary(now: Date = Date()) -> [[String: Any]] {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        return InstalledWorkflowStore.shared.workflows.sorted { $0.name < $1.name }.map { workflow in
            let runs = WorkflowRunStore.shared.runs(workflowID: workflow.id, limit: 200)
            let recent = runs.filter { $0.startedAt >= weekAgo }
            var row: [String: Any] = [
                "name": workflow.name,
                "version": workflow.templateVersion,
                "needs_setup": workflow.needsSetup,
                "self_heal": workflow.selfHeal,
                "last_7_days": [
                    "runs": recent.count,
                    "completed": recent.filter { $0.status == .completed }.count,
                    "failed": recent.filter { $0.status == .failed }.count,
                ],
            ]
            if let summary = workflow.summary { row["summary"] = summary }
            if let last = runs.first {
                row["last_run"] = [
                    "run_id": last.id.uuidString, "status": last.status.rawValue,
                    "started_at": iso(last.startedAt),
                ]
            }
            return row
        }
    }

    /// One `list` row.
    static func row(_ run: WorkflowRun, definition: WorkflowDefinition?) -> [String: Any] {
        var out: [String: Any] = [
            "run_id": run.id.uuidString,
            "status": run.status.rawValue,
            "started_at": iso(run.startedAt),
            "started_by": startedBy(run.caller),
            "template_version": run.templateVersion,
        ]
        if let finished = run.finishedAt {
            out["duration_ms"] = Int(finished.timeIntervalSince(run.startedAt) * 1000)
        }
        if let failed = failedStep(run) {
            out["failed_step"] = failed.nodeID
            if let name = definition?.node(failed.nodeID)?.name { out["failed_step_name"] = name }
            out["error"] = failed.reason
            if let failure = run.primaryFailure {
                out["error_kind"] = failure.kind
                out["fix_in"] = failure.fixIn.rawValue
            }
        } else if let error = run.error?.reason {
            out["error"] = error
        }
        if let retryOf = run.retryOf { out["retry_of"] = retryOf.uuidString }
        out["input"] = trimmed(run.input, limit: 500)
        return out
    }

    /// One `get` result: the run and every step.
    static func detail(_ run: WorkflowRun, definition: WorkflowDefinition?) -> [String: Any] {
        var out: [String: Any] = [
            "run_id": run.id.uuidString,
            "workflow": run.workflowName,
            "template_version": run.templateVersion,
            "status": run.status.rawValue,
            "started_at": iso(run.startedAt),
            "started_by": startedBy(run.caller),
            "input": trimmed(run.input, limit: trimLimit),
            "nodes": run.nodes.map { nodeDetail($0, definition: definition, limit: trimLimit, logs: 20) },
        ]
        if let finished = run.finishedAt {
            out["finished_at"] = iso(finished)
            out["duration_ms"] = Int(finished.timeIntervalSince(run.startedAt) * 1000)
        }
        if let output = run.output { out["output"] = trimmed(output, limit: trimLimit) }
        if let error = run.error { out["error"] = ArchitectToolGate.foundation(error) }
        if let retryOf = run.retryOf { out["retry_of"] = retryOf.uuidString }
        if let parent = run.caller.parentRunID { out["parent_run_id"] = parent.uuidString }
        if !run.artifacts.isEmpty {
            out["files"] = run.artifacts.map { file -> [String: Any] in
                var f: [String: Any] = ["filename": file.filename, "source": file.source.rawValue]
                if let nodeID = file.nodeID { f["node"] = nodeID }
                if let problem = file.problem { f["problem"] = problem }
                return f
            }
        }
        let tokensIn = run.nodes.compactMap(\.inputTokens).reduce(0, +)
        let tokensOut = run.nodes.compactMap(\.outputTokens).reduce(0, +)
        if tokensIn + tokensOut > 0 { out["tokens"] = ["input": tokensIn, "output": tokensOut] }
        return out
    }

    static func nodeDetail(_ node: NodeRun, definition: WorkflowDefinition?, limit: Int, logs: Int?) -> [String: Any] {
        var n: [String: Any] = ["id": node.nodeID, "status": node.status.rawValue]
        if let spec = definition?.node(node.nodeID) {
            n["name"] = spec.name
            if let kind = spec.kind { n["kind"] = WorkflowNode.kindName(of: kind) }
        }
        if let model = node.model { n["model"] = model }
        if let ms = node.durationMs { n["duration_ms"] = ms }
        if let started = node.startedAt { n["started_at"] = iso(started) }
        if node.attempts > 1 { n["attempts"] = node.attempts }
        if let error = node.error { n["error"] = error }
        if let failure = node.failure { n["failure"] = ArchitectToolGate.foundation(failure) }
        if let input = node.input { n["input"] = trimmed(input, limit: limit) }
        if let output = node.output { n["output"] = trimmed(output, limit: limit) }
        let failed = node.status == .failed
        if !node.logs.isEmpty {
            n["logs"] = failed ? node.logs : logs.map { Array(node.logs.suffix($0)) } ?? node.logs
        }
        if failed, let spec = definition?.node(node.nodeID) { n["step"] = stepSpec(spec, limit: limit) }
        if !node.fetches.isEmpty { n["fetches"] = node.fetches }
        if !node.toolCallRecords.isEmpty {
            n["tool_calls"] = node.toolCallRecords.map { record -> [String: Any] in
                var r: [String: Any] = ["name": record.name, "arguments": record.arguments, "is_error": record.isError]
                if let ms = record.durationMs { r["duration_ms"] = ms }
                if let preview = record.resultPreview {
                    r["result"] = preview.count <= limit ? preview : String(preview.prefix(limit)) + "… (truncated)"
                }
                return r
            }
        } else if !node.toolCalls.isEmpty {
            n["tool_calls"] = node.toolCalls
        }
        if let tokens = node.inputTokens { n["input_tokens"] = tokens }
        if let tokens = node.outputTokens { n["output_tokens"] = tokens }
        return n
    }

    /// A failed step's definition as it ran, so a fix starts from what the
    /// step asked for.
    static func stepSpec(_ node: WorkflowNode, limit: Int) -> Any {
        guard let data = try? JSONEncoder().encode(node), let text = String(data: data, encoding: .utf8) else {
            return NSNull()
        }
        if text.count <= limit { return ArchitectToolGate.foundation(node) }
        return String(text.prefix(limit)) + "… (truncated)"
    }

    // MARK: - Failures

    /// The step a run failed at and why: the run error's node, else the
    /// first failed step.
    static func failedStep(_ run: WorkflowRun) -> (nodeID: String, reason: String)? {
        guard run.status == .failed else { return nil }
        if let nodeID = run.error?.nodeID {
            return (nodeID, run.error?.reason ?? run.node(nodeID)?.error ?? "")
        }
        if let node = run.nodes.first(where: { $0.status == .failed }) {
            return (node.nodeID, node.error ?? run.error?.reason ?? "")
        }
        return nil
    }

    /// The step plus the first line of the reason with volatile parts
    /// blanked (uuids, paths, durations and sizes, numbers of four or more
    /// digits), so the same failure groups together across runs while
    /// status codes such as 404 and 500 stay apart.
    static func signature(nodeID: String, reason: String) -> String {
        var line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        line = line.trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            #"(?:~|/)[^\s"']+"#,
            #"\b\d+(?:\.\d+)?\s?(?:ms|s|m|h|kb|mb|gb|b)\b"#,
            #"\b\d{4,}\b"#,
        ]
        for pattern in patterns {
            line = line.replacingOccurrences(
                of: pattern, with: "…", options: [.regularExpression, .caseInsensitive])
        }
        return nodeID + ": " + line
    }

    static func signature(of run: WorkflowRun) -> String? {
        failedStep(run).map { signature(nodeID: $0.nodeID, reason: $0.reason) }
    }

    struct FailureGroup {
        var nodeID: String
        var signature: String
        var example: String
        var failure: NodeRunFailure?
        var runIDs: [UUID]
        var firstSeen: Date
        var lastSeen: Date
        var weekdays: [String: Int]
    }

    static func groups(_ runs: [WorkflowRun], calendar: Calendar = .current) -> [FailureGroup] {
        var byKey: [String: FailureGroup] = [:]
        var order: [String] = []
        let symbols = calendar.weekdaySymbols
        for run in runs {
            guard let failed = failedStep(run) else { continue }
            let key = signature(nodeID: failed.nodeID, reason: failed.reason)
            let weekday = symbols[calendar.component(.weekday, from: run.startedAt) - 1]
            if var group = byKey[key] {
                group.runIDs.append(run.id)
                group.firstSeen = min(group.firstSeen, run.startedAt)
                group.lastSeen = max(group.lastSeen, run.startedAt)
                group.weekdays[weekday, default: 0] += 1
                byKey[key] = group
            } else {
                byKey[key] = FailureGroup(
                    nodeID: failed.nodeID, signature: key, example: failed.reason, failure: run.primaryFailure,
                    runIDs: [run.id],
                    firstSeen: run.startedAt, lastSeen: run.startedAt, weekdays: [weekday: 1])
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }.sorted {
            $0.runIDs.count != $1.runIDs.count ? $0.runIDs.count > $1.runIDs.count : $0.lastSeen > $1.lastSeen
        }
    }

    static func failureReport(_ runs: [WorkflowRun], definition: WorkflowDefinition?) -> [String: Any] {
        let groups = groups(runs)
        var out: [String: Any] = [
            "scanned": runs.count,
            "totals": [
                "completed": runs.filter { $0.status == .completed }.count,
                "failed": runs.filter { $0.status == .failed }.count,
                "cancelled": runs.filter { $0.status == .cancelled }.count,
                "needs_setup": runs.filter { $0.status == .needsSetup }.count,
            ],
            "groups": groups.map { group -> [String: Any] in
                var g: [String: Any] = [
                    "step": group.nodeID,
                    "reason": group.example,
                    "count": group.runIDs.count,
                    "first_seen": iso(group.firstSeen),
                    "last_seen": iso(group.lastSeen),
                    "run_ids": group.runIDs.prefix(5).map(\.uuidString),
                    "weekdays": group.weekdays,
                ]
                if let name = definition?.node(group.nodeID)?.name { g["step_name"] = name }
                if let failure = group.failure { g["failure"] = ArchitectToolGate.foundation(failure) }
                return g
            },
        ]
        if let first = runs.last, let last = runs.first {
            out["window"] = ["from": iso(min(first.startedAt, last.startedAt)), "to": iso(max(first.startedAt, last.startedAt))]
        }
        return out
    }

    // MARK: - Helpers

    static func startedBy(_ caller: WorkflowCaller) -> String {
        if caller.kind == .event { return caller.eventName.map { "event \($0)" } ?? "event" }
        if caller.isUnattendedDispatch { return "schedule" }
        if caller.isExternalSurface { return "api" }
        switch caller.kind {
        case .user: return "user"
        case .test: return "test"
        case .orchestrator: return "orchestrator"
        case .workflow: return "workflow"
        case .agent: return caller.agentName.map { "agent \($0)" } ?? "agent"
        case .event: return "event"
        }
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
    }

    static func trimmed(_ value: JSONValue, limit: Int) -> Any {
        let text = value.compactJSONString
        if text.count <= limit { return ArchitectToolGate.foundation(value) }
        return String(text.prefix(limit)) + "… (truncated)"
    }
}
