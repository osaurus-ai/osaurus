//
//  AgentTemplateLibraryTests.swift
//  OsaurusCoreTests
//
//  The Templates page's share discoverability: the filter chips, when they
//  show, the published summary line, and which template a pending Share
//  (from Save as Template's Saved state) opens.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentTemplateLibraryTests {

    private let builtIn = AgentTemplate(name: "Cloud Agent", agent: AgentEntry(name: "Cloud Agent"))
    private let published = AgentTemplate(name: "Inbox Desk", agent: AgentEntry(name: "Inbox Desk"))
    private let draft = AgentTemplate(name: "Scout", agent: AgentEntry(name: "Scout"))

    private var all: [AgentTemplate] { [builtIn, published, draft] }
    private func isBuiltIn(_ t: AgentTemplate) -> Bool { t.id == builtIn.id }
    private func isPublished(_ t: AgentTemplate) -> Bool { t.id == published.id }

    private func names(_ filter: AgentTemplateFilter) -> [String] {
        filter.apply(all, isBuiltIn: isBuiltIn, isPublished: isPublished).map(\.name)
    }

    @Test
    func filter_narrowsByChip() {
        #expect(names(.all) == ["Cloud Agent", "Inbox Desk", "Scout"])
        #expect(names(.published) == ["Inbox Desk"])
        #expect(names(.builtIn) == ["Cloud Agent"])
        #expect(names(.yours) == ["Inbox Desk", "Scout"])
    }

    @Test
    func chips_showOncePublishedOrPastThreshold() {
        #expect(!AgentTemplateFilter.showsChips(templateCount: 3, hasPublished: false))
        #expect(AgentTemplateFilter.showsChips(templateCount: 3, hasPublished: true))
        #expect(!AgentTemplateFilter.showsChips(templateCount: AgentTemplateFilter.chipThreshold, hasPublished: false))
        #expect(AgentTemplateFilter.showsChips(templateCount: AgentTemplateFilter.chipThreshold + 1, hasPublished: false))
    }

    @Test
    func chips_carryLabelsAndHelp() {
        #expect(AgentTemplateFilter.allCases.map(\.label) == ["All", "Published", "Built-in", "Yours"])
        #expect(AgentTemplateFilter.allCases.allSatisfy { !$0.help.isEmpty })
    }

    @Test
    func pendingShare_opensOnlyALibraryTemplate() {
        let target = AgentTemplatesView.pendingShareTarget(draft.id, in: all, isBuiltIn: isBuiltIn)
        #expect(target?.id == draft.id)
        #expect(AgentTemplatesView.pendingShareTarget(builtIn.id, in: all, isBuiltIn: isBuiltIn) == nil)
        #expect(AgentTemplatesView.pendingShareTarget(UUID(), in: all, isBuiltIn: isBuiltIn) == nil)
        #expect(AgentTemplatesView.pendingShareTarget(nil, in: all, isBuiltIn: isBuiltIn) == nil)
    }

    @Test
    func pendingShare_isOneShotState() {
        let state = ManagementStateManager.shared
        defer { state.pendingTemplateShare = nil }
        #expect(state.pendingTemplateShare == nil)
        state.pendingTemplateShare = draft.id
        #expect(state.pendingTemplateShare == draft.id)
    }

    @Test
    func publishedLine_summarizesCountAndInstalls() {
        #expect(PublishedByYouLine.summary(liveCount: 0, installs: 5) == nil)
        #expect(PublishedByYouLine.summary(liveCount: 1, installs: 0) == "1 published")
        #expect(PublishedByYouLine.summary(liveCount: 1, installs: 1) == "1 published · 1 install")
        #expect(PublishedByYouLine.summary(liveCount: 3, installs: 42) == "3 published · 42 installs")
    }

    @Test
    func catalog_coversTheNewControls() {
        for id in [
            "agents.templates.share", "agents.templates.publishedByYou", "agents.templates.filter",
            "agents.templates.shareAfterSave", "agents.templates.publish",
        ] {
            let entry = SettingsSearchIndex.entries.first { $0.id == id }
            #expect(entry?.tab == .agents, "\(id) missing from the catalog")
        }
    }
}
