//
//  ManagementTabTests.swift
//  OsaurusCoreTests
//
//  Guardrails for the management sidebar's information architecture:
//  every tab must belong to exactly one labeled section, the flattened
//  section order must cover every tab, and legacy deep-link raw values
//  (`"dashboard"`, `"channels"`) must keep resolving as their destinations
//  move. These pin the Settings IA cleanup so a future tab addition can't
//  silently fall out of the sidebar.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ManagementTabTests {

    // MARK: - Section membership

    @Test func everyTabBelongsToExactlyOneSection() {
        for tab in ManagementTab.allCases {
            let owningSections = ManagementSection.allCases.filter { $0.tabs.contains(tab) }
            #expect(
                owningSections.count == 1,
                "\(tab.rawValue) must appear in exactly one section, found \(owningSections.map(\.rawValue))"
            )
            // The tab's own `section` property must agree with the section
            // that lists it, so the two definitions can't drift apart.
            #expect(
                owningSections.first == tab.section,
                "\(tab.rawValue).section (\(tab.section.rawValue)) disagrees with the section listing it"
            )
        }
    }

    @Test func sectionOrderCoversAllTabsWithoutDuplicates() {
        let flattened = ManagementSection.allCases.flatMap(\.tabs)
        #expect(flattened.count == Set(flattened).count, "sections must not repeat a tab")
        #expect(
            Set(flattened) == Set(ManagementTab.allCases),
            "flattened sections must cover every ManagementTab case"
        )
        // `visibleCases` is the canonical sidebar order and must be that
        // same flattening.
        #expect(ManagementTab.visibleCases == flattened)
    }

    @Test func generalSectionLeadsAndAccountTrails() {
        // The IA contract: General is the first group (landing area) and
        // Account is the last. Guards accidental reordering of allCases.
        #expect(ManagementSection.allCases.first == .general)
        #expect(ManagementSection.allCases.last == .account)
        #expect(ManagementTab.visibleCases.first == .settings)
    }

    // MARK: - Legacy raw-value resolution

    @Test func resolvedMapsLegacyRawValues() {
        #expect(ManagementTab.resolved(from: "dashboard") == .credits)
        #expect(ManagementTab.resolved(from: "channels") == .agentChannels)
        #expect(ManagementTab.resolved(from: "integrations") == .agentChannels)
        #expect(ManagementTab.resolved(from: "agent-channels") == .agentChannels)
    }

    @Test func resolvedRoundTripsCurrentRawValues() {
        for tab in ManagementTab.allCases {
            #expect(ManagementTab.resolved(from: tab.rawValue) == tab)
        }
        #expect(ManagementTab.resolved(from: "not-a-tab") == nil)
    }

    @Test func settingsTabIsLabeledGeneral() {
        // The tab formerly labeled "Settings" (inside the settings window)
        // now reads "General"; its raw value stays stable for deep links.
        #expect(ManagementTab.settings.rawValue == "settings")
        #expect(ManagementTab.settings.label == "General")
    }
}
