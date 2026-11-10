//
//  WorkflowStepAgent.swift
//  osaurus
//
//  Resolves a tool step's `agent` key to the agent whose permission the
//  call uses. Order: a teammate template id, then an agent id, then a
//  unique agent name (case-insensitive). Built-in and hidden agents never
//  match: a step cannot borrow the Orchestrator's or a worker's reach.
//

import Foundation

enum WorkflowStepAgent {

    struct Match: Equatable, Sendable {
        let id: UUID
        let name: String
        let enabledAppleApps: Set<AppleApp>
        /// The agent's working folder: a folder tool step reads there.
        var workingFolder: URL? = nil
    }

    static func resolve(_ reference: String, in agents: [Agent]) -> Agent? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = agents.filter { !$0.isBuiltIn && !Agent.hiddenBuiltInAgentIds.contains($0.id) }
        if let id = UUID(uuidString: trimmed) {
            return candidates.first { $0.sourceTemplateID == id } ?? candidates.first { $0.id == id }
        }
        let named = candidates.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        return named.count == 1 ? named[0] : nil
    }

    @MainActor
    static func resolveLive(_ reference: String) -> Match? {
        let manager = AgentManager.shared
        guard let agent = resolve(reference, in: manager.agents) else { return nil }
        return Match(
            id: agent.id, name: agent.name,
            enabledAppleApps: manager.effectiveCapabilities(for: agent.id).enabledAppleApps,
            workingFolder: workingFolderURL(of: agent))
    }

    static func workingFolderURL(of agent: Agent) -> URL? {
        if let bookmark = agent.workingFolderBookmark,
            let url = FolderContextService.resolveSecurityScopedURL(from: bookmark)
        {
            return url
        }
        guard let path = agent.workingFolderPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shown when the step's agent is not on this Mac.
    static func missingMessage(_ reference: String) -> String {
        if let teammate = UUID(uuidString: reference).flatMap(Teammate.teammate(forTemplateID:)) {
            return L("This step reads with \(teammate.rawValue.capitalized)'s permission, and that agent is no longer on this Mac.")
        }
        return L("This step reads with the permission of “\(reference)”, and no agent here answers to that.")
    }
}
