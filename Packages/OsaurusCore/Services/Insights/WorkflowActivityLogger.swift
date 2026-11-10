//
//  WorkflowActivityLogger.swift
//  osaurus
//
//  Activity-log rows for workflow runs. Each step writes a `workflowNode`
//  row when it finishes (input, output, model, tokens, tool calls), and
//  the run writes one `workflowRun` row when it ends (caller, status,
//  input, output). Both carry the run id, as does every model, tool, and
//  network row emitted inside a step, so Insights can list one run's
//  events together. Content follows Privacy › Activity Log like every
//  other row.
//

import Foundation

@MainActor
final class WorkflowActivityLogger {
    static let shared = WorkflowActivityLogger()

    /// Test seam: where finished rows go.
    var sink: (RequestLog) -> Void = { InsightsService.shared.log($0) }

    private var active: Set<UUID> = []
    private var definitions: [UUID: WorkflowDefinition] = [:]
    private var loggedNodes: [UUID: Set<String>] = [:]

    init() {}

    /// Remembers the run's definition so rows can name its steps.
    func begin(runID: UUID, definition: WorkflowDefinition?) {
        active.insert(runID)
        definitions[runID] = definition
    }

    /// Writes rows for steps that finished since the last update.
    func observe(_ run: WorkflowRun) {
        guard active.contains(run.id) else { return }
        for node in run.nodes where Self.isFinished(node) {
            guard loggedNodes[run.id, default: []].insert(node.nodeID).inserted else { continue }
            sink(Self.nodeRow(node, of: run, definition: definitions[run.id]))
        }
    }

    /// Writes any remaining step rows and the run row.
    func finished(_ run: WorkflowRun) {
        guard active.contains(run.id) else { return }
        observe(run)
        sink(Self.runRow(run, definition: definitions[run.id]))
        active.remove(run.id)
        definitions[run.id] = nil
        loggedNodes[run.id] = nil
    }

    // MARK: - Rows

    static func isFinished(_ node: NodeRun) -> Bool {
        node.status == .done || node.status == .failed
    }

    static func runRow(_ run: WorkflowRun, definition: WorkflowDefinition?) -> RequestLog {
        var details: [String: String] = [
            "workflow": run.workflowName,
            "workflow_id": run.workflowID.uuidString,
            "status": run.status.rawValue,
            "caller": callerLabel(run.caller),
            "steps": String(run.nodes.filter(isFinished).count),
        ]
        if run.isTest { details["test"] = "true" }
        if let failed = run.error?.nodeID {
            details["failed_step"] = definition?.node(failed)?.name ?? failed
        }
        if let folder = run.caller.folderPath { details["folder"] = folder }
        let finished = run.finishedAt ?? Date()
        return RequestLog(
            timestamp: finished,
            source: source(for: run.caller),
            requestId: run.id.uuidString,
            method: "RUN",
            path: "/workflow/\(slug(run.workflowName))",
            statusCode: statusCode(run.status),
            durationMs: finished.timeIntervalSince(run.startedAt) * 1000,
            requestBody: InsightsService.truncateBody(run.input.prettyJSONString),
            responseBody: InsightsService.truncateBody(run.output?.prettyJSONString),
            errorMessage: run.error?.reason,
            category: .workflowRun,
            locality: .local,
            egress: EgressInfo(details: details),
            agentId: run.caller.agentID,
            agentName: run.caller.agentName,
            sessionId: run.caller.sessionID.flatMap(UUID.init(uuidString:)),
            workflowRunId: run.id
        )
    }

    static func nodeRow(_ node: NodeRun, of run: WorkflowRun, definition: WorkflowDefinition?) -> RequestLog {
        let spec = definition?.node(node.nodeID)
        var details: [String: String] = [
            "workflow": run.workflowName,
            "node_name": spec?.name ?? node.nodeID,
            "status": node.status.rawValue,
            "attempts": String(node.attempts),
        ]
        if let kind = spec?.kindName { details["kind"] = kind }
        if !node.fetches.isEmpty { details["urls"] = node.fetches.joined(separator: "\n") }
        if !node.logs.isEmpty { details["logs"] = node.logs.joined(separator: "\n") }
        // A code step's requests left this Mac.
        let hosts = Array(Set(node.fetches.compactMap(fetchHost))).sorted()
        var egress = EgressInfo(details: details)
        if !hosts.isEmpty {
            egress.destinationLabel = hosts.joined(separator: ", ")
            egress.destinationHost = hosts.first
            egress.dataClasses = ["request"]
        }
        let toolCalls = node.toolCallRecords.map { record in
            ToolCallLog(
                name: record.name, arguments: record.arguments, result: record.resultPreview,
                durationMs: record.durationMs.map(Double.init), isError: record.isError)
        }
        return RequestLog(
            timestamp: node.finishedAt ?? Date(),
            source: source(for: run.caller),
            requestId: "\(run.id.uuidString)/\(node.nodeID)",
            method: "STEP",
            path: "/workflow/\(slug(run.workflowName))/\(node.nodeID)",
            statusCode: node.status == .failed ? 500 : 200,
            durationMs: Double(node.durationMs ?? 0),
            requestBody: InsightsService.truncateBody(node.input?.prettyJSONString),
            responseBody: InsightsService.truncateBody(node.output?.prettyJSONString),
            model: node.model,
            inputTokens: node.inputTokens,
            outputTokens: node.outputTokens,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            errorMessage: node.error,
            category: .workflowNode,
            locality: hosts.isEmpty ? .local : .remote,
            egress: egress,
            agentId: run.caller.agentID,
            agentName: run.caller.agentName,
            sessionId: run.caller.sessionID.flatMap(UUID.init(uuidString:)),
            workflowRunId: run.id,
            workflowNodeId: node.nodeID
        )
    }

    static func statusCode(_ status: WorkflowRunStatus) -> Int {
        switch status {
        case .completed, .running, .awaitingUser: return 200
        case .cancelled: return 499
        case .failed, .needsSetup: return 500
        }
    }

    nonisolated static func source(for caller: WorkflowCaller) -> RequestSource {
        if caller.isExternalSurface { return .httpAPI }
        if caller.isUnattendedDispatch { return .scheduled }
        switch caller.kind {
        case .agent, .orchestrator, .workflow: return .agent
        case .user, .test: return .chatUI
        case .event: return .scheduled
        }
    }

    static func callerLabel(_ caller: WorkflowCaller) -> String {
        let kind: String
        switch caller.kind {
        case .agent: kind = L("Agent")
        case .orchestrator: kind = L("Orchestrator")
        case .user: kind = L("You")
        case .test: kind = L("Architect test")
        case .workflow: kind = L("Workflow")
        case .event: kind = L("Event")
        }
        if caller.kind == .event, let name = caller.eventName { return "\(kind) · \(name)" }
        guard let name = caller.agentName, caller.kind == .agent else { return kind }
        if let teammate = caller.onBehalfOf { return "\(kind) · \(name) · \(ParticipantFormatter.short(teammate))" }
        return "\(kind) · \(name)"
    }

    /// "GET api.clio.com/v4/matters" → "api.clio.com".
    static func fetchHost(_ fetch: String) -> String? {
        let target = fetch.split(separator: " ").last.map(String.init) ?? fetch
        return EgressInfo.host(from: target.contains("://") ? target : "https://\(target)")
    }

    static func slug(_ name: String) -> String {
        let parts = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? "workflow" : parts.joined(separator: "-")
    }
}
