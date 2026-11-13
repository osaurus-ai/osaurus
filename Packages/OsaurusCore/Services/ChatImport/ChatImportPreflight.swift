//
//  ChatImportPreflight.swift
//  osaurus
//
//  Before the card shows: how each row relates to what is installed
//  (already installed, update available, name in use) and what this Mac
//  can run (stdio servers need the VM sandbox, `npx`/`uvx` need sandbox
//  network, `docker run` needs Docker on the host).
//

import Foundation

enum ChatImportPreflight {
    struct Environment: Sendable, Equatable {
        /// The VM sandbox can host stdio servers.
        var stdioSandbox: Bool
        /// The target agent's sandbox may reach the network.
        var agentNetworkEnabled: Bool
        /// `docker` is on PATH or in a standard install location.
        var dockerInstalled: Bool
    }

    static func liveEnvironment(targetAgentId: UUID) async -> Environment {
        let stdio = await SandboxManager.shared.supportsSandboxedStdio()
        let network = await MainActor.run {
            AgentManager.shared.effectiveAutonomousExec(for: targetAgentId)?.sandboxNetworkEnabled ?? true
        }
        return Environment(
            stdioSandbox: stdio, agentNetworkEnabled: network,
            dockerInstalled: HostCommandLocator.find("docker") != nil)
    }

    @MainActor
    static func annotate(_ items: inout [ChatImportItem], environment: Environment) {
        let store = ChatImportProvenanceStore.shared
        for index in items.indices {
            var item = items[index]
            switch item.payload {
            case .instructions:
                let exists: Bool
                if item.kind == .agent {
                    exists = AgentManager.shared.agents.contains {
                        !$0.isBuiltIn && $0.name.caseInsensitiveCompare(item.name) == .orderedSame
                    }
                } else {
                    exists = SkillManager.shared.skill(named: item.name) != nil
                }
                markState(&item, exists: exists, record: store.find(kind: item.kind, name: item.name))
            case .command(let entry):
                let exists = ConfigExporter.manageableCommands().contains {
                    $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
                }
                markState(&item, exists: exists, record: store.find(kind: .command, name: entry.name))
            case .mcpServer(let spec):
                let existing = ConfigExporter.manageableMCPProviders().first {
                    $0.name.caseInsensitiveCompare(spec.entry.name) == .orderedSame
                }
                if let existing, sameServer(existing, spec.entry) {
                    let record = store.find(kind: .mcpServer, name: spec.entry.name)
                    markState(&item, exists: true, record: record ?? ChatImportProvenance(
                        kind: ChatImportItemKind.mcpServer.rawValue, name: spec.entry.name, importSource: item.origin,
                        contentHash: item.contentHash, importedAt: Date()))
                } else {
                    markState(&item, exists: existing != nil, record: nil)
                }
                runtimeChecks(&item, spec: spec, environment: environment)
            case .plugin(let repo):
                let prefix = "github:\(repo.owner)/\(repo.name)/".lowercased()
                let installed = SkillManager.shared.skills.contains { $0.pluginId?.lowercased().hasPrefix(prefix) == true }
                    || SlashCommandRegistry.shared.customCommands.contains {
                        $0.pluginId?.lowercased().hasPrefix(prefix) == true
                    }
                if installed {
                    item.state = .alreadyInstalled
                    item.included = false
                    item.warnings.append(L("Installing again updates the plugin's skills, agents, and commands."))
                }
            case .manualStep:
                break
            }
            items[index] = item
        }
    }

    /// Same name and same source content: nothing to do. Same name, a
    /// recorded import of the same item with new content: an update. Same
    /// name otherwise: a clash, defaulting to keeping both.
    private static func markState(_ item: inout ChatImportItem, exists: Bool, record: ChatImportProvenance?) {
        guard exists else { return }
        if let record, record.contentHash == item.contentHash {
            item.state = .alreadyInstalled
            item.included = false
        } else if record != nil {
            item.state = .updateAvailable
            item.clashChoice = .replace
        } else {
            item.state = .nameClash
            item.clashChoice = .keepBoth
        }
    }

    private static func sameServer(_ provider: MCPProvider, _ entry: MCPServerEntry) -> Bool {
        if let url = entry.url, !url.isEmpty {
            return provider.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return provider.command == (entry.command ?? "") && provider.args == (entry.args ?? [])
    }

    static func runtimeChecks(_ item: inout ChatImportItem, spec: ChatImportMCPSpec, environment: Environment) {
        guard spec.entry.transport == "stdio" else { return }
        if spec.runsDocker {
            item.included = false
            item.risks.append(ConfigRisk.stdioOnHost(spec.entry.name))
            item.warnings.append(L("Runs on this Mac (needs Docker). Check it to install it outside the sandbox."))
            if !environment.dockerInstalled {
                item.warnings.append(L("Docker wasn't found on this Mac. Install Docker Desktop before turning it on."))
            }
            return
        }
        guard environment.stdioSandbox else {
            item.blockedReason = L(
                "Local MCP servers run inside the Osaurus sandbox, which needs macOS 26 or later with the sandbox set up.")
            item.included = false
            return
        }
        let launcher = ((spec.entry.command ?? "") as NSString).lastPathComponent
        if ["npx", "uvx", "bunx", "pnpm", "pip", "pipx", "uv"].contains(launcher), !environment.agentNetworkEnabled {
            item.warnings.append(
                L("It downloads its package when it starts, but sandbox network access is off for this agent."))
        }
    }
}

/// Finds a command on PATH or in the standard Homebrew and app install
/// locations, without running a shell.
enum HostCommandLocator {
    static let extraDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin",
        "/Applications/OrbStack.app/Contents/MacOS/xbin",
    ]

    static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories + extraDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
