//
//  ChatHarnessPickerOptionTests.swift
//  osaurusTests
//
//  Harness runtimes as chat-picker columns: one row per Claude Code model
//  alias, one row for a Pi runtime, columns after the model providers, and
//  the selected row tracking the agent's runtime and Claude model.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatHarnessPickerOptionTests {
    private let claude = HarnessRuntime.builtInClaudeCode
    private let pi = HarnessRuntime(name: "Spotlight", kind: .piRPC)

    @Test func claudeCodeListsEachAliasAndPiListsOneRow() {
        let claudeRows = ChatHarnessPickerOption.options(for: claude)
        #expect(claudeRows.map(\.claudeModel) == ["sonnet", "opus", "haiku"])
        #expect(claudeRows.map(\.title) == ["Sonnet", "Opus", "Haiku"])
        #expect(Set(claudeRows.map(\.id)).count == 3)

        let piRows = ChatHarnessPickerOption.options(for: pi)
        #expect(piRows.count == 1)
        #expect(piRows.first?.claudeModel == nil)
        #expect(piRows.first?.id == "harness:\(pi.id.uuidString)")
    }

    @Test func aFullClaudeModelIdGetsItsOwnRowSoItShowsSelected() {
        let rows = ChatHarnessPickerOption.options(for: claude, currentClaudeModel: "claude-opus-4-1")
        #expect(rows.map(\.claudeModel) == ["sonnet", "opus", "haiku", "claude-opus-4-1"])
        let alias = ChatHarnessPickerOption.options(for: claude, currentClaudeModel: "opus")
        #expect(alias.count == 3)
    }

    @Test func selectedIdFollowsRuntimeAndClaudeModel() {
        var config = ClaudeCodeAgentConfig.default
        #expect(ChatHarnessPickerOption.selectedID(runtime: nil, claudeConfig: config) == nil)
        #expect(
            ChatHarnessPickerOption.selectedID(runtime: claude, claudeConfig: config)
                == ChatHarnessPickerOption.id(runtimeId: claude.id, claudeModel: "sonnet"))
        config.model = "haiku"
        #expect(
            ChatHarnessPickerOption.selectedID(runtime: claude, claudeConfig: config)
                == ChatHarnessPickerOption.id(runtimeId: claude.id, claudeModel: "haiku"))
        #expect(
            ChatHarnessPickerOption.selectedID(runtime: pi, claudeConfig: config)
                == ChatHarnessPickerOption.id(runtimeId: pi.id, claudeModel: nil))
    }

    @Test func harnessColumnsFollowModelProvidersAheadOfInactiveEntries() {
        let harnesses = ChatModelPickerProvider.harnessProviders(runtimes: [claude, pi])
        let groups = ChatModelPickerProvider.groups(from: [.foundation()], harnesses: harnesses)
        #expect(groups.map(\.kind) == [.local, .harness(.claudeCode), .harness(.piRPC), .osaurusCloud])
        #expect(groups.map(\.title) == ["Local", "Claude Code", "Spotlight", "Osaurus Cloud"])
        let claudeColumn = groups[1]
        #expect(claudeColumn.isActive && claudeColumn.isHarness)
        #expect(claudeColumn.models.isEmpty, "harness rows never become routable model ids")
        #expect(claudeColumn.rowCount == 3)
    }

    @Test func onlyTheCurrentRuntimeGetsTheExtraModelRow() {
        let harnesses = ChatModelPickerProvider.harnessProviders(
            runtimes: [claude, HarnessRuntime(name: "Work Claude", kind: .claudeCode)],
            current: (runtimeId: claude.id, claudeModel: "claude-sonnet-4-5"))
        #expect(harnesses[0].harnessOptions.count == 4)
        #expect(harnesses[1].harnessOptions.count == 3)
    }

    @Test func initialSizeOpensOnTheSelectedHarnessColumn() {
        let harnesses = ChatModelPickerProvider.harnessProviders(runtimes: [claude])
        let groups = ChatModelPickerProvider.groups(from: [.foundation()], harnesses: harnesses)
        let selected = ChatHarnessPickerOption.id(runtimeId: claude.id, claudeModel: "opus")
        let onHarness = ChatModelPickerCard.initialSize(
            providers: groups, selectedModel: "foundation", optionsControl: nil, selectedHarnessID: selected)
        let onModel = ChatModelPickerCard.initialSize(
            providers: groups, selectedModel: "foundation", optionsControl: nil)
        #expect(onHarness.width > 0 && onHarness.height > 0)
        #expect(onModel.width > 0 && onModel.height > 0)
    }
}
