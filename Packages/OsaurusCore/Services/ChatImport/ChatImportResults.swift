//
//  ChatImportResults.swift
//  osaurus
//
//  After apply: a connection test for new MCP servers (run as the agent
//  that will use them, with room for a cold sandbox VM) and the short
//  summary the model repeats. The summary is built from names and fixed
//  wording only; no page text reaches it.
//

import Foundation

enum ChatImportConnectionTest {
    struct Result: Sendable, Equatable {
        var name: String
        var connected: Bool
        var toolCount: Int
        var error: String?
    }

    /// Covers a first sandbox boot plus an `npx` package download.
    static let timeoutSeconds: Double = 120

    @MainActor
    static func run(serverNames: [String], agentId: UUID) async -> [Result] {
        var out: [Result] = []
        for name in serverNames {
            guard
                let provider = ConfigExporter.manageableMCPProviders().first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }), provider.enabled
            else { continue }
            let manager = MCPProviderManager.shared
            if manager.providerStates[provider.id]?.isConnected != true {
                let error = await connectWithTimeout(providerId: provider.id, agentId: agentId)
                let state = manager.providerStates[provider.id]
                out.append(
                    Result(
                        name: name, connected: state?.isConnected == true, toolCount: state?.discoveredToolCount ?? 0,
                        error: state?.isConnected == true ? nil : (error ?? state?.lastError)))
            } else {
                let state = manager.providerStates[provider.id]
                out.append(Result(name: name, connected: true, toolCount: state?.discoveredToolCount ?? 0))
            }
        }
        return out
    }

    /// The connect error, a timeout note, or nil once connected.
    private static func connectWithTimeout(providerId: UUID, agentId: UUID) async -> String? {
        await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { await connect(providerId: providerId, agentId: agentId) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return L("still starting after \(Int(timeoutSeconds)) seconds")
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @MainActor
    private static func connect(providerId: UUID, agentId: UUID) async -> String? {
        do {
            try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                try await MCPProviderManager.shared.connect(providerId: providerId)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum ChatImportSummary {
    static func text(
        results: [ChatImportItemResult],
        connections: [ChatImportConnectionTest.Result] = [],
        refusals: [ChatImportRefusal] = [],
        openedTemplates: Int = 0
    ) -> String {
        var sentences: [String] = []
        let landed = results.filter { $0.status == .installed || $0.status == .updated || $0.status == .needsSetup }
        let rolledBack = results.contains { $0.status == .rolledBack }
        let failed = results.filter { $0.status == .failed }

        if rolledBack {
            let names = failed.map(\.name).joined(separator: ", ")
            sentences.append(L("Nothing was installed because \(names.isEmpty ? L("one item") : names) failed."))
        } else if !landed.isEmpty {
            sentences.append(L("Installed \(describe(landed))."))
        }
        for row in failed {
            sentences.append(L("Couldn't install \(row.name): \(row.message ?? L("unknown error"))."))
        }
        if !rolledBack {
            for row in results where row.status == .needsSetup {
                sentences.append(L("\(row.name): \(row.message ?? L("needs setup in Settings"))."))
            }
        }
        for connection in connections {
            if connection.connected {
                sentences.append(L("\(connection.name) connected with \(connection.toolCount) tools."))
            } else if let error = connection.error {
                sentences.append(L("\(connection.name) didn't connect yet (\(error))."))
            }
        }
        for refusal in refusals { sentences.append(refusal.message) }
        if openedTemplates > 0 { sentences.append(L("Opened the template review for the store link.")) }
        if sentences.isEmpty { sentences.append(L("Nothing was installed.")) }
        return sentences.joined(separator: " ")
    }

    /// "skill Tempo and MCP server Linear", or counts past three items.
    static func describe(_ rows: [ChatImportItemResult]) -> String {
        func noun(_ kind: ChatImportItemKind, _ count: Int) -> String {
            switch kind {
            case .skill: return count == 1 ? L("skill") : L("skills")
            case .agent: return count == 1 ? L("agent") : L("agents")
            case .mcpServer: return count == 1 ? L("MCP server") : L("MCP servers")
            case .command: return count == 1 ? L("command") : L("commands")
            case .plugin: return count == 1 ? L("plugin") : L("plugins")
            case .manualStep: return ""
            }
        }
        let parts: [String]
        if rows.count <= 3 {
            parts = rows.map { "\(noun($0.kind, 1)) \($0.name)" }
        } else {
            parts = ChatImportItemKind.allCases.compactMap { kind in
                let count = rows.filter { $0.kind == kind }.count
                return count == 0 ? nil : "\(count) \(noun(kind, count))"
            }
        }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " " + L("and") + " " + (parts.last ?? "")
    }
}
