//
//  InsightsScopeTests.swift
//  osaurusTests
//
//  Guards the view-only scope grouping and the filter-token derivation the
//  Insights toolbar renders. Scopes must round-trip to `ActivityFilter`
//  category sets, every category must belong to exactly one scope, and a
//  token's `remove` must reset only the field it came from.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Insights scopes and filter tokens")
struct InsightsScopeTests {

    @Test("Every category belongs to exactly one non-All scope")
    func categoriesPartitionIntoScopes() {
        for category in ActivityCategory.allCases {
            let owners = InsightsScope.allCases.filter { $0 != .all && $0.categories.contains(category) }
            #expect(owners.count == 1, "\(category) owned by \(owners)")
            #expect(InsightsScope.scope(containing: category) == owners.first)
        }
    }

    @Test("scope(for:) round-trips every scope and rejects ad-hoc sets")
    func scopeRoundTrip() {
        for scope in InsightsScope.allCases {
            #expect(InsightsScope.scope(for: scope.categories) == scope)
        }
        #expect(InsightsScope.scope(for: []) == .all)
        #expect(InsightsScope.scope(for: [.inference]) == nil)
        #expect(InsightsScope.scope(for: [.inference, .webSearch]) == nil)
    }

    @Test("Empty filter yields no tokens")
    func emptyFilterNoTokens() {
        #expect(ActivityFilterToken.tokens(for: .empty).isEmpty)
    }

    @Test("One token per active field; scope-shaped categories are not tokenized")
    func tokensPerField() {
        var f = ActivityFilter()
        f.text = "  helper "
        f.dateRange = .last7Days
        f.locality = .remote
        f.categories = InsightsScope.web.categories
        f.sources = [.agent, .httpAPI]
        f.destinationHost = "api.openai.com"
        f.model = "gpt-4o"
        f.agentId = UUID()
        f.status = .error
        f.privacyFilterApplied = true
        f.includePluginLogs = false

        let tokens = ActivityFilterToken.tokens(for: f)
        // text, date, locality, 2 sources, destination, model, agent, status, privacy, plugin logs
        #expect(tokens.count == 11)
        #expect(tokens.first?.kind == .text)
        #expect(tokens.first?.label == "“helper”")
        #expect(tokens.contains { $0.kind == .source(.agent) })
        #expect(tokens.contains { $0.kind == .source(.httpAPI) })
        #expect(!tokens.contains { $0.kind == .categories })
        #expect(Set(tokens.map(\.id)).count == tokens.count)
    }

    @Test("Ad-hoc category set renders as a single categories token")
    func adHocCategoriesToken() {
        var f = ActivityFilter()
        f.categories = [.inference, .webSearch]
        let tokens = ActivityFilterToken.tokens(for: f)
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .categories)
        #expect(tokens.first?.label.contains("Inference") == true)
        #expect(tokens.first?.label.contains("Web search") == true)
    }

    @Test("remove resets only the token's own field")
    func removeIsSurgical() {
        var f = ActivityFilter()
        f.text = "x"
        f.locality = .remote
        f.sources = [.agent, .httpAPI]
        f.status = .error
        f.includePluginLogs = false

        ActivityFilterToken(kind: .source(.agent), label: "").remove(from: &f)
        #expect(f.sources == [.httpAPI])
        #expect(f.text == "x")
        #expect(f.locality == .remote)
        #expect(f.status == .error)

        ActivityFilterToken(kind: .locality, label: "").remove(from: &f)
        #expect(f.locality == nil)
        #expect(f.sources == [.httpAPI])

        ActivityFilterToken(kind: .pluginLogsHidden, label: "").remove(from: &f)
        #expect(f.includePluginLogs)

        ActivityFilterToken(kind: .status, label: "").remove(from: &f)
        ActivityFilterToken(kind: .text, label: "").remove(from: &f)
        ActivityFilterToken(kind: .source(.httpAPI), label: "").remove(from: &f)
        #expect(f.isEmpty)
    }
}
