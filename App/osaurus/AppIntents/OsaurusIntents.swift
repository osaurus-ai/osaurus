//
//  OsaurusIntents.swift
//  osaurus
//
//  App Intents exposed to Shortcuts, Spotlight, and Siri. Both intents are
//  thin clients over the local HTTP server (see `OsaurusLocalClient`).
//

import AppIntents
import OsaurusCore

/// Ask the currently active Osaurus agent and return its reply.
///
/// This awaits the streaming `/agents/{id}/run` result. A short ask completes
/// well within the intent time budget; an ask that triggers heavy tool use can
/// exceed it (the run is connection-bound and would be cancelled).
struct AskOsaurusIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Osaurus"
    static let description = IntentDescription("Ask the active Osaurus agent.")

    @Parameter(title: "Prompt") var prompt: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let id = await OsaurusLocalClient.shared.activeAgentID()
        let reply = try await OsaurusLocalClient.shared.runAgent(id: id, prompt: prompt)
        return .result(value: reply, dialog: "\(reply)")
    }
}

/// Start a custom Osaurus agent in the background (fire-and-confirm).
///
/// Uses the detached `/agents/{id}/dispatch` path so the run survives this
/// intent returning; progress and results surface through the app's Work Mode
/// and toasts.
struct RunAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Osaurus Agent"
    static let description = IntentDescription("Start an Osaurus agent in the background.")

    @Parameter(title: "Agent") var agent: AgentEntity
    @Parameter(title: "Input") var input: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await OsaurusLocalClient.shared.startAgent(id: agent.id, input: input)
        return .result(dialog: "Started \(agent.name).")
    }
}
