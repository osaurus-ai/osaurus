//
//  WorkflowClient.swift
//  OsaurusCLI
//
//  The owner's workflow routes, for `osaurus workflow` and
//  `osaurus mcp --workflows`: `GET /workflows`, `POST /workflows/{id}/run`,
//  `GET /workflows/runs[/{id}]`, the dialog answer route, and cancel.
//

import Foundation

/// One installed workflow from `GET /workflows`.
public struct WorkflowSummary: @unchecked Sendable {
    public let id: String
    public let name: String
    public let toolName: String
    public let summary: String?
    /// JSON Schema object for the run input.
    public let inputSchema: [String: Any]
    public let needsSetup: Bool
    public let setupSummary: String?

    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.toolName = object["tool_name"] as? String ?? ""
        self.summary = object["summary"] as? String
        self.inputSchema = object["input_schema"] as? [String: Any] ?? [:]
        self.needsSetup = object["needs_setup"] as? Bool ?? false
        self.setupSummary = object["setup_summary"] as? String
    }

    /// Input field names, required first, in schema order where known.
    public var inputProperties: [String: [String: Any]] {
        inputSchema["properties"] as? [String: [String: Any]] ?? [:]
    }

    public var requiredInputs: [String] { inputSchema["required"] as? [String] ?? [] }
}

public struct WorkflowClientError: Error, Equatable, CustomStringConvertible {
    public let message: String
    /// Osaurus refused because this CLI is not approved to start workflows.
    public let appOnly: Bool
    public var description: String { message }
    init(_ message: String, appOnly: Bool = false) {
        self.message = message
        self.appOnly = appOnly
    }
}

public struct WorkflowClient: Sendable {
    let server: LocalServerClient

    public init(server: LocalServerClient) { self.server = server }

    public func list() async throws -> [WorkflowSummary] {
        let object = try await json(server.request("/workflows", timeout: 15), expecting: [200])
        return (object["workflows"] as? [[String: Any]] ?? []).compactMap(WorkflowSummary.init)
    }

    public enum Resolution {
        case found(WorkflowSummary)
        case notFound
        case ambiguous([WorkflowSummary])
    }

    /// By id, tool name (with or without `workflow_`), or name, ignoring
    /// case and punctuation.
    public static func resolve(_ query: String, in workflows: [WorkflowSummary]) -> Resolution {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = workflows.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }) {
            return .found(exact)
        }
        let lowered = key.lowercased()
        if let tool = workflows.first(where: { $0.toolName == lowered || $0.toolName == "workflow_" + lowered }) {
            return .found(tool)
        }
        let named = workflows.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if named.count == 1 { return .found(named[0]) }
        if named.count > 1 { return .ambiguous(named) }
        let slugged = workflows.filter { slug($0.name) == slug(key) && !slug(key).isEmpty }
        if slugged.count == 1 { return .found(slugged[0]) }
        return slugged.isEmpty ? .notFound : .ambiguous(slugged)
    }

    static func slug(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: "_")
    }

    public func find(_ query: String) async throws -> WorkflowSummary {
        let workflows = try await list()
        switch Self.resolve(query, in: workflows) {
        case .found(let workflow):
            return workflow
        case .ambiguous(let matches):
            throw WorkflowClientError(
                "More than one workflow matches `\(query)`: " + matches.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
                    + ". Use the id.")
        case .notFound:
            let names = workflows.map(\.name).sorted()
            throw WorkflowClientError(
                "No workflow is named `\(query)`."
                    + (names.isEmpty ? " No workflows are installed." : " Installed: " + names.joined(separator: ", ")))
        }
    }

    /// Starts a run with `input` (an object) or `text`; returns its id.
    public func start(workflowID: String, input: [String: Any]?, text: String?) async throws -> String {
        var body: [String: Any] = [:]
        if let input { body["input"] = input }
        if let text { body["text"] = text }
        // Loopback trust does not reach this route, so an unapproved CLI is
        // refused even with network exposure off. Ask first, and once more
        // when Osaurus no longer accepts the stored token.
        let hadToken = server.hasToken
        _ = await server.requireToken()
        let object: [String: Any]
        do {
            object = try await json(
                server.jsonRequest("/workflows/\(workflowID)/run", body: body, timeout: 30), expecting: [200, 202])
        } catch let error as WorkflowClientError where error.appOnly && hadToken {
            server.dropToken()
            guard await server.requireToken() else { throw error }
            object = try await json(
                server.jsonRequest("/workflows/\(workflowID)/run", body: body, timeout: 30), expecting: [200, 202])
        }
        guard let runID = object["run_id"] as? String else {
            throw WorkflowClientError("Osaurus did not return a run id.")
        }
        return runID
    }

    /// `GET /workflows/runs/{id}`: status, output, error, pending_dialog.
    public func run(_ runID: String) async throws -> [String: Any] {
        try await json(server.request("/workflows/runs/\(runID)", timeout: 15), expecting: [200])
    }

    public func runs(workflow: String?, limit: Int?) async throws -> [[String: Any]] {
        var query: [String] = []
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let workflow, let encoded = workflow.addingPercentEncoding(withAllowedCharacters: unreserved) {
            query.append("workflow=\(encoded)")
        }
        if let limit { query.append("limit=\(limit)") }
        let path = "/workflows/runs" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        let object = try await json(server.request(path, timeout: 15), expecting: [200])
        return object["runs"] as? [[String: Any]] ?? []
    }

    public enum AnswerResult: Equatable {
        case accepted
        /// Another form of the same run is waiting first.
        case queued
        /// Answered elsewhere (in the app) or the run moved on.
        case gone
        case invalid([String])
    }

    public func answer(runID: String, nodeID: String, values: [String: Any]) async throws -> AnswerResult {
        let node = nodeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nodeID
        let request = server.jsonRequest(
            "/workflows/runs/\(runID)/dialogs/\(node)", body: ["values": values], timeout: 30)
        let (data, response) = try await server.data(for: request)
        if response.statusCode == 401 { throw WorkflowClientError(server.unauthorizedHint) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch response.statusCode {
        case 200: return .accepted
        case 404: return .gone
        case 409: return .queued
        case 422: return .invalid(object["issues"] as? [String] ?? [])
        default: throw Self.error(from: object, status: response.statusCode)
        }
    }

    public func cancel(_ runID: String) async throws {
        _ = try await json(
            server.request("/workflows/runs/\(runID)/cancel", method: "POST", timeout: 15), expecting: [200])
    }

    // MARK: - Private

    private func json(_ request: URLRequest, expecting statuses: Set<Int>) async throws -> [String: Any] {
        let (data, response) = try await server.data(for: request)
        if response.statusCode == 401 { throw WorkflowClientError(server.unauthorizedHint) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard statuses.contains(response.statusCode) else { throw Self.error(from: object, status: response.statusCode) }
        return object
    }

    static func error(from object: [String: Any], status: Int) -> WorkflowClientError {
        if status == 403, object["error"] as? String == "app_only" {
            return WorkflowClientError(
                "Osaurus only lets an approved osaurus command start workflows. Run `osaurus workflow run NAME` "
                    + "in Terminal once and click Allow when Osaurus asks.",
                appOnly: true)
        }
        if status == 404, object["error"] == nil {
            return WorkflowClientError("This version of Osaurus does not offer that workflow route. Update Osaurus.")
        }
        if let message = object["message"] as? String { return WorkflowClientError(message) }
        if let code = object["error"] as? String { return WorkflowClientError("\(code) (HTTP \(status))") }
        return WorkflowClientError("Osaurus answered HTTP \(status).")
    }
}
