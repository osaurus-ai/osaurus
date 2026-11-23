//
//  MCPWorkflowTools.swift
//  OsaurusCLICore
//
//  `osaurus mcp --workflows`: the owner's installed workflows as MCP tools.
//
//  `/mcp/tools` leaves workflow tools out for callers without an agent, so
//  these are built here from `GET /workflows` and run through
//  `POST /workflows/{id}/run`, which only the app or an approved CLI may
//  call. A run that stops for a form returns `awaiting_user` with its run id;
//  the owner answers in Osaurus and the client checks back with
//  `workflow_run_status`.
//

import Foundation
import MCP

/// Which workflows `--workflows` exposes. Bare `--workflows` (or `*`) means
/// all of them; otherwise comma-separated names, ids or tool names, each
/// optionally ending in `*` to match by prefix.
public struct MCPWorkflowFilter: Equatable, Sendable {
    private let exact: [String]
    private let prefixes: [String]
    private let all: Bool

    public init(patterns raw: String) {
        var exact: [String] = []
        var prefixes: [String] = []
        var all = false
        for piece in raw.split(separator: ",") {
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if token == "*" {
                all = true
            } else if token.hasSuffix("*") {
                prefixes.append(Self.key(String(token.dropLast())))
            } else {
                exact.append(token)
            }
        }
        self.exact = exact
        self.prefixes = prefixes
        self.all = all || (exact.isEmpty && prefixes.isEmpty)
    }

    public func admits(_ workflow: WorkflowSummary) -> Bool {
        if all { return true }
        if exact.contains(where: {
            if case .found(let match) = WorkflowClient.resolve($0, in: [workflow]) { return match.id == workflow.id }
            return false
        }) {
            return true
        }
        let names = [Self.key(workflow.name), Self.key(workflow.toolName), Self.key(Self.bareToolName(workflow))]
        return prefixes.contains { prefix in names.contains { $0.hasPrefix(prefix) } }
    }

    public var summary: String {
        all ? "all" : (exact + prefixes.map { "\($0)*" }).joined(separator: ", ")
    }

    /// The `--workflows` value, or nil when the flag is absent. A bare flag
    /// (last argument, or followed by another flag) means all workflows.
    public static func parse(args: [String]) -> MCPWorkflowFilter? {
        for (index, arg) in args.enumerated() {
            if arg.hasPrefix("--workflows=") {
                return MCPWorkflowFilter(patterns: String(arg.dropFirst("--workflows=".count)))
            }
            if arg == "--workflows" {
                let next = index + 1 < args.count ? args[index + 1] : nil
                guard let next, !next.hasPrefix("-") else { return MCPWorkflowFilter(patterns: "") }
                return MCPWorkflowFilter(patterns: next)
            }
        }
        return nil
    }

    private static func key(_ text: String) -> String { WorkflowClient.slug(text) }

    private static func bareToolName(_ workflow: WorkflowSummary) -> String {
        workflow.toolName.hasPrefix("workflow_") ? String(workflow.toolName.dropFirst("workflow_".count)) : workflow.toolName
    }
}

struct MCPWorkflowTools: Sendable {
    static let statusToolName = "workflow_run_status"

    let filter: MCPWorkflowFilter
    let client: WorkflowClient
    /// How long one call may wait for a run before handing back its id.
    let budget: TimeInterval
    var poll: Duration = .milliseconds(750)

    func workflows() async throws -> [WorkflowSummary] {
        try await client.list().filter { filter.admits($0) && !$0.toolName.isEmpty }
    }

    func tools() async throws -> [MCP.Tool] {
        let listed = try await workflows().map { workflow in
            MCP.Tool(
                name: workflow.toolName,
                description: Self.description(workflow),
                inputSchema: MCPCommand.toMCPValue(from: Self.objectSchema(workflow.inputSchema)))
        }
        return listed + [Self.statusTool]
    }

    /// Nil when `name` is not one of these tools, so the caller proxies it.
    func call(_ name: String, arguments: [String: Any]) async -> CallTool.Result? {
        do {
            if name == Self.statusToolName { return try await status(arguments) }
            guard name.hasPrefix("workflow_") else { return nil }
            guard let workflow = try await workflows().first(where: { $0.toolName == name }) else { return nil }
            if workflow.needsSetup {
                return Self.result(
                    ["status": "needs_setup", "message": "Set up \(workflow.name) in Osaurus first."
                        + (workflow.setupSummary.map { " \($0)" } ?? "")],
                    isError: true)
            }
            let runID = try await client.start(workflowID: workflow.id, input: arguments, text: nil)
            return try await settle(runID)
        } catch let error as WorkflowClientError {
            return Self.result(["status": "error", "message": error.message], isError: true)
        } catch {
            return Self.result(["status": "error", "message": error.localizedDescription], isError: true)
        }
    }

    private func status(_ arguments: [String: Any]) async throws -> CallTool.Result {
        guard let runID = arguments["run_id"] as? String, !runID.isEmpty else {
            return Self.result(["status": "error", "message": "run_id is required."], isError: true)
        }
        if arguments["wait"] as? Bool == true { return try await settle(runID, throughForms: true) }
        return Self.report(try await client.run(runID))
    }

    /// A new run hands back at its first form so the client can tell the
    /// owner; a status wait keeps waiting while the owner fills it in.
    private func settle(_ runID: String, throughForms: Bool = false) async throws -> CallTool.Result {
        let deadline = ContinuousClock.now + .seconds(budget)
        let run = try await WorkflowCommand.wait(
            for: runID, client: client, answerForms: false, waitThroughForms: throughForms,
            poll: poll, deadline: deadline)
        return Self.report(run)
    }

    // MARK: - Shapes

    static func report(_ run: [String: Any]) -> CallTool.Result {
        let status = run["status"] as? String ?? "unknown"
        let runID = run["run_id"] as? String ?? ""
        var body: [String: Any] = ["run_id": runID, "status": status]
        if let output = run["output"], !(output is NSNull) { body["output"] = output }
        if let error = run["error"], !(error is NSNull) { body["error"] = error }
        if let reasons = run["reasons"] as? [String], !reasons.isEmpty { body["reasons"] = reasons }
        switch status {
        case "awaiting_user":
            let dialog = run["pending_dialog"] as? [String: Any] ?? [:]
            var form: [String: Any] = [:]
            if let title = dialog["title"] { form["title"] = title }
            if let message = dialog["message"] { form["message"] = message }
            form["fields"] = (dialog["fields"] as? [[String: Any]] ?? []).compactMap { $0["label"] ?? $0["key"] }
            body["form"] = form
            body["next"] =
                "The workflow is waiting for the owner to fill in a form in Osaurus. Tell them, then call "
                + "\(statusToolName) with this run_id (wait: true) to get the result."
        case "running":
            body["next"] = "Still running. Call \(statusToolName) with this run_id (wait: true) to get the result."
        default:
            break
        }
        let failed = ["failed", "cancelled", "needs_setup"].contains(status)
        return result(body, isError: failed)
    }

    static func result(_ body: [String: Any], isError: Bool) -> CallTool.Result {
        let text =
            (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }

    static func description(_ workflow: WorkflowSummary) -> String {
        var text = "Run the Osaurus workflow \"\(workflow.name)\""
        if let summary = workflow.summary, !summary.isEmpty { text += ": \(summary)" }
        text += ". Returns the run's output. If the workflow stops for a form, the result has status "
            + "awaiting_user and a run_id; the owner answers in Osaurus, then call \(statusToolName)."
        if workflow.needsSetup { text += " Needs setup in Osaurus before it can run." }
        return text
    }

    static func objectSchema(_ schema: [String: Any]) -> [String: Any] {
        var schema = schema
        schema["type"] = "object"
        if schema["properties"] == nil { schema["properties"] = [String: Any]() }
        return schema
    }

    static let statusTool = MCP.Tool(
        name: statusToolName,
        description:
            "Check an Osaurus workflow run started by a workflow_* tool. With wait: true, waits for it to finish, "
            + "including while the owner fills in a form in Osaurus.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "run_id": .object(["type": .string("string"), "description": .string("The run_id a workflow tool returned.")]),
                "wait": .object(["type": .string("boolean"), "description": .string("Wait for the run to finish.")]),
            ]),
            "required": .array([.string("run_id")]),
        ]))

    /// MCP arguments as plain JSON values.
    static func plain(_ arguments: [String: MCP.Value]?) -> [String: Any] {
        guard let arguments, let data = try? JSONEncoder().encode(arguments),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
