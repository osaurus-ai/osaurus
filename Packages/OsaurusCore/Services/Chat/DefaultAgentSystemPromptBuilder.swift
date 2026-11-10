//
//  DefaultAgentSystemPromptBuilder.swift
//  osaurus
//
//  The Orchestrator's persona: the one agent the user talks to. It answers
//  when no tool is needed and routes when any tool is needed, never both.
//  Osaurus questions and changes go to the Configurator
//  (`configurator_handoff`), new workflows to the Architect
//  (`architect_handoff`), installed workflows run with `run_workflow`.
//  Everything about Osaurus's own settings lives in
//  `ConfiguratorSystemPromptBuilder`, not here.
//
//  The text is the seven rules, each one testable, plus the routing table.
//  The `state` rule rides at the end of each turn's injected block
//  (`OrchestratorTurnBlock.injectedBlock`), where small models attend to it.
//  Each variant is memoized, so every turn with the same exposure sees
//  byte-identical text and the prompt prefix stays in the KV cache.
//

import Foundation

@MainActor
public enum DefaultAgentSystemPromptBuilder {
    private static var cache: [String: String] = [:]

    /// Tools every rendered variant, with the injected block's `state`
    /// line, tells the model to call. A prompt that
    /// names these while the request's tool scope refuses them sets up a
    /// `tool_not_found` loop; the schema resolver keeps them exposed for the
    /// Default agent, and tests pin it with `missingRequiredToolNames`.
    nonisolated public static let orchestratorRequiredToolNames: Set<String> = [
        StatusTool.toolName, StateTool.toolName, ConfiguratorHandoffTool.toolName, ArchitectHandoffTool.toolName,
    ]

    /// The required names that `exposed` does NOT contain; empty when the
    /// prompt and the scope agree.
    nonisolated public static func missingRequiredToolNames(exposed: Set<String>) -> Set<String> {
        orchestratorRequiredToolNames.subtracting(exposed)
    }

    /// The conditional part of the Orchestrator's tool surface. The persona
    /// renders from this so it never names a tool the request lacks.
    public struct Exposure: Hashable, Sendable {
        /// A working folder is attached to the chat (workers read and write
        /// it; the Orchestrator never does).
        public var folderBound: Bool
        /// `run_workflow` is in the request schema; it also runs the agent
        /// wrappers and built-in workers.
        public var runWorkflowAvailable: Bool

        public init(folderBound: Bool, runWorkflowAvailable: Bool = true) {
            self.folderBound = folderBound
            self.runWorkflowAvailable = runWorkflowAvailable
        }

        /// Every conditional tool present.
        public static let full = Exposure(folderBound: true, runWorkflowAvailable: true)

        /// Derive the exposure from a resolved request schema's tool names.
        /// The folder is not visible in the schema, so the caller passes it.
        public static func from(toolNames: Set<String>, folderBound: Bool) -> Exposure {
            Exposure(folderBound: folderBound, runWorkflowAvailable: toolNames.contains(RunWorkflowTool.toolName))
        }
    }

    /// Render (or return the cached) persona.
    ///
    /// `compact` renders the leaner variant for small local models
    /// (`prefersCompactPrompt`): same rules, trimmed prose.
    public static func render(
        compact: Bool = false,
        toolsAvailable: Bool = true,
        exposure: Exposure = .full
    ) -> String {
        guard toolsAvailable else {
            return """
                # Osaurus

                You are Osaurus's assistant. Tools are unavailable in this request. Answer directly from the conversation and your knowledge. Explain when a request needs tool access; do not claim to have inspected configuration, changed settings, or delegated work.
                """
        }
        let key =
            "\(compact)|\(exposure.folderBound)|\(exposure.runWorkflowAvailable)"
        if let cached = cache[key] { return cached }
        let rendered = build(compact: compact, exposure: exposure)
        cache[key] = rendered
        return rendered
    }

    static func _renderForTests(compact: Bool = false, exposure: Exposure = .full) -> String {
        build(compact: compact, exposure: exposure)
    }

    public static func _resetForTests() {
        cache = [:]
    }

    // MARK: - Build

    private static func build(compact: Bool, exposure: Exposure) -> String {
        var lines: [String] = []
        lines.append("# Osaurus")
        lines.append("")
        lines.append(
            compact
                ? "You are Osaurus, the one assistant the user talks to. Answer when no tool is "
                    + "needed; route when any tool is needed. Never both in one turn."
                : "You are Osaurus, the one assistant the user talks to. When a request needs no "
                    + "tool, answer it yourself. When it needs any tool, route it with the tools "
                    + "below and present what comes back. Never both in one turn."
        )
        lines.append("")
        lines.append("Routes:")
        lines.append(
            "- Anything about Osaurus itself (how a feature works, where a setting is, what is "
                + "configured, or a change to models, agents, providers, tools, automations, or "
                + "settings, including installing what a shared link, snippet, or install command "
                + "sets up) → `configurator_handoff`."
        )
        if exposure.runWorkflowAvailable {
            lines.append(
                "- A task an installed workflow does → `run_workflow` with its name and input "
                    + "(`status` lists them)."
            )
            lines.append(
                "- Other tool work (web research, files, a website, code, or a task for one of the "
                    + "user's agents) → `run_workflow` with that worker or agent's name and "
                    + "`{\"task\": the user's message}`."
            )
        }
        lines.append(
            "- A request that needs several steps or tools together, with no workflow for it "
                + "(fetch, then summarize, then email; an intake; a recurring report) → "
                + "`architect_handoff`, which builds it and runs it now. When the user accepts an "
                + "offer to keep one, call it again with that offer's `keep_draft`."
        )
        lines.append(
            "- What is running, waiting, or loaded right now → `status`."
        )
        lines.append(
            exposure.folderBound
                ? "- A working folder is attached. Work on its files goes to a worker; its result "
                    + "names the files it wrote."
                : "- No working folder is attached. For a task on files, tell the user to pick a "
                    + "folder with the Folder chip."
        )
        lines.append("")
        lines.append("Rules:")
        lines.append("1. No tool needed: answer. Any tool needed: route.")
        lines.append(
            "2. Pass the user's message verbatim in every handoff (`user_message`); add a one-line "
                + "`brief`."
        )
        lines.append("3. Never spawn a subagent.")
        lines.append(
            "4. Never apply a settings change yourself; `configurator_handoff` makes it, behind "
                + "the user's approval card."
        )
        lines.append(
            "5. Settings may have changed since earlier turns: trust this turn's results over "
                + "earlier messages."
        )
        lines.append(
            "6. Present results as returned. If a result is wrong or incomplete, route again "
                + "and name the gap."
        )
        lines.append(
            "7. At most one clarifying question per turn (`clarify`), and only when the route is "
                + "unclear."
        )
        if !compact {
            lines.append("")
            lines.append(
                "Never type a tool call, its JSON, or a document into your reply. Never say a change "
                    + "or a task is done unless a result says so."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Backticked tool names the rendered persona tells the model to call,
    /// restricted to `known` (the registered tool universe) so argument
    /// names in backticks do not count. The truthfulness contract: this set
    /// ⊆ the request schema.
    nonisolated public static func advertisedToolNames(
        in rendered: String,
        known: Set<String>
    ) -> Set<String> {
        var found = Set<String>()
        var rest = rendered[...]
        while let open = rest.firstIndex(of: "`") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "`") else { break }
            let token = String(rest[afterOpen..<close])
            if known.contains(token) { found.insert(token) }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }
}
