//
//  AgentChannelSetupFlowTests.swift
//  osaurus
//
//  Tests for the provider-independent setup flow model: section-rail
//  navigation, initial landing position, and the unified Add Channel catalog.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelSetupFlowTests {

    private let sections = [
        AgentChannelSetupSection(id: "connect", title: "Connect", icon: "link"),
        AgentChannelSetupSection(id: "access", title: "Access", icon: "person.2"),
        AgentChannelSetupSection(id: "behavior", title: "Behavior", icon: "arrow.triangle.branch"),
        AgentChannelSetupSection(id: "verify", title: "Verify", icon: "checkmark.seal"),
    ]

    @Test func navigationWalksSectionsInOrder() {
        #expect(AgentChannelSetupFlow.isFirst("connect", in: sections))
        #expect(!AgentChannelSetupFlow.isFirst("access", in: sections))
        #expect(AgentChannelSetupFlow.isLast("verify", in: sections))
        #expect(!AgentChannelSetupFlow.isLast("behavior", in: sections))

        #expect(AgentChannelSetupFlow.next(after: "connect", in: sections) == "access")
        #expect(AgentChannelSetupFlow.next(after: "verify", in: sections) == nil)
        #expect(AgentChannelSetupFlow.previous(before: "access", in: sections) == "connect")
        #expect(AgentChannelSetupFlow.previous(before: "connect", in: sections) == nil)
    }

    @Test func navigationIsSafeForUnknownIds() {
        #expect(AgentChannelSetupFlow.next(after: "missing", in: sections) == nil)
        #expect(AgentChannelSetupFlow.previous(before: "missing", in: sections) == nil)
        #expect(!AgentChannelSetupFlow.isFirst("missing", in: sections))
        #expect(!AgentChannelSetupFlow.isLast("missing", in: sections))
    }

    @Test func initialSectionIsFirstIncompleteRequiredSection() {
        let landing = AgentChannelSetupFlow.initialSection(
            in: sections,
            required: ["connect", "access"],
            isComplete: { $0 == "connect" },
            fallback: "verify"
        )
        #expect(landing == "access")
    }

    @Test func initialSectionFallsBackWhenEverythingRequiredIsComplete() {
        let landing = AgentChannelSetupFlow.initialSection(
            in: sections,
            required: ["connect", "access"],
            isComplete: { _ in true },
            fallback: "verify"
        )
        #expect(landing == "verify")
    }

    @Test func initialSectionIgnoresOptionalSections() {
        // Behavior is not required, so it must not capture the landing spot
        // even though it is incomplete.
        let landing = AgentChannelSetupFlow.initialSection(
            in: sections,
            required: ["connect", "access"],
            isComplete: { $0 != "behavior" },
            fallback: "verify"
        )
        #expect(landing == "verify")
    }

    @Test func providerSetupSectionsAreTheFourFocusedSections() {
        let ids = AgentChannelProviderSetupSection.sections.map(\.id)
        #expect(ids == ["connect", "access", "behavior", "verify"])
        #expect(AgentChannelProviderSetupSection.requiredSectionIds == ["connect", "access"])
    }

    @Test func providerSetupStagesReadAsUserIntents() {
        // The rail is the setup's table of contents; stages must read as
        // what the user is doing, not as internal configuration areas.
        #expect(AgentChannelProviderSetupSection.connect.title == "Connect")
        #expect(AgentChannelProviderSetupSection.access.title == "Conversations")
        #expect(AgentChannelProviderSetupSection.behavior.title == "Agent Behavior")
        #expect(AgentChannelProviderSetupSection.verify.title == "Test")
    }

    @Test func addCatalogListsGuidedProvidersFirstAndCustomLastAsAdvanced() {
        #expect(AgentChannelAddCatalog.choices == [.discord, .slack, .telegram, .imessage, .customHTTP])
        #expect(AgentChannelAddCatalog.choices.last == .customHTTP)
        #expect(AgentChannelAddCatalog.isAdvanced(.customHTTP))
        for kind in AgentChannelAddCatalog.choices.dropLast() {
            #expect(!AgentChannelAddCatalog.isAdvanced(kind))
        }
    }
}
