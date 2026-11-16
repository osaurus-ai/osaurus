//
//  AgentCreationEvalHarness.swift
//  osaurus
//
//  Drives one New Agent chat turn for the OsaurusEvals `agent_creation`
//  domain: a fresh draft bound to the session, the Configurator on the
//  shared agent loop with the same composer profile and tool surface a
//  New Agent chat gets, then checks on the draft it left. The draft is
//  deleted afterwards and no agent may be added.
//

import Foundation

@MainActor
public enum AgentCreationEvalHarness {
    public struct Case: Sendable {
        public var brief: String
        public var replies: [String]
        public var maxIterations: Int
        /// Capability keys (as `agent_draft` reports them) that must be on.
        public var capabilitiesOn: [String]
        /// Capability keys that must stay off.
        public var capabilitiesOff: [String]
        /// `auto` or `manual`, when the row pins it.
        public var toolMode: String?
        public var maxClarifications: Int?
        /// A name the person typed in the panel before the turn; the draft
        /// must keep it.
        public var handEditedName: String?
        /// The message shares something to import: the turn must call
        /// `agent_draft` `import`, and these item kinds (`skill`,
        /// `mcp_server`, …) must be queued for Create, not installed.
        public var importKinds: [String]?

        public init(
            brief: String, replies: [String] = [], maxIterations: Int = 10, capabilitiesOn: [String] = [],
            capabilitiesOff: [String] = [], toolMode: String? = nil, maxClarifications: Int? = nil,
            handEditedName: String? = nil, importKinds: [String]? = nil
        ) {
            self.importKinds = importKinds
            self.brief = brief
            self.replies = replies
            self.maxIterations = maxIterations
            self.capabilitiesOn = capabilitiesOn
            self.capabilitiesOff = capabilitiesOff
            self.toolMode = toolMode
            self.maxClarifications = maxClarifications
            self.handEditedName = handEditedName
        }
    }

    public struct Outcome: Sendable {
        public let passed: Bool
        public let checks: [String]
    }

    /// Replies that say the agent exists. Only Create in the panel makes it.
    static let createdClaims = [
        "has been created", "was created", "is created", "i created", "i've created", "i have created",
        "has been saved", "i saved", "i've saved", "is ready to chat", "is now ready to use",
    ]

    public static func run(_ spec: Case, model: String?) async -> (outcome: Outcome, transcript: AgentLoopTranscript) {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let store = AgentDraftStore.shared
        let sessionID = UUID().uuidString
        let draft = store.create(sessionID: sessionID)
        defer { store.delete(draft.id) }
        if let name = spec.handEditedName {
            store.applyUserEdit(draft.id, .name) { $0.name = name }
        }
        let agentsBefore = Set(AgentManager.shared.agents.map(\.id))
        let installedBefore = installedNames()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-creation-eval-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var brief = spec.brief
        if let context = store.takeTurnContext(sessionID: sessionID) {
            brief = ChatSession.buildUserMessageText(
                content: brief,
                attachments: [
                    .document(filename: "agent-draft-context.md", content: context, fileSize: context.utf8.count)
                ])
        }
        let transcript = await AgentLoopEvaluator.run(
            task: brief, workspace: workspace, agentId: Agent.configuratorId, maxIterations: spec.maxIterations,
            model: model, useHostFolder: false, sessionId: sessionID, clarifyReplies: spec.replies)

        var checks: [(Bool, String)] = []
        let patches = transcript.toolCalls.filter { call in
            call.name == AgentDraftTool.toolName && call.arguments.contains("patch") && !call.wasError
        }
        let imports = transcript.toolCalls.filter { call in
            call.name == AgentDraftTool.toolName && call.arguments.contains("\"import\"")
        }
        if let kinds = spec.importKinds {
            let ok = imports.filter { !$0.wasError }
            checks.append((imports.count == 1 && ok.count == 1, "one `agent_draft` import (\(imports.count) calls, \(ok.count) ok)"))
            let queued = Set((store.draft(id: draft.id) ?? draft).queuedImports.map(\.kind.rawValue))
            for kind in kinds {
                checks.append((queued.contains(kind), "\(kind) queued for Create"))
            }
            let installed = installedNames().subtracting(installedBefore)
            checks.append((
                installed.isEmpty,
                "nothing installed before Create" + (installed.isEmpty ? "" : " (\(installed.sorted().joined(separator: ", ")))")
            ))
        } else {
            checks.append((!patches.isEmpty, "drafted through `agent_draft` patch (\(patches.count) ok)"))
            checks.append((imports.isEmpty, "no import without something to import (\(imports.count))"))
        }
        let forbidden = transcript.toolCalls.filter { $0.name == "osaurus_config" }
        checks.append((forbidden.isEmpty, "no `osaurus_config` call (\(forbidden.count))"))

        let after = store.draft(id: draft.id) ?? draft
        let agent = after.agent
        checks.append((!agent.name.trimmingCharacters(in: .whitespaces).isEmpty, "draft has a name: \"\(agent.name)\""))
        checks.append((
            !agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "draft has instructions (\(agent.systemPrompt.count) chars)"
        ))
        let on = Set(AgentDraftTool.enabledCapabilities(agent))
        for key in spec.capabilitiesOn {
            checks.append((on.contains(key), "\(key) on"))
        }
        for key in spec.capabilitiesOff {
            checks.append((!on.contains(key), "\(key) off"))
        }
        if let mode = spec.toolMode {
            let actual = (agent.toolSelectionMode ?? .auto).rawValue
            checks.append((actual == mode, "tool mode \(actual) (want \(mode))"))
        }
        if let name = spec.handEditedName {
            checks.append((agent.name == name, "kept the hand-edited name \"\(name)\" (got \"\(agent.name)\")"))
        }
        if let limit = spec.maxClarifications {
            let asked = transcript.toolCalls.filter { $0.name == "clarify" }.count
            checks.append((asked <= limit, "clarify ×\(asked) (max \(limit))"))
        }
        let added = AgentManager.shared.agents.filter { !agentsBefore.contains($0.id) }
        checks.append((added.isEmpty && !after.isCreated, "no agent was created (\(added.count) added)"))
        let reply = transcript.finalText.lowercased()
        let claim = createdClaims.first { reply.contains($0) }
        checks.append((claim == nil, "reply does not claim the agent exists" + (claim.map { " (said \"\($0)\")" } ?? "")))
        checks.append((!transcript.finalText.isEmpty, "a visible reply (\(transcript.finalText.count) chars)"))

        var lines = checks.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 }
        lines.append("INFO capabilities on: \(on.sorted().joined(separator: ", "))")
        if !after.reasons.isEmpty {
            lines.append("INFO reasons: \(after.reasons.keys.sorted().joined(separator: ", "))")
        }
        return (Outcome(passed: checks.allSatisfy(\.0), checks: lines), transcript)
    }

    /// Skills, MCP servers, and commands on this Mac, by kind and name.
    /// Built-in skills can finish loading mid-turn, so they don't count.
    private static func installedNames() -> Set<String> {
        Set(SkillManager.shared.skills.filter { !$0.isBuiltIn }.map { "skill:\($0.name)" })
            .union(MCPProviderManager.shared.configuration.providers.map { "mcp_server:\($0.name)" })
            .union(SlashCommandRegistry.shared.customCommands.map { "command:\($0.name)" })
    }
}
