//
//  OrchestratorTurnBlock.swift
//  osaurus
//
//  The block injected beside the Orchestrator's latest user message: the
//  session state, and a line when the host already made this turn's call
//  (an ask button or a Discovery card names its target).
//

import Foundation

enum OrchestratorTurnBlock {
    /// The presenting turn after a host dispatch: ask one question, or route
    /// again when the result is wrong or incomplete.
    static let presentingTurnToolNames: Set<String> = [
        "clarify", ConfiguratorHandoffTool.toolName, RunWorkflowTool.toolName,
        ArchitectHandoffTool.toolName,
    ]

    static func injectedBlock(state: String, dispatchedTool: String?) -> String {
        var block = state
        if let dispatchedTool {
            block += "\n\n[Routed: the host already called `\(dispatchedTool)` with your message. Present its result.]"
        }
        return block
    }
}
