//
//  ModelPickerTabTests.swift
//  osaurusTests
//
//  Covers the tab grouping used by the model picker's horizontal provider
//  tabs: a single "Local" tab (Foundation first, then on-device models
//  sorted by name) followed by one tab per remote provider in the order
//  providers first appear in the options array.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ModelPickerTabTests {

    private func localModel(id: String, name: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: name, source: .local)
    }

    // MARK: - Local tab composition

    @Test func localTab_putsFoundationFirstThenLocalsSortedByName() {
        let items: [ModelPickerItem] = [
            localModel(id: "mlx/zeta", name: "Zeta"),
            localModel(id: "mlx/alpha", name: "Alpha"),
            .foundation(),
            localModel(id: "mlx/mid", name: "Mid"),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 1)

        let local = tabs[0]
        #expect(local.key == "local")
        #expect(local.title == "Local")
        #expect(local.models.map(\.id) == ["foundation", "mlx/alpha", "mlx/mid", "mlx/zeta"])
    }

    @Test func localTab_omittedWhenNoLocalOrFoundationModels() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: providerId)
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 1)
        #expect(tabs[0].key == "remote-\(providerId.uuidString)")
    }

    // MARK: - Provider tab ordering

    @Test func providerTabs_followFirstAppearanceOrder_afterLocal() {
        let openAIId = UUID()
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .foundation(),
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
            .fromRemoteModel(modelId: "anthropic/claude-haiku-4.5", providerName: "Anthropic", providerId: anthropicId),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.map(\.title) == ["Local", "Anthropic", "OpenAI"])
        #expect(tabs[0].key == "local")
        #expect(tabs[1].key == "remote-\(anthropicId.uuidString)")
        #expect(tabs[2].key == "remote-\(openAIId.uuidString)")
    }

    @Test func providerTabs_pinOsaurusAfterLocal_preservingOtherProviderOrder() {
        let openAIId = UUID()
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .foundation(),
            .fromRemoteModel(modelId: "osaurus/llama-3.3", providerName: "Osaurus", providerId: osaurusId),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.map(\.title) == ["Local", "Osaurus", "OpenAI", "Anthropic"])
    }

    @Test func providerTab_modelsSortedByDisplayName() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "x/grok-4.3", providerName: "xAI", providerId: providerId),
            .fromRemoteModel(modelId: "x/grok-2", providerName: "xAI", providerId: providerId),
            .fromRemoteModel(modelId: "x/grok-3", providerName: "xAI", providerId: providerId),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 1)
        #expect(tabs[0].models.map(\.displayName) == ["grok-2", "grok-3", "grok-4.3"])
    }

    // MARK: - Duplicate model IDs across providers

    @Test func sameModelIdOnTwoProviders_staysInBothTabs_withDistinctRowIds() {
        let providerA = UUID()
        let providerB = UUID()
        let items: [ModelPickerItem] = [
            ModelPickerItem(
                id: "llama-3.1-70b",
                displayName: "llama-3.1-70b",
                source: .remote(providerName: "Groq", providerId: providerA)
            ),
            ModelPickerItem(
                id: "llama-3.1-70b",
                displayName: "llama-3.1-70b",
                source: .remote(providerName: "Together", providerId: providerB)
            ),
        ]

        let tabs = items.groupedByTab()
        #expect(tabs.count == 2)
        #expect(tabs[0].models.count == 1)
        #expect(tabs[1].models.count == 1)

        // Row IDs embed the source key, so unified search results keep the
        // two listings distinguishable for the diffable data source.
        let rowIds = tabs.flatMap { tab in
            tab.models.map { model in
                ModelPickerRow(
                    modelId: model.id,
                    sourceKey: model.source.uniqueKey,
                    displayName: model.displayName,
                    description: model.description,
                    parameterCount: model.parameterCount,
                    quantization: model.quantization,
                    isVLM: model.isVLM,
                    providerLabel: tab.title
                ).id
            }
        }
        #expect(Set(rowIds).count == 2)
    }

    // MARK: - Edge cases

    @Test func emptyOptions_yieldNoTabs() {
        let items: [ModelPickerItem] = []
        #expect(items.groupedByTab().isEmpty)
    }

    @Test func emptyTabs_areOmitted() {
        // Only foundation: a single Local tab, no remote tabs.
        let items: [ModelPickerItem] = [.foundation()]
        let tabs = items.groupedByTab()
        #expect(tabs.map(\.key) == ["local"])
        #expect(tabs[0].models.map(\.id) == ["foundation"])
    }

    // MARK: - Committed tab key resolution

    /// Regression: the model lists refresh asynchronously while the picker is
    /// open, so a tab can briefly vanish mid-refresh. An explicit user
    /// selection must survive that transient absence — previously the "Local"
    /// tab snapped back to "Osaurus" when Local momentarily disappeared.
    @Test func resolveCommittedTabKey_keepsExplicitSelectionWhenTabTransientlyMissing() {
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let osaurusModel = ModelPickerItem(
            id: "osaurus/llama-3.3",
            displayName: "llama-3.3",
            source: .remote(providerName: "Osaurus", providerId: osaurusId)
        )
        // Mid-refresh snapshot: local discovery briefly returned nothing, so
        // only the Osaurus tab is present.
        let tabsWithoutLocal = [osaurusModel].groupedByTab()
        #expect(tabsWithoutLocal.contains { $0.key == "local" } == false)

        let resolved = ModelPickerView.resolveCommittedTabKey(
            current: "local",
            tabs: tabsWithoutLocal,
            selectedModel: osaurusModel.id
        )
        #expect(resolved == "local")
    }

    @Test func resolveCommittedTabKey_derivesDefaultFromSelectedModelWhenUnset() {
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let local = localModel(id: "mlx/local-a", name: "Local A")
        let osaurus = ModelPickerItem(
            id: "osaurus/llama-3.3",
            displayName: "llama-3.3",
            source: .remote(providerName: "Osaurus", providerId: osaurusId)
        )
        let tabs = [local, osaurus].groupedByTab()

        // No committed key -> open on the tab holding the current model.
        #expect(
            ModelPickerView.resolveCommittedTabKey(
                current: nil,
                tabs: tabs,
                selectedModel: osaurus.id
            ) == "remote-\(osaurusId.uuidString)"
        )
        #expect(
            ModelPickerView.resolveCommittedTabKey(
                current: nil,
                tabs: tabs,
                selectedModel: local.id
            ) == "local"
        )
        // Unknown / nil model -> first tab; no tabs at all -> nothing to commit.
        #expect(
            ModelPickerView.resolveCommittedTabKey(
                current: nil,
                tabs: tabs,
                selectedModel: nil
            ) == "local"
        )
        #expect(
            ModelPickerView.resolveCommittedTabKey(
                current: nil,
                tabs: [],
                selectedModel: nil
            ) == nil
        )
    }
}
