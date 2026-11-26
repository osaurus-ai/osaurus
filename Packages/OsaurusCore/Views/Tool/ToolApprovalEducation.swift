//
//  ToolApprovalEducation.swift
//  osaurus
//
//  One source for the copy that explains skipped approval cards: what keeps
//  asking, and what each per-agent Tool Approvals mode does. Shared by the
//  global Auto-Allow switch, the agent's Tool Approvals card and its confirm
//  alert, the approval card's Never Ask entry, and the composer chip.
//

import Foundation

enum ToolApprovalEducation {
    /// What still asks when approval cards are skipped, by the global switch
    /// or an agent's Never Ask. Mirrors the branches above the card skip in
    /// `ToolRegistry.runPermissionGate` and the tools that run their own
    /// confirmation in their bodies.
    static var stillAsks: [String] {
        [
            L("Tools set to Deny, which never run."),
            L("Sending messages or mail, and deleting events, reminders or knowledge. These ask every time."),
            L("MCP tools their server marks as destructive, until you choose Always Allow for that tool."),
            L("Configuration changes, which show their own review card."),
            L("Delegating to other agents, image and video costs, and Computer or Browser Use."),
            L("Teammates and remote callers on a shared agent."),
        ]
    }

    /// One-line form of `stillAsks` for captions and tooltips.
    static var stillAsksSummary: String {
        L("Deny, send and delete, destructive MCP tools, configuration changes, delegation, media costs, and Computer or Browser Use still ask.")
    }

    static var workflowNote: String {
        L("Workflow runs keep their own approvals.")
    }

    static var globalToggleDescription: String {
        L("Run tool calls without showing an approval card. \(stillAsksSummary) Tools can run code and modify files, so enable this only if you trust the tools you have installed. To change this for one agent, use Tool Approvals on that agent's Tools tab.")
    }

    static var globalConfirmMessage: String {
        L("Tool calls will run without showing an approval card, including tools that can run code, modify files, or send data. \(stillAsksSummary) You can turn this off at any time under Tools & MCP → All Tools.")
    }

    static func neverAskConfirmTitle(agentName: String) -> String {
        L("Never Ask for \(agentName)?")
    }

    static func neverAskConfirmMessage(agentName: String) -> String {
        let list = stillAsks.map { "• " + $0 }.joined(separator: "\n")
        return L("\(agentName) will run tools without showing an approval card, in chats and in its scheduled and watcher runs. Tools can run code and modify files, so use this only for an agent whose tools you trust.")
            + "\n\n" + L("Still asks:") + "\n" + list + "\n\n" + workflowNote
    }

    static var neverAskConfirmButton: String { L("Never Ask") }

    static func alwaysAllowForAgentMessage(agentName: String) -> String {
        L("This tool will run without asking in \(agentName)'s chats and runs. Other agents still ask. You can change this on \(agentName)'s Tools tab.")
    }

    static var alwaysAllowForEveryAgentMessage: String {
        L("This tool will run without asking for every agent. You can change this under Tools & MCP → All Tools.")
    }

    /// What the agent's Tool Approvals setting does right now.
    static func caption(mode: AgentToolApprovalMode, globalAutoAllow: Bool) -> String {
        switch mode {
        case .useGlobal:
            return globalAutoAllow
                ? L("Auto-Allow All Tool Calls is on, so approval cards are skipped. \(stillAsksSummary)")
                : L("Tools set to Ask show an approval card, as set under Tools & MCP → All Tools.")
        case .ask:
            return L("Tools set to Ask always show an approval card for this agent, even when Auto-Allow All Tool Calls is on.")
        case .neverAsk:
            return L("Approval cards are skipped for this agent. \(stillAsksSummary)")
        }
    }
}
