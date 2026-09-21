//
//  SettingsSearchIndexTests.swift
//  OsaurusCoreTests
//
//  Guardrails for the settings-search index: every entry must point at a
//  tab that actually renders in the sidebar, ids must be unique (they double
//  as landing-anchor ids for scroll-to + glow), and inner-navigation subTab
//  raw values must decode into the destination tab's own sub-tab enum so a
//  rename there can't silently break search deep-links.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SettingsSearchIndexTests {

    @Test func everyEntryTargetsAVisibleTab() {
        let visible = Set(ManagementTab.visibleCases)
        for entry in SettingsSearchIndex.entries {
            #expect(
                visible.contains(entry.tab),
                "\(entry.id) targets \(entry.tab.rawValue), which is not in the sidebar"
            )
        }
    }

    @Test func entryIdsAreUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        #expect(ids.count == Set(ids).count, "duplicate SettingsSearchEntry ids")
    }

    /// subTab raw values are consumed by the destination views' own tab
    /// enums; a stale string would navigate to the tab but land on the
    /// wrong sub-tab with no glow.
    @Test func subTabRawValuesDecodeIntoDestinationEnums() {
        for entry in SettingsSearchIndex.entries {
            guard let subTab = entry.subTab else { continue }
            switch entry.tab {
            case .voice:
                #expect(
                    VoiceTab(rawValue: subTab) != nil,
                    "\(entry.id): \(subTab) is not a VoiceTab raw value"
                )
            case .server:
                #expect(
                    ServerSettingsSection(rawValue: subTab) != nil,
                    "\(entry.id): \(subTab) is not a ServerSettingsSection raw value"
                )
            case .imageGeneration:
                #expect(
                    ImageGenerationTab(rawValue: subTab) != nil,
                    "\(entry.id): \(subTab) is not an ImageGenerationTab raw value"
                )
            case .memory:
                #expect(
                    MemoryTab(rawValue: subTab) != nil,
                    "\(entry.id): \(subTab) is not a MemoryTab raw value"
                )
            case .agents:
                // Routed by `AgentsView.routeSettingsLanding` from the landing
                // id; the subTab must still be a real detail tab raw value.
                #expect(
                    AgentDetailTabRoute.resolve(subTab) != nil,
                    "\(entry.id): \(subTab) is not an agent detail tab raw value"
                )
            default:
                Issue.record(
                    "\(entry.id) declares subTab \(subTab) but \(entry.tab.rawValue) has no sub-tab routing in ManagementView.handleResultSelected"
                )
            }
        }
    }

    @Test func breadcrumbCollapsesSectionMatchingTabLabel() {
        // "General › General › Global Hotkey" would read as a stutter; the
        // breadcrumb drops a section that just repeats the tab label.
        let entry = SettingsSearchEntry(
            id: "test.collapse",
            tab: .settings,
            section: "General",
            title: "Global Hotkey"
        )
        #expect(entry.breadcrumb == ["General", "Global Hotkey"])

        let nested = SettingsSearchEntry(
            id: "test.nested",
            tab: .voice,
            section: "Speech to Text",
            title: "Pause Detection"
        )
        #expect(nested.breadcrumb == ["Voice", "Speech to Text", "Pause Detection"])
    }

    @Test func searchFindsRelocatedStorageEntries() {
        // The standalone Storage tab is gone: the models directory +
        // external sources live on the General tab, and the encryption
        // panel lives on the Privacy tab's Storage sub-tab.
        let directoryHits = SettingsSearchIndex.search("models directory")
        #expect(directoryHits.contains { $0.id == "storage.location" && $0.tab == .settings })

        let externalHits = SettingsSearchIndex.search("lm studio")
        #expect(externalHits.contains { $0.id == "storage.externalModels" && $0.tab == .settings })

        let encryptionHits = SettingsSearchIndex.search("sqlcipher")
        #expect(encryptionHits.contains { $0.id == "storage.encryption" && $0.tab == .privacy })
    }

    @Test func searchFindsAgentEntries() {
        // Both entries land on the Agents tab, whose header / agent grid
        // carry the matching `settingsLandingAnchor` ids.
        let agentHits = SettingsSearchIndex.search("agents")
        #expect(agentHits.contains { $0.id == "agents.overview" && $0.tab == .agents })

        let databaseHits = SettingsSearchIndex.search("agent database")
        #expect(databaseHits.contains { $0.id == "agents.database" && $0.tab == .agents })

        let tableHits = SettingsSearchIndex.search("saved views")
        #expect(tableHits.contains { $0.id == "agents.database" })
    }

    @Test func searchFindsAgentChannelIntegrationEntries() {
        let integrationHits = SettingsSearchIndex.search("integrations")
        #expect(integrationHits.contains { $0.id == "agentChannels.overview" && $0.tab == .agentChannels })

        let slackHits = SettingsSearchIndex.search("slack signing secret")
        #expect(slackHits.contains { $0.id == "agentChannels.slack" && $0.tab == .agentChannels })

        let telegramHits = SettingsSearchIndex.search("telegram bot token")
        #expect(telegramHits.contains { $0.id == "agentChannels.telegram" && $0.tab == .agentChannels })

        let whatsappHits = SettingsSearchIndex.search("whatsapp qr code")
        #expect(whatsappHits.contains { $0.id == "agentChannels.whatsapp" && $0.tab == .agentChannels })

        let killSwitchHits = SettingsSearchIndex.search("kill switch")
        #expect(killSwitchHits.contains { $0.id == "agentChannels.globalWrites" && $0.tab == .agentChannels })

        let n8nHits = SettingsSearchIndex.search("n8n")
        #expect(n8nHits.contains { $0.id == "agentChannels.n8n" && $0.tab == .agentChannels })
        let dockerHits = SettingsSearchIndex.search("host.docker.internal")
        #expect(dockerHits.contains { $0.id == "agentChannels.n8n" })
    }

    /// Searching "sampler" returned ZERO results in the live app, even though
    /// Settings has a "Sampling Defaults" section and Live Activity renders a
    /// row literally labelled "Sampler last used". The matcher is substring /
    /// token based with `allowFuzzy: false`, so "sampler" can never reach
    /// "sampling" — no stemming bridges the two. A user who types the word
    /// printed on screen found nothing.
    ///
    /// Both entries now carry the token explicitly. This test fails against
    /// the old keyword lists.
    @Test func searchFindsSamplerByTheWordShownOnScreen() {
        let hits = SettingsSearchIndex.search("sampler")
        #expect(hits.contains { $0.id == "server.generation" && $0.tab == .server })
        #expect(hits.contains { $0.id == "server.liveActivity" && $0.tab == .server })

        // The pre-existing spelling must keep working — this is an addition,
        // not a replacement.
        let sampling = SettingsSearchIndex.search("sampling")
        #expect(sampling.contains { $0.id == "server.generation" })

        // The other sampler knobs the Sampling Defaults panel exposes.
        for term in ["top k", "min p", "temperature"] {
            #expect(
                SettingsSearchIndex.search(term).contains { $0.id == "server.generation" },
                "\"\(term)\" should reach Sampling Defaults")
        }
    }

    @Test func everyVisibleTabHasAnIndexRow() {
        let indexed = Set(SettingsSearchIndex.entries.map(\.tab))
        for tab in ManagementTab.visibleCases {
            #expect(indexed.contains(tab), "\(tab.rawValue) has no SettingsSearchIndex row")
        }
    }

    @Test func contextBudgetRanksWindowCapAboveMemory() {
        let budgetHits = SettingsSearchIndex.search("context budget")
        let capIndex = budgetHits.firstIndex { $0.id == "settings.chat.contextLength" }
        let memoryIndex = budgetHits.firstIndex { $0.id == "memory.settings.budget" }
        #expect(capIndex != nil, "context budget must reach Context Window Cap")
        if let capIndex, let memoryIndex {
            #expect(capIndex < memoryIndex)
        }

        let memoryHits = SettingsSearchIndex.search("memory budget")
        #expect(memoryHits.contains { $0.id == "memory.settings.budget" })

        #expect(
            SettingsSearchIndex.search("context window").contains {
                $0.id == "settings.chat.contextLength"
            })
        #expect(
            SettingsSearchIndex.search("context length").contains {
                $0.id == "settings.chat.contextLength"
            })
        #expect(
            SettingsSearchIndex.search("max tokens").contains { $0.id == "server.generation" })
    }

    @Test func permissionsTitleIsNotToolCatalog() {
        let entry = SettingsSearchIndex.entries.first { $0.id == "permissions.tools" }
        #expect(entry?.title == "macOS Permissions")
        #expect(
            SettingsSearchIndex.search("tool catalog").contains { $0.id == "tools.overview" })
    }

    @Test func landingAnchorsInViewsAreIndexed() throws {
        let viewsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Views")
        let privacyRoot = viewsRoot.deletingLastPathComponent()
            .appendingPathComponent("PrivacyFilter")
        let indexed = Set(SettingsSearchIndex.entries.map(\.id))
        var missing: [String] = []
        for root in [viewsRoot, privacyRoot] {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            let pattern = /settingsLandingAnchor\("([^"]+)"\)|anchorId:\s*"([^"]+)"/
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for match in text.matches(of: pattern) {
                    let id = String(match.1 ?? match.2 ?? "")
                    // Interpolated anchors (e.g. agentChannels.\(kind)) are
                    // not catalog ids — skip them.
                    guard !id.isEmpty, !id.contains("\\("), !indexed.contains(id) else { continue }
                    missing.append("\(id) in \(url.lastPathComponent)")
                }
            }
        }
        #expect(missing.isEmpty, "landing ids missing from SettingsSearchIndex: \(missing)")
    }
}
