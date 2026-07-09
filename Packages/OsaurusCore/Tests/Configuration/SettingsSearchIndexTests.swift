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
        // The models directory + external sources moved from General to
        // Storage; searching for them must land on the Storage tab.
        let directoryHits = SettingsSearchIndex.search("models directory")
        #expect(directoryHits.contains { $0.id == "storage.location" && $0.tab == .storage })

        let externalHits = SettingsSearchIndex.search("lm studio")
        #expect(externalHits.contains { $0.id == "storage.externalModels" && $0.tab == .storage })

        let encryptionHits = SettingsSearchIndex.search("sqlcipher")
        #expect(encryptionHits.contains { $0.id == "storage.encryption" && $0.tab == .storage })
    }

    @Test func searchFindsAgentChannelIntegrationEntries() {
        let integrationHits = SettingsSearchIndex.search("integrations")
        #expect(integrationHits.contains { $0.id == "agentChannels.overview" && $0.tab == .agentChannels })

        let slackHits = SettingsSearchIndex.search("slack signing secret")
        #expect(slackHits.contains { $0.id == "agentChannels.slack" && $0.tab == .agentChannels })

        let telegramHits = SettingsSearchIndex.search("telegram bot token")
        #expect(telegramHits.contains { $0.id == "agentChannels.telegram" && $0.tab == .agentChannels })

        let killSwitchHits = SettingsSearchIndex.search("kill switch")
        #expect(killSwitchHits.contains { $0.id == "agentChannels.globalWrites" && $0.tab == .agentChannels })
    }
}
