//
//  ManagementBadgeHeaderContractTests.swift
//  osaurusTests
//
//  A sidebar badge is a promise that the page says the same number: every
//  tab `ManagementBadgeStore` counts must pass a `count:` to its page header.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ManagementBadgeHeaderContractTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Page whose root header shows each badged tab, and that header's title.
    static let headers: [ManagementTab: (file: String, title: String)] = [
        .models: ("Views/Model/Catalog/LocalModelsCatalogPage.swift", "Local Models"),
        .providers: ("Views/Settings/RemoteProvidersView.swift", "Providers"),
        .tools: ("Views/Plugin/ToolsManagerView.swift", "Tools & MCP"),
        .skills: ("Views/Skill/SkillsView.swift", "Skills"),
        .commands: ("Views/SlashCommand/SlashCommandsView.swift", "Commands"),
        .agents: ("Views/Agent/AgentsView.swift", "Agents"),
        .automations: ("Views/Event/EventsView.swift", "Automations"),
        .approvals: ("Views/Approvals/ApprovalsView.swift", "Inbox"),
        .tasks: ("Views/Task/TasksView.swift", "Tasks"),
        .knowledge: ("Views/Knowledge/KnowledgeView.swift", "Knowledge"),
        .memory: ("Views/Memory/MemoryView.swift", "Memory"),
        .workspaces: ("Views/Workspaces/WorkspacesView.swift", "Workspaces"),
        .agentChannels: ("Views/Settings/AgentChannelConnectionCenterView.swift", "Channels"),
        .keys: ("Views/Credentials/KeysView.swift", "Vault"),
    ]

    @Test func everyBadgedTabIsListed() throws {
        let store = try Self.source("Managers/ManagementBadgeStore.swift")
        let assigned = Set(store.matches(of: /counts\[\.(\w+)\]\s*=/).map { String($0.1) })
        let listed = Set(Self.headers.keys.map { "\($0)" })
        #expect(assigned.subtracting(listed).isEmpty, "Badged tabs with no header entry: \(assigned.subtracting(listed).sorted())")
    }

    @Test func everyBadgedHeaderShowsACount() throws {
        for (tab, header) in Self.headers {
            let source = try Self.source(header.file)
            let blocks = source.components(separatedBy: "SettingsPageHeader(").dropFirst()
            let match = blocks.first { block in
                block.prefix(200).contains("title: \"\(header.title)\"")
            }
            let arguments = match.map { String($0.prefix { $0 != "{" }) } ?? ""
            #expect(match != nil, "\(tab): no SettingsPageHeader titled \(header.title) in \(header.file)")
            #expect(arguments.contains("count:"), "\(tab): \(header.title) header has no count: argument")
        }
    }
}
