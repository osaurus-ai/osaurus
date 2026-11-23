//
//  WorkflowEvalHarness+HarnessBridge.swift
//  osaurus
//
//  Starts a template case the way a Claude Code chat delegates: the
//  Default agent's harness token, for a chat a window shows, calls
//  `run_workflow` on the server's `/mcp/call` with the harness's tool-use
//  id. No model: the run is the case's own steps.
//

import Foundation

extension WorkflowEvalHarness {

    /// How a template case starts its run.
    public enum TemplateDriver: Sendable, Equatable {
        case direct
        /// `run_workflow` over HTTP on the in-process server at `apiPort`.
        case harnessBridge(apiPort: Int)
    }

    struct BridgeRun {
        var run: WorkflowRun?
        var checks: [(Bool, String)]
    }

    @MainActor
    static func runThroughHarnessBridge(_ template: Template, input: JSONValue, apiPort: Int) async -> BridgeRun {
        let workflowID = UUID()
        let name = "Eval Harness Run \(workflowID.uuidString.prefix(8))"
        let installed = InstalledWorkflow(
            id: workflowID, template: Template(name: name, summary: template.summary, payload: template.payload),
            bindings: InstallBindings(), orchestratorVisible: true)
        do {
            try InstalledWorkflowStore.shared.save(installed, reviewed: true)
        } catch {
            return BridgeRun(run: nil, checks: [(false, "the workflow installs: \(error)")])
        }
        defer {
            InstalledWorkflowStore.shared.delete(id: workflowID)
            WorkflowRunStore.shared.deleteRuns(workflowID: workflowID)
        }

        let chatId = UUID()
        let previousOpen = HarnessBridgeCall.openChat
        HarnessBridgeCall.openChat = { $0 == chatId ? .init(folderRoot: nil) : previousOpen($0) }
        defer { HarnessBridgeCall.openChat = previousOpen }
        let token = HarnessGrantStore.shared.mint(
            agentId: Agent.defaultId, chatId: chatId, allowsConfigWrites: false,
            allowedToolNames: [RunWorkflowTool.toolName])
        defer { HarnessGrantStore.shared.revoke(token) }
        let toolCallId = "toolu_eval_\(workflowID.uuidString.prefix(8))"

        var checks: [(Bool, String)] = []
        let body = JSONValue.object([
            "name": .string(RunWorkflowTool.toolName),
            "arguments": .object(["workflow": .string(name), "input": input]),
        ])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/mcp/call")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: HarnessGrantStore.headerName)
        request.setValue(toolCallId, forHTTPHeaderField: HarnessBridgeCall.toolCallIdHeader)
        request.httpBody = Data(body.compactJSONString.utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            checks.append((status == 200, "POST /mcp/call answered \(status)"))
            let reply = JSONValue.parse(String(decoding: data, as: UTF8.self))?.objectValue
            let text = reply?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
            checks.append(
                (reply?["isError"]?.boolValue == false && ToolEnvelope.isSuccess(text),
                    "run_workflow succeeded: \(text.prefix(300))"))
        } catch {
            checks.append((false, "POST /mcp/call: \(error.localizedDescription)"))
        }

        let run = WorkflowRunStore.shared.runs(workflowID: workflowID, limit: 1).first
        if let caller = run?.caller {
            checks.append(
                (caller.kind == .orchestrator && caller.agentID == Agent.defaultId,
                    "started by the Default agent (\(caller.kind.rawValue))"))
            checks.append((caller.sessionID == chatId.uuidString, "belongs to the harness chat"))
            checks.append((caller.toolCallID == toolCallId, "carries the harness tool-use id"))
            checks.append(
                (caller.isAttended && !caller.deniesUnapprovedPrompts,
                    "attended: approvals ask in the chat (external \(caller.isExternalSurface), "
                        + "denies \(caller.deniesUnapprovedPrompts))"))
        } else {
            checks.append((false, "a run of the installed workflow exists"))
        }
        let record = await HarnessBridgeCalls.shared.record(chatId: chatId, toolCallId: toolCallId)
        checks.append(
            (record?.name == RunWorkflowTool.toolName && record?.isError == false,
                "the call is recorded for its tool card"))
        await HarnessBridgeCalls.shared.clearRecords(chatId: chatId)
        return BridgeRun(run: run, checks: checks)
    }
}
