//
//  ClaudeCodePickerTests.swift
//  osaurusTests
//
//  Model-picker wiring for the Claude Code backend. Covers the surface a
//  human would otherwise have to launch the app to check: does the tab
//  appear, is it separate from Local, and does selecting a row route back
//  to the right service?
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code model picker")
struct ClaudeCodePickerTests {

    private var claudeCodeItems: [ModelPickerItem] {
        ClaudeCodeModel.allCases.map { ModelPickerItem.claudeCode($0) }
    }

    @Test func everyAliasBecomesAPickerRow() {
        let items = claudeCodeItems
        #expect(items.count == ClaudeCodeModel.allCases.count)
        #expect(items.allSatisfy { $0.source == .claudeCode })
        #expect(Set(items.map(\.id)) == Set(ClaudeCodeModel.allCases.map(\.pickerId)))
        // Every row must be selectable as a chat model, or the picker would
        // render it but refuse to default to it.
        let allChatCapable = items.allSatisfy { $0.isLikelyChatCapable }
        #expect(allChatCapable)
    }

    /// Grouping under "Local" would tell the user the prompt stays on device,
    /// which is false — the CLI is local but inference is not.
    @Test func claudeCodeGetsItsOwnTabSeparateFromLocal() {
        let localModel = ModelPickerItem(
            id: "mlx-community/Qwen3-8B",
            displayName: "Qwen3 8B",
            source: .local
        )
        let tabs = (claudeCodeItems + [localModel]).groupedByTab()

        let localTab = tabs.first { $0.key == "local" }
        #expect(localTab != nil)
        #expect(localTab?.models.count == 1)
        #expect(localTab?.models.first?.id == localModel.id)

        let claudeTab = tabs.first { $0.key == "claude-code" }
        #expect(claudeTab != nil)
        #expect(claudeTab?.title == "Claude Code")
        #expect(claudeTab?.models.count == ClaudeCodeModel.allCases.count)
    }

    /// The picker id is also the routing key, so a row the user clicks has to
    /// resolve back to `ClaudeCodeService` and to nothing else.
    @Test func pickerRowsRouteToTheClaudeCodeService() {
        let service = ClaudeCodeService()
        for item in claudeCodeItems {
            #expect(service.handles(requestedModel: item.id))
        }

        let mlx = MLXService()
        let foundation = FoundationModelService()
        for item in claudeCodeItems {
            #expect(!foundation.handles(requestedModel: item.id))
            #expect(!mlx.handles(requestedModel: item.id))
        }
    }

    /// A row with no source-grouping entry would silently vanish from the
    /// picker rather than fail loudly.
    @Test func sourceMetadataIsComplete() {
        let source = ModelPickerItem.Source.claudeCode
        #expect(!source.displayName.isEmpty)
        #expect(!source.uniqueKey.isEmpty)
        #expect(!source.isImageGeneration)
        // Distinct from every other source's key, or tabs would collide.
        let others: [ModelPickerItem.Source] = [
            .foundation, .local, .imageGeneration,
            .remote(providerName: "x", providerId: UUID()),
        ]
        #expect(others.allSatisfy { $0.uniqueKey != source.uniqueKey })
    }

    @Test func groupedBySourceKeepsClaudeCodeTogether() {
        let groups = claudeCodeItems.groupedBySource()
        #expect(groups.count == 1)
        #expect(groups.first?.source == .claudeCode)
        #expect(groups.first?.models.count == ClaudeCodeModel.allCases.count)
    }
}
