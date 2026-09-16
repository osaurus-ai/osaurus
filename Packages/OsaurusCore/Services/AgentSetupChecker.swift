//
//  AgentSetupChecker.swift
//  osaurus
//
//  Answers "can this agent actually run the way it is configured?" for the
//  first-run gate. It looks only at the machine-local things an agent can be
//  created WITH but not GRANTED by whoever created it: a working folder
//  without a bookmark, a pinned model that is not installed, a knowledge
//  grant with no collections, a system permission the OS has not given,
//  tools an MCP server or plugin on another Mac provided. These are exactly
//  the `requires` kinds an agent template carries, so the same report feeds
//  the template import checklist and the setup wizard.
//
//  Pure core (`check(_:environment:)`) so tests need no live services; the
//  `check(_:)` convenience wires the real ones.
//

import Foundation

public struct AgentSetupItem: Identifiable, Equatable, Sendable {
    public enum Severity: Sendable {
        /// The agent cannot do what it was configured for until fixed.
        case blocking
        /// Worth confirming, but the agent runs without it.
        case advisory
    }

    public let kind: TemplateRequirement.Kind
    public let severity: Severity
    /// Short label, e.g. "Working folder".
    public let title: String
    /// What is wrong and what fixes it.
    public let detail: String
    /// The value involved (path, model id, permission raw value, tool names).
    public let value: String

    public var id: String { "\(kind.rawValue):\(value)" }
    public var isBlocking: Bool { severity == .blocking }
}

public struct AgentSetupReport: Equatable, Sendable {
    public let agentId: UUID
    public let items: [AgentSetupItem]

    public var isClean: Bool { items.isEmpty }
    public var blocking: [AgentSetupItem] { items.filter(\.isBlocking) }
    public var hasBlockers: Bool { !blocking.isEmpty }

    /// One-line summary for tool envelopes and toasts.
    public var summary: String {
        items.map { "\($0.title): \($0.detail)" }.joined(separator: " ")
    }
}

public enum AgentSetupChecker {

    /// Everything the check reads from the machine, injectable for tests.
    struct Environment {
        var registeredToolNames: Set<String>
        var modelCatalog: ConfigModelReference.Catalog
        var isPermissionGranted: (SystemPermission) -> Bool
        var bookmarkResolves: (Data) -> Bool
        var knowledgeCollectionExists: (UUID) -> Bool

        @MainActor
        static func live() -> Environment {
            let collections = Set(KnowledgeCollectionStore.loadAll().map(\.id))
            return Environment(
                registeredToolNames: Set(ToolRegistry.shared.listTools().map(\.name)),
                modelCatalog: ConfigModelReference.liveCatalog(),
                // Cached: a live Automation probe can itself trigger a system prompt.
                isPermissionGranted: { SystemPermissionService.shared.cachedIsGranted($0) },
                bookmarkResolves: { FolderContextService.resolveSecurityScopedURL(from: $0) != nil },
                knowledgeCollectionExists: { collections.contains($0) }
            )
        }
    }

    @MainActor
    public static func check(_ agent: Agent) -> AgentSetupReport {
        check(agent, environment: .live())
    }

    static func check(_ agent: Agent, environment env: Environment) -> AgentSetupReport {
        var items: [AgentSetupItem] = []

        // Working folder: a path with no usable bookmark is the "orchestrator
        // said it has folder access but it loops forever" case.
        if let path = agent.workingFolderPath, !path.isEmpty {
            let ok = agent.workingFolderBookmark.map(env.bookmarkResolves) ?? false
            if !ok {
                items.append(
                    AgentSetupItem(
                        kind: .workingFolder, severity: .blocking,
                        title: L("Working Folder"),
                        detail: L("The agent points at \(path) but Osaurus has no access to it. Pick the folder to grant access."),
                        value: path))
            }
        }

        // Model: pinned to something this Mac cannot route.
        if let model = agent.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            if case .invalid = ConfigModelReference.resolve(model, catalog: env.modelCatalog) {
                items.append(
                    AgentSetupItem(
                        kind: .model, severity: .blocking,
                        title: L("Model"),
                        detail: L("\(model) is not installed or its provider is not connected. Install it or choose another model."),
                        value: model))
            }
        }

        // Knowledge: enabled with nothing to search, or grants pointing at
        // collections that do not exist here (a template from another Mac).
        if agent.settings.knowledgeEnabled {
            let granted = agent.settings.knowledgeCollectionIds
            let present = granted.filter(env.knowledgeCollectionExists)
            if present.isEmpty {
                items.append(
                    AgentSetupItem(
                        kind: .knowledgeCollection, severity: .advisory,
                        title: L("Knowledge"),
                        detail: L("Knowledge is on but no collection is granted. Grant or create one so the agent has something to search."),
                        value: "knowledge"))
            }
        }

        // System permissions the runtime gate will refuse on first call.
        if agent.settings.computerUseEnabled, !env.isPermissionGranted(.accessibility) {
            items.append(
                AgentSetupItem(
                    kind: .systemPermission, severity: .blocking,
                    title: L("Accessibility"),
                    detail: L("Computer Use needs the Accessibility permission. Grant it in System Settings."),
                    value: SystemPermission.accessibility.rawValue))
        }
        if agent.settings.appleScriptEnabled, !env.isPermissionGranted(.automation) {
            items.append(
                AgentSetupItem(
                    kind: .systemPermission, severity: .advisory,
                    title: L("Automation"),
                    detail: L("AppleScript will ask for Automation permission the first time it controls an app."),
                    value: SystemPermission.automation.rawValue))
        }

        // Manual tool list naming tools no server or plugin here provides.
        if agent.toolSelectionMode == .manual {
            let missing = (agent.manualToolNames ?? []).filter { !env.registeredToolNames.contains($0) }
            if !missing.isEmpty {
                let joined = missing.sorted().joined(separator: ", ")
                items.append(
                    AgentSetupItem(
                        kind: .mcpServer, severity: .advisory,
                        title: L("Tools"),
                        detail: L("Not available on this Mac: \(joined). Add the MCP server or plugin that provides them, or remove them from the agent."),
                        value: joined))
            }
        }

        return AgentSetupReport(agentId: agent.id, items: items)
    }
}
