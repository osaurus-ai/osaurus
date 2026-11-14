//
//  ManagementTabTests.swift
//  OsaurusCoreTests
//
//  Guardrails for the management window's information architecture:
//  group (`ManagementSection`) > category (sidebar tab) > item (child tab).
//  Every tab is either a sidebar category in exactly one group or a child
//  of exactly one category, the flattened order covers every tab, and
//  legacy deep-link raw values keep resolving as their destinations move.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ManagementTabTests {

    // MARK: - Hierarchy

    @Test func everyTabIsACategoryOrAChild() {
        for tab in ManagementTab.allCases {
            let owningSections = ManagementSection.allCases.filter { $0.tabs.contains(tab) }
            if ManagementTab.mainWindowCases.contains(tab) {
                #expect(owningSections.isEmpty, "\(tab.rawValue) lives in the main window, not the sidebar")
                #expect(tab.parent == nil)
            } else if let parent = tab.parent {
                #expect(owningSections.isEmpty, "\(tab.rawValue) is a child and must not be in the sidebar")
                #expect(parent.parent == nil, "\(tab.rawValue)'s parent must be a sidebar category")
                #expect(parent.children.contains(tab), "\(parent.rawValue).children must list \(tab.rawValue)")
                #expect(tab.section == parent.section)
                #expect(tab.sidebarTab == parent)
            } else {
                #expect(
                    owningSections.count == 1,
                    "\(tab.rawValue) must appear in exactly one section, found \(owningSections.map(\.rawValue))"
                )
                #expect(owningSections.first == tab.section)
                #expect(tab.sidebarTab == tab)
            }
        }
    }

    @Test func childrenAgreeWithParent() {
        for tab in ManagementTab.allCases {
            for child in tab.children {
                #expect(child.parent == tab, "\(child.rawValue).parent must be \(tab.rawValue)")
                #expect(!child.subtitle.isEmpty, "\(child.rawValue) needs a row subtitle on its parent's page")
            }
        }
    }

    @Test func visibleOrderCoversAllTabsWithoutDuplicates() {
        let visible = ManagementTab.visibleCases
        #expect(visible.count == Set(visible).count, "visible order must not repeat a tab")
        #expect(Set(visible).isDisjoint(with: ManagementTab.mainWindowCases))
        #expect(
            Set(visible).union(ManagementTab.mainWindowCases) == Set(ManagementTab.allCases),
            "visible order plus main-window surfaces must cover every ManagementTab case")
        #expect(ManagementTab.sidebarCases == ManagementSection.allCases.flatMap(\.tabs))
    }

    @Test func agentsArePinnedFirstAndWorkflowsAndInsightsLiveInTheMainWindow() {
        #expect(ManagementSection.allCases.first == .home)
        #expect(ManagementSection.home.title.isEmpty)
        #expect(ManagementSection.home.tabs == [.agents, .automations, .approvals])
        #expect(ManagementTab.mainWindowCases == [.workflows, .insights])
        #expect(ManagementTab.approvals.rawValue == "approvals")
        #expect(ManagementTab.approvals.label == "Inbox")
        #expect(ManagementTab.resolved(from: "inbox") == .approvals)
        #expect(ManagementTab.resolved(from: "needsYou") == .approvals)
        #expect(ManagementSection.allCases.last == .developers)
        #expect(ManagementSection.developers.tabs == [.server, .sandbox, .tasks])
        #expect(ManagementTab.defaultTab == .agents)
        #expect(ManagementTab.sidebarCases.first == .agents)
    }

    @Test func builtInAgentsHangOffAgents() {
        #expect(ManagementTab.agents.children == [.orchestrator, .architect, .configurator, .delegation])
        #expect(ManagementTab.architect.section == .home)
        #expect(ManagementTab.orchestrator.sidebarTab == .agents)
        #expect(ManagementTab.configurator.sidebarTab == .agents)
        #expect(ManagementTab.delegation.sidebarTab == .agents)
    }

    @Test func groupedCategories() {
        #expect(ManagementSection.general.tabs == [.settings, .chat, .keys, .identity, .privacy])
        #expect(ManagementSection.sharing.tabs == [.workspaces, .access, .devices])
        #expect(ManagementSection.sharing.title == "Sharing")
        #expect(ManagementSection.models.tabs == [.models, .providers, .modelDefaults])
        #expect(ManagementTab.identity.children == [.credits])
        #expect(ManagementTab.workspaces.parent == nil)
        #expect(ManagementTab.workspaces.section == .sharing)
        #expect(ManagementTab.privacy.children == [.permissions])
        #expect(ManagementTab.computerUse.children == [.browser])
        #expect(ManagementTab.devices.children == [.connect])
        #expect(ManagementTab.connect.section == .sharing)
        #expect(ManagementTab.connect.label == "Mobile")
        #expect(ManagementTab.chat.children == [.commands])
        #expect(ManagementSection.context.tabs == [.memory, .projects, .knowledge, .skills])
        #expect(ManagementTab.projects.parent == nil)
        #expect(ManagementTab.projects.label == "Projects")
    }

    // MARK: - Legacy raw-value resolution

    @Test func resolvedMapsLegacyRawValues() {
        #expect(ManagementTab.resolved(from: "dashboard") == .credits)
        #expect(ManagementTab.resolved(from: "channels") == .agentChannels)
        #expect(ManagementTab.resolved(from: "integrations") == .agentChannels)
        #expect(ManagementTab.resolved(from: "agent-channels") == .agentChannels)
        // Storage is Privacy & Security → Data & Storage.
        #expect(ManagementTab.resolved(from: "storage") == .privacy)
        #expect(ManagementTab.legacySubTab(from: "storage") == PrivacyTab.storage.rawValue)
        #expect(ManagementTab.legacySubTab(from: "privacy") == nil)
        // Custom themes were retired; Appearance lives on General.
        #expect(ManagementTab.resolved(from: "themes") == .settings)
        #expect(ManagementTab.resolved(from: "teams") == .workspaces)
        #expect(ManagementTab.resolved(from: "schedules") == .automations)
        #expect(ManagementTab.resolved(from: "watchers") == .automations)
        #expect(ManagementTab.resolved(from: "events") == .automations)
        #expect(ManagementTab.resolved(from: "model-defaults") == .modelDefaults)
        // Sync merged into Devices and Mobile is its child page (kept for one
        // release); Server's Relays moved to Access.
        #expect(ManagementTab.resolved(from: "sync") == .devices)
        #expect(ManagementTab.resolved(from: "connect") == .connect)
        #expect(ManagementTab.resolved(from: "mobile") == .connect)
        #expect(ManagementTab.resolved(from: "relays") == .access)
    }

    @Test func resolvedRoundTripsCurrentRawValues() {
        for tab in ManagementTab.allCases {
            #expect(ManagementTab.resolved(from: tab.rawValue) == tab)
        }
        #expect(ManagementTab.resolved(from: "not-a-tab") == nil)
    }

    @Test func renamedTabsKeepStableRawValues() {
        #expect(ManagementTab.settings.rawValue == "settings")
        #expect(ManagementTab.settings.label == "General")
        #expect(ManagementTab.chat.rawValue == "chat")
        #expect(ManagementTab.chat.label == "Chat")
        #expect(ManagementTab.models.rawValue == "models")
        #expect(ManagementTab.models.label == "Local Models")
        #expect(ManagementTab.identity.label == "Osaurus ID")
        #expect(ManagementTab.privacy.label == "Privacy & Security")
        #expect(ManagementTab.keys.rawValue == "keys")
        #expect(ManagementTab.keys.label == "Vault")
        #expect(ManagementTab.keys.icon == "key.fill")
        #expect(ManagementTab.computerUse.label == "Computer & Browser Use")
        #expect(ManagementTab.imageGeneration.rawValue == "imageGeneration")
        #expect(ManagementTab.imageGeneration.label == "Images & Video")
        #expect(ManagementTab.automations.label == "Automations")
        #expect(ManagementTab.automations.icon == "bolt.fill")
    }
}
