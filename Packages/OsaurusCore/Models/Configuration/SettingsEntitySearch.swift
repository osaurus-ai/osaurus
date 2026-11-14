//
//  SettingsEntitySearch.swift
//  osaurus
//
//  The second results group in Management search: the user's own things by
//  name (an agent called "Researcher", a workflow, a downloaded model, an
//  MCP server, a provider, a theme). `SettingsSearchIndex` answers "where is
//  the setting"; this answers "where is my thing". Matching is pure so it
//  can be tested; `liveCandidates()` and `open(_:)` touch app state.
//

import Foundation

struct SettingsEntityCandidate: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case agent
        case workflow
        case model
        case mcpServer
        case provider

        /// Catalog key.
        var label: String {
            switch self {
            case .agent: "Agent"
            case .workflow: "Workflow"
            case .model: "Model"
            case .mcpServer: "MCP Server"
            case .provider: "Provider"
            }
        }

        var icon: String {
            switch self {
            case .agent: "person.crop.circle"
            case .workflow: "point.3.connected.trianglepath.dotted"
            case .model: "cube"
            case .mcpServer: "server.rack"
            case .provider: "cloud"
            }
        }
    }

    let kind: Kind
    /// Stable identity within the kind (UUID string or model repo id).
    let key: String
    let name: String

    var id: String { "\(kind.rawValue):\(key)" }
}

enum SettingsEntitySearch {
    static let minimumQueryLength = 2
    static let limitPerKind = 5

    /// Candidates whose name matches `query`, best first: exact name, name
    /// prefix, word prefix (every query word starts a word of the name),
    /// then substring. Case- and diacritic-insensitive.
    static func match(_ query: String, in candidates: [SettingsEntityCandidate]) -> [SettingsEntityCandidate] {
        let needle = normalize(query)
        guard needle.count >= minimumQueryLength else { return [] }
        let queryWords = needle.split(separator: " ").map(String.init)

        var scored: [(candidate: SettingsEntityCandidate, rank: Int, order: Int)] = []
        for (order, candidate) in candidates.enumerated() {
            let name = normalize(candidate.name)
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let rank: Int
            if name == needle {
                rank = 0
            } else if name.hasPrefix(needle) {
                rank = 1
            } else if queryWords.allSatisfy({ q in words.contains { $0.hasPrefix(q) } }) {
                rank = 2
            } else if name.contains(needle) {
                rank = 3
            } else {
                continue
            }
            scored.append((candidate, rank, order))
        }
        scored.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }

        var perKind: [SettingsEntityCandidate.Kind: Int] = [:]
        return scored.compactMap { item in
            let count = perKind[item.candidate.kind, default: 0]
            guard count < limitPerKind else { return nil }
            perKind[item.candidate.kind] = count + 1
            return item.candidate
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: - Live state

    /// Everything the user owns that has a name, read once per search
    /// session (model download checks touch disk).
    @MainActor
    static func liveCandidates() -> [SettingsEntityCandidate] {
        var all: [SettingsEntityCandidate] = []
        all += AgentManager.shared.agents.map {
            .init(kind: .agent, key: $0.id.uuidString, name: $0.displayName)
        }
        all += InstalledWorkflowStore.shared.workflows.map {
            .init(kind: .workflow, key: $0.id.uuidString, name: $0.name)
        }
        all += ModelManager.shared.availableModels.filter(\.isDownloaded).map {
            .init(kind: .model, key: $0.id, name: $0.name)
        }
        all += MCPProviderManager.shared.configuration.providers.map {
            .init(kind: .mcpServer, key: $0.id.uuidString, name: $0.name)
        }
        all += RemoteProviderManager.shared.configuration.providers.map {
            .init(kind: .provider, key: $0.id.uuidString, name: $0.name)
        }
        return all
    }

    /// Navigates to the candidate's own page (or the list that holds it).
    @MainActor
    static func open(_ candidate: SettingsEntityCandidate) {
        let state = ManagementStateManager.shared
        switch candidate.kind {
        case .agent:
            state.pendingAgentDetailId = UUID(uuidString: candidate.key)
            state.selectedTab = .agents
        case .workflow:
            state.pendingWorkflowDetailId = UUID(uuidString: candidate.key)
            state.selectedTab = .workflows
        case .model:
            state.pendingModelDetailId = candidate.key
            state.openLocalModels(kind: .language)
        case .mcpServer:
            state.pendingToolsSubTab = ToolsTab.services.rawValue
            state.pendingMCPProviderEditId = UUID(uuidString: candidate.key)
            state.selectedTab = .tools
        case .provider:
            state.selectedTab = .providers
        }
    }
}
