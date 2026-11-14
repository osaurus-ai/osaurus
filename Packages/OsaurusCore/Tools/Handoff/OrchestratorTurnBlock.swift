//
//  OrchestratorTurnBlock.swift
//  osaurus
//
//  The block injected beside the Orchestrator's latest user message: the
//  session state, a line when the host already made this turn's call (an
//  ask button or a Discovery card names its target), and the `state` rule.
//

import Foundation

enum OrchestratorTurnBlock {
    /// The presenting turn after a host dispatch: write `state`, ask one
    /// question, or route again when the result is wrong or incomplete.
    static let presentingTurnToolNames: Set<String> = [
        StateTool.toolName, "clarify", ConfiguratorHandoffTool.toolName, RunWorkflowTool.toolName,
        ArchitectHandoffTool.toolName,
    ]

    /// The last line of every injected block: the Orchestrator's `state` rule.
    static let stateRuleLine =
        "[Before you finish this turn, call `state` once with the whole object; never append. "
        + "Without it the object above stays, marked stale.]"

    static func injectedBlock(state: String, dispatchedTool: String?, stateOffered: Bool = true) -> String {
        var block = state
        if let dispatchedTool {
            block += "\n\n[Routed: the host already called `\(dispatchedTool)` with your message. Present its result.]"
        }
        return stateOffered ? block + "\n" + stateRuleLine : block
    }
}
