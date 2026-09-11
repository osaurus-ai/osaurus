//
//  ModelPickerGroupTests.swift
//  osaurusTests
//
//  Covers the sidebar grouping used by the two-pane model picker: Favorites
//  first, then "On this Mac" (Foundation first, then on-device models sorted
//  by name), Osaurus Cloud pinned, one group per configured provider in
//  descriptor order (including disconnected providers with no models), any
//  undeclared provider in first-appearance order, and Claude Code last.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ModelPickerGroupTests {

    private func localModel(id: String, name: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: name, source: .local)
    }

    /// Groups without the always-present Favorites group, for assertions
    /// about source ordering.
    private func sourceGroups(_ groups: [ModelPickerGroup]) -> [ModelPickerGroup] {
        groups.filter { !$0.isFavorites }
    }

    // MARK: - On this Mac composition

    @Test func localGroup_putsFoundationFirstThenLocalsSortedByName() {
        let items: [ModelPickerItem] = [
            localModel(id: "mlx/zeta", name: "Zeta"),
            localModel(id: "mlx/alpha", name: "Alpha"),
            .foundation(),
            localModel(id: "mlx/mid", name: "Mid"),
        ]

        let groups = items.groupedIntoPickerGroups()
        #expect(groups.map(\.key) == [ModelPickerGroup.favoritesKey, ModelPickerGroup.localKey])

        let local = groups[1]
        #expect(local.isLocal)
        #expect(local.title == "On this Mac")
        #expect(local.icon == "desktopcomputer")
        #expect(local.models.map(\.id) == ["foundation", "mlx/alpha", "mlx/mid", "mlx/zeta"])
    }

    @Test func localGroup_omittedWhenNoLocalOrFoundationModels() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: providerId)
        ]

        let groups = sourceGroups(items.groupedIntoPickerGroups())
        #expect(groups.count == 1)
        #expect(groups[0].key == "remote-\(providerId.uuidString)")
        #expect(groups[0].providerId == providerId)
        #expect(groups[0].isProviderBacked)
        // Undeclared providers that have models are treated as connected.
        #expect(groups[0].status == .connected)
    }

    // MARK: - Provider group ordering

    @Test func providerGroups_followFirstAppearanceOrder_afterLocal_whenUndeclared() {
        let openAIId = UUID()
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .foundation(),
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
            .fromRemoteModel(modelId: "anthropic/claude-haiku-4.5", providerName: "Anthropic", providerId: anthropicId),
        ]

        let groups = sourceGroups(items.groupedIntoPickerGroups())
        #expect(groups.map(\.title) == ["On this Mac", "Anthropic", "OpenAI"])
        #expect(groups[0].key == "local")
        #expect(groups[1].key == "remote-\(anthropicId.uuidString)")
        #expect(groups[2].key == "remote-\(openAIId.uuidString)")
    }

    @Test func providerGroups_followDescriptorOrder_whenDeclared() {
        let openAIId = UUID()
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
        ]
        let descriptors = [
            ModelPickerProviderDescriptor(id: openAIId, name: "OpenAI", status: .connected, icon: "sparkles"),
            ModelPickerProviderDescriptor(id: anthropicId, name: "Anthropic", status: .connected),
        ]

        let groups = sourceGroups(items.groupedIntoPickerGroups(providers: descriptors))
        #expect(groups.map(\.title) == ["OpenAI", "Anthropic"])
        #expect(groups[0].icon == "sparkles")
        // Descriptor without an icon falls back to the generic cloud glyph.
        #expect(groups[1].icon == "cloud")
    }

    @Test func providerGroups_pinOsaurusCloudAfterLocal_preservingOtherProviderOrder() {
        let openAIId = UUID()
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let anthropicId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: openAIId),
            .fromRemoteModel(modelId: "anthropic/claude-opus-4", providerName: "Anthropic", providerId: anthropicId),
            .foundation(),
            .fromRemoteModel(modelId: "osaurus/llama-3.3", providerName: "Osaurus", providerId: osaurusId),
        ]

        let groups = sourceGroups(items.groupedIntoPickerGroups())
        #expect(groups.map(\.title) == ["On this Mac", "Osaurus Cloud", "OpenAI", "Anthropic"])
        #expect(groups[1].isOsaurusCloud)
        #expect(groups[1].icon == "cloud.fill")
    }

    @Test func providerGroup_modelsSortedByDisplayName() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "x/grok-4.3", providerName: "xAI", providerId: providerId),
            .fromRemoteModel(modelId: "x/grok-2", providerName: "xAI", providerId: providerId),
            .fromRemoteModel(modelId: "x/grok-3", providerName: "xAI", providerId: providerId),
        ]

        let groups = sourceGroups(items.groupedIntoPickerGroups())
        #expect(groups.count == 1)
        #expect(groups[0].models.map(\.displayName) == ["grok-2", "grok-3", "grok-4.3"])
    }

    // MARK: - Disconnected providers

    /// A configured provider with no models must still get a sidebar group so
    /// the user can see it and reconnect — hiding it read as "provider gone".
    @Test func declaredProviderWithoutModels_stillGetsGroup_withStatus() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [.foundation()]
        let descriptors = [
            ModelPickerProviderDescriptor(
                id: providerId,
                name: "Groq",
                status: .disconnected(message: "401 Unauthorized")
            )
        ]

        let groups = items.groupedIntoPickerGroups(providers: descriptors)
        let groq = groups.first { $0.key == ModelPickerGroup.key(forProviderId: providerId) }
        #expect(groq != nil)
        #expect(groq?.models.isEmpty == true)
        #expect(groq?.status == .disconnected(message: "401 Unauthorized"))
        #expect(groq?.status.isConnected == false)
    }

    @Test func declaredProviderNeedingSignIn_reportsStatus() {
        let providerId = UUID()
        let descriptors = [
            ModelPickerProviderDescriptor(id: providerId, name: "Codex", status: .needsSignIn)
        ]
        let groups = [ModelPickerItem.foundation()].groupedIntoPickerGroups(providers: descriptors)
        let codex = groups.first { $0.providerId == providerId }
        #expect(codex?.status == .needsSignIn)
    }

    @Test func osaurusCloudGroup_appearsFromDescriptorEvenWithoutModels() {
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let descriptors = [
            ModelPickerProviderDescriptor(id: osaurusId, name: "Osaurus", status: .connecting)
        ]
        let groups = [ModelPickerItem.foundation()].groupedIntoPickerGroups(providers: descriptors)
        let cloud = groups.first { $0.isOsaurusCloud }
        #expect(cloud != nil)
        #expect(cloud?.status == .connecting)
        #expect(cloud?.models.isEmpty == true)
    }

    // MARK: - Favorites

    @Test func favoritesGroup_isFirst_mirrorsDisplayOrder_andDedupes() {
        let providerId = UUID()
        let local = localModel(id: "mlx/alpha", name: "Alpha")
        let remote = ModelPickerItem.fromRemoteModel(
            modelId: "openai/gpt-4o",
            providerName: "OpenAI",
            providerId: providerId
        )
        let items: [ModelPickerItem] = [remote, local, .foundation()]

        let favoriteKeys: Set<String> = [remote.favoriteKey, local.favoriteKey, local.favoriteKey]
        let groups = items.groupedIntoPickerGroups(favoriteKeys: favoriteKeys)

        #expect(groups.first?.isFavorites == true)
        #expect(groups.first?.key == ModelPickerGroup.favoritesKey)
        // Local group renders before the provider group, so Alpha comes first.
        #expect(groups.first?.models.map(\.id) == ["mlx/alpha", "openai/gpt-4o"])
    }

    @Test func favoritesGroup_presentButEmpty_whenNothingFavorited() {
        let groups = [ModelPickerItem.foundation()].groupedIntoPickerGroups()
        #expect(groups.first?.isFavorites == true)
        #expect(groups.first?.models.isEmpty == true)
    }

    @Test func favoritesGroup_ignoresKeysForModelsNotPresent() {
        let staleKey = FavoriteModelsStore.key(sourceKey: "local", modelId: "mlx/removed")
        let groups = [ModelPickerItem.foundation()].groupedIntoPickerGroups(favoriteKeys: [staleKey])
        #expect(groups.first?.models.isEmpty == true)
    }

    // MARK: - Duplicate model IDs across providers

    @Test func sameModelIdOnTwoProviders_staysInBothGroups_withDistinctRowIds() {
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

        let groups = sourceGroups(items.groupedIntoPickerGroups())
        #expect(groups.count == 2)
        #expect(groups[0].models.count == 1)
        #expect(groups[1].models.count == 1)

        // Row IDs embed the source key, so unified search results keep the
        // two listings distinguishable for the diffable data source.
        let rowIds = groups.flatMap { group in
            group.models.map { model in
                ModelPickerRow(
                    modelId: model.id,
                    sourceKey: model.source.uniqueKey,
                    displayName: model.displayName,
                    description: model.description,
                    parameterCount: model.parameterCount,
                    quantization: model.quantization,
                    isVLM: model.isVLM,
                    providerLabel: group.title
                ).id
            }
        }
        #expect(Set(rowIds).count == 2)
    }

    // MARK: - Header / options rows

    @Test func headerAndOptionsRows_haveDistinctIds_andAreNotNavigable() {
        let header = ModelPickerRow.header(title: "OpenAI", key: "remote-x")
        let options = ModelPickerRow.options(forModelId: "openai/gpt-4o", sourceKey: "remote-x")
        let model = ModelPickerRow(
            modelId: "openai/gpt-4o",
            sourceKey: "remote-x",
            displayName: "gpt-4o",
            description: nil,
            parameterCount: nil,
            quantization: nil,
            isVLM: false
        )

        #expect(header.id != options.id)
        #expect(options.id != model.id)
        #expect(header.isNavigable == false)
        #expect(options.isNavigable == false)
        #expect(model.isNavigable)
        #expect(model.isModel)
        #expect(options.isOptions)
    }

    // MARK: - Edge cases

    @Test func emptyOptions_yieldNoGroups() {
        let items: [ModelPickerItem] = []
        #expect(items.groupedIntoPickerGroups().isEmpty)
    }

    @Test func emptyUndeclaredGroups_areOmitted() {
        // Only foundation: Favorites + On this Mac, no remote groups.
        let items: [ModelPickerItem] = [.foundation()]
        let groups = items.groupedIntoPickerGroups()
        #expect(groups.map(\.key) == [ModelPickerGroup.favoritesKey, ModelPickerGroup.localKey])
        #expect(groups[1].models.map(\.id) == ["foundation"])
    }

    @Test func claudeCodeGroup_comesLast() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .claudeCode(ClaudeCodeModel.allCases[0]),
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: providerId),
            .foundation(),
        ]
        let groups = sourceGroups(items.groupedIntoPickerGroups())
        #expect(groups.map(\.key) == ["local", "remote-\(providerId.uuidString)", "claude-code"])
        #expect(groups.last?.isClaudeCode == true)
        #expect(groups.last?.icon == "terminal.fill")
    }

    // MARK: - Committed group key resolution

    /// Regression: the model lists refresh asynchronously while the picker is
    /// open, so a group can briefly vanish mid-refresh. An explicit user
    /// selection must survive that transient absence — previously the "Local"
    /// tab snapped back to "Osaurus" when Local momentarily disappeared.
    @Test func resolveCommittedGroupKey_keepsExplicitSelectionWhenGroupTransientlyMissing() {
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let osaurusModel = ModelPickerItem(
            id: "osaurus/llama-3.3",
            displayName: "llama-3.3",
            source: .remote(providerName: "Osaurus", providerId: osaurusId)
        )
        // Mid-refresh snapshot: local discovery briefly returned nothing, so
        // only the Osaurus group is present.
        let groupsWithoutLocal = [osaurusModel].groupedIntoPickerGroups()
        #expect(groupsWithoutLocal.contains { $0.key == "local" } == false)

        let resolved = ModelPickerView.resolveCommittedGroupKey(
            current: "local",
            groups: groupsWithoutLocal,
            selectedModel: osaurusModel.id
        )
        #expect(resolved == "local")
    }

    @Test func resolveCommittedGroupKey_derivesDefaultFromSelectedModelWhenUnset() {
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let local = localModel(id: "mlx/local-a", name: "Local A")
        let osaurus = ModelPickerItem(
            id: "osaurus/llama-3.3",
            displayName: "llama-3.3",
            source: .remote(providerName: "Osaurus", providerId: osaurusId)
        )
        let groups = [local, osaurus].groupedIntoPickerGroups()

        // No committed key -> open on the group holding the current model.
        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: groups,
                selectedModel: osaurus.id
            ) == "remote-\(osaurusId.uuidString)"
        )
        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: groups,
                selectedModel: local.id
            ) == "local"
        )
        // Unknown / nil model -> first source group (never the empty
        // Favorites group); no groups at all -> nothing to commit.
        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: groups,
                selectedModel: nil
            ) == "local"
        )
        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: [],
                selectedModel: nil
            ) == nil
        )
    }

    /// A favorited model lives in both Favorites and its source group; the
    /// picker opens on the source group so the sidebar shows where it is.
    @Test func resolveCommittedGroupKey_prefersSourceGroupOverFavorites() {
        let local = localModel(id: "mlx/local-a", name: "Local A")
        let groups = [local].groupedIntoPickerGroups(favoriteKeys: [local.favoriteKey])
        #expect(groups.first?.models.map(\.id) == ["mlx/local-a"])
        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: groups,
                selectedModel: local.id
            ) == "local"
        )
    }

    /// The host passes `initialGroupKey` after adding a provider from the
    /// picker so it lands on the new provider instead of the selected model.
    @Test func resolveCommittedGroupKey_honorsInitialGroupKeyWhenPresent() {
        let providerId = UUID()
        let local = localModel(id: "mlx/local-a", name: "Local A")
        let descriptors = [ModelPickerProviderDescriptor(id: providerId, name: "Groq", status: .connecting)]
        let groups = [local].groupedIntoPickerGroups(providers: descriptors)
        let groqKey = ModelPickerGroup.key(forProviderId: providerId)

        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: groups,
                selectedModel: local.id,
                initialGroupKey: groqKey
            ) == groqKey
        )
        // Unknown initial key is ignored.
        #expect(
            ModelPickerView.resolveCommittedGroupKey(
                current: nil,
                groups: groups,
                selectedModel: local.id,
                initialGroupKey: "remote-nope"
            ) == "local"
        )
    }

    // MARK: - Filters

    private func externalModel(id: String, name: String, source: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: name, source: .local, externalSource: source)
    }

    @Test func localSourceFilter_narrowsToOsaurusOrOneExternalSource() {
        let items: [ModelPickerItem] = [
            .foundation(),
            localModel(id: "mlx/alpha", name: "Alpha"),
            externalModel(id: "lm/beta", name: "Beta", source: "LM Studio"),
            externalModel(id: "hf/gamma", name: "Gamma", source: "Hugging Face cache"),
        ]

        #expect(items.filteredByLocalSource(.any).map(\.id) == items.map(\.id))
        // Osaurus keeps everything without an external provenance, Foundation included.
        #expect(items.filteredByLocalSource(.osaurus).map(\.id) == ["foundation", "mlx/alpha"])
        #expect(items.filteredByLocalSource(.external("LM Studio")).map(\.id) == ["lm/beta"])
    }

    @Test func distinctExternalSources_sortedAndEmptyWithoutExternals() {
        let mixed: [ModelPickerItem] = [
            localModel(id: "mlx/alpha", name: "Alpha"),
            externalModel(id: "lm/beta", name: "Beta", source: "LM Studio"),
            externalModel(id: "lm/delta", name: "Delta", source: "LM Studio"),
            externalModel(id: "hf/gamma", name: "Gamma", source: "Hugging Face cache"),
        ]
        #expect(mixed.distinctExternalSources == ["Hugging Face cache", "LM Studio"])
        #expect([localModel(id: "mlx/alpha", name: "Alpha")].distinctExternalSources.isEmpty)
    }

    @Test func toolsFilter_keepsOnlyModelsThatDeclareToolCalling() {
        let providerId = UUID()
        let tools = ModelPickerItem(
            id: "a/tools",
            displayName: "tools",
            source: .remote(providerName: "P", providerId: providerId),
            supportsToolCalling: true
        )
        let noTools = ModelPickerItem(
            id: "a/no-tools",
            displayName: "no-tools",
            source: .remote(providerName: "P", providerId: providerId),
            supportsToolCalling: false
        )
        let unknown = ModelPickerItem(
            id: "a/unknown",
            displayName: "unknown",
            source: .remote(providerName: "P", providerId: providerId)
        )
        let items = [tools, noTools, unknown]

        #expect(items.filteredByTools(.any).map(\.id) == items.map(\.id))
        // Unknown capability is not a claim, so it drops out like `false`.
        #expect(items.filteredByTools(.toolsOnly).map(\.id) == ["a/tools"])
    }

    // MARK: - Metadata line

    @Test func metadataLine_joinsUpstreamContextAndPrice_andFallsBackToDescription() {
        let providerId = UUID()
        let full = ModelPickerItem(
            id: "or/model",
            displayName: "model",
            source: .remote(providerName: "OpenRouter", providerId: providerId),
            description: "A long marketing blurb",
            inputPriceMicroPerMTok: 300_000,
            outputPriceMicroPerMTok: 2_500_000,
            contextLength: 131_072,
            upstreamProvider: "Anthropic"
        )
        #expect(full.metadataLine == "Anthropic · 131K ctx · $0.3 / $2.5 per M")
        #expect(full.hasPricing)

        let descriptionOnly = ModelPickerItem(
            id: "x/plain",
            displayName: "plain",
            source: .remote(providerName: "X", providerId: providerId),
            description: "Just a description"
        )
        #expect(descriptionOnly.metadataLine == "Just a description")
        #expect(descriptionOnly.hasPricing == false)

        let free = ModelPickerItem(
            id: "x/free",
            displayName: "free",
            source: .remote(providerName: "X", providerId: providerId),
            inputPriceMicroPerMTok: 0,
            outputPriceMicroPerMTok: 0
        )
        #expect(free.metadataLine == "Free")
    }

    @Test func priceFormatter_trimsZeros_andHandlesOneSidedPricing() {
        #expect(ModelPriceFormatter.line(inputMicroPerMTok: 150_000, outputMicroPerMTok: 600_000) == "$0.15 / $0.6 per M")
        #expect(ModelPriceFormatter.line(inputMicroPerMTok: 15_000_000, outputMicroPerMTok: 75_000_000) == "$15 / $75 per M")
        #expect(ModelPriceFormatter.line(inputMicroPerMTok: 0, outputMicroPerMTok: 0) == "Free")
        #expect(ModelPriceFormatter.line(inputMicroPerMTok: 200_000, outputMicroPerMTok: nil) == "$0.2 in per M")
        #expect(ModelPriceFormatter.line(inputMicroPerMTok: nil, outputMicroPerMTok: nil) == nil)
    }
}
