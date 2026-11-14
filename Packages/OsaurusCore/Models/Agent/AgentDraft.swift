//
//  AgentDraft.swift
//  osaurus
//
//  The agent a New Agent chat is building: an unsaved record bound to the
//  Configurator chat that drafts it. The Configurator changes it through
//  `agent_draft`, the draft panel through direct edits; only the panel's
//  Create button turns it into an agent.
//

import Foundation

public struct AgentDraft: Codable, Identifiable, Equatable, Sendable {
    /// The parts of the draft the panel shows and the checklist tracks.
    public enum Field: String, Codable, CaseIterable, Sendable {
        case name
        case description
        case avatar
        case model
        case tools
        case instructions

        var label: String {
            switch self {
            case .name: return L("Name")
            case .description: return L("Description")
            case .avatar: return L("Avatar")
            case .model: return L("Model")
            case .tools: return L("Tools")
            case .instructions: return L("Instructions")
            }
        }
    }

    public var id: UUID
    public var sessionID: String?
    /// The unsaved agent. Its id is the one the created agent keeps.
    public var agent: Agent
    /// Fields the person changed in the panel. A Configurator patch leaves
    /// them alone unless the person asked for the change.
    public var userEdited: Set<Field>
    /// Fields the Configurator or the person has set, for the checklist.
    public var touched: Set<Field>
    /// Panel edits and undo notes for the Configurator's next turn.
    public var pendingUserEdits: [String]
    /// Why each tool choice was made, keyed by a capability key
    /// (`web_search_enabled`), an Apple app (`apple_apps.calendar`), or a
    /// tool name.
    public var reasons: [String: String]
    /// Imported skills, MCP servers, and other items that install when the
    /// person clicks Create. Optional so drafts saved before import load.
    var pendingImports: [ChatImportItem]?
    /// Set once Create saved the agent.
    public var createdAgentId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(sessionID: String?, agent: Agent, now: Date = Date()) {
        self.id = UUID()
        self.sessionID = sessionID
        self.agent = agent
        self.userEdited = []
        self.touched = []
        self.pendingUserEdits = []
        self.reasons = [:]
        self.createdAgentId = nil
        self.createdAt = now
        self.updatedAt = now
    }

    public var isCreated: Bool { createdAgentId != nil }

    var queuedImports: [ChatImportItem] { pendingImports ?? [] }

    /// Names of queued MCP servers, which the draft may list before they
    /// exist.
    var queuedMCPServerNames: [String] {
        queuedImports.compactMap { item in
            guard case .mcpServer(let spec) = item.payload else { return nil }
            return spec.entry.name
        }
    }

    /// Nothing drafted yet: no field set by either side.
    public var isEmpty: Bool { touched.isEmpty && agent.name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The onboarding-style progress steps, in order.
    public enum Step: String, CaseIterable, Sendable {
        case purpose, identity, model, tools, instructions

        var label: String {
            switch self {
            case .purpose: return L("Purpose")
            case .identity: return L("Name and look")
            case .model: return L("Model")
            case .tools: return L("Tools")
            case .instructions: return L("Instructions")
            }
        }
    }

    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .purpose:
            return !agent.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || touched.contains(.description)
        case .identity:
            return !agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .model:
            return touched.contains(.model)
        case .tools:
            return touched.contains(.tools)
        case .instructions:
            return !agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
