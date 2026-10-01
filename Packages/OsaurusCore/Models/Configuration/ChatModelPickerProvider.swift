//
//  ChatModelPickerProvider.swift
//  osaurus
//
//  Provider-column projection for the chat picker. Input is the real picker
//  cache (already scoped to available connections), never a provider catalog.
//

import Foundation

@MainActor
struct ChatModelPickerProvider: Identifiable, Equatable {
    enum Kind: Equatable {
        case local
        case osaurusCloud
        case connected
    }

    let id: String
    let title: String
    let kind: Kind
    /// Selectable models for this provider. Cloud may be narrowed by an
    /// explicit shortlist; an empty shortlist must not silently show all.
    let models: [ModelPickerItem]
    /// All currently available models, including Cloud models outside the
    /// shortlist. Lets Explore use the same live data without inventing rows.
    let availableModels: [ModelPickerItem]

    var isActive: Bool { !models.isEmpty }
    var isLocal: Bool { kind == .local }
    var isOsaurusCloud: Bool { kind == .osaurusCloud }

    /// Pure grouping: does not connect providers, select models, or persist
    /// anything. A nil Cloud shortlist preserves the existing full catalog;
    /// a non-nil set contains exact, provider-prefixed picker model IDs.
    static func groups(
        from items: [ModelPickerItem],
        cloudModelIDs: Set<String>? = nil
    ) -> [ChatModelPickerProvider] {
        let cloudID = RemoteProviderManager.osaurusRouterProviderId
        var foundation: [ModelPickerItem] = []
        var local: [ModelPickerItem] = []
        var cloud: [ModelPickerItem] = []
        var connectedModels: [String: [ModelPickerItem]] = [:]
        var connectedOrder: [(id: String, title: String)] = []

        for item in items {
            guard item.isMLXFormat, !item.isAppleScriptCatalogModel else { continue }
            switch item.source {
            case .foundation:
                foundation.append(item)
            case .local:
                // The live cache already excludes encoders; retain that
                // admission rule if another chat host supplies its own items.
                guard !item.isEmbedding else { continue }
                local.append(item)
            case .imageGeneration:
                guard item.imageReady else { continue }
                local.append(item)
            case .remote(_, let providerID) where providerID == cloudID:
                cloud.append(item)
            case .claudeCode, .remote:
                // Claude Code is network-backed, so it keeps its own provider
                // row. Provider UUIDs keep same-named connections distinct.
                let key = item.source.uniqueKey
                if connectedModels[key] == nil {
                    connectedOrder.append((key, item.source.displayName))
                }
                connectedModels[key, default: []].append(item)
            }
        }

        let localModels = foundation + sorted(local)
        let cloudCatalog = sorted(cloud)
        let cloudModels = cloudCatalog.filter { cloudModelIDs?.contains($0.id) ?? true }
        let localProvider = ChatModelPickerProvider(
            id: "local",
            title: "Local",
            kind: .local,
            models: localModels,
            availableModels: localModels
        )
        let cloudProvider = ChatModelPickerProvider(
            id: "remote-\(cloudID.uuidString)",
            title: "Osaurus Cloud",
            kind: .osaurusCloud,
            models: cloudModels,
            availableModels: cloudCatalog
        )
        let connected = connectedOrder.map { entry in
            let models = sorted(connectedModels[entry.id] ?? [])
            return ChatModelPickerProvider(
                id: entry.id,
                title: entry.title,
                kind: .connected,
                models: models,
                availableModels: models
            )
        }
        return ordered(local: localProvider, cloud: cloudProvider, connected: connected)
    }

    /// Keep placement policy separate from membership, so changing where an
    /// inactive discovery entry sits cannot alter which models are selectable.
    private static func ordered(
        local: ChatModelPickerProvider,
        cloud: ChatModelPickerProvider,
        connected: [ChatModelPickerProvider]
    ) -> [ChatModelPickerProvider] {
        let builtIns = [local, cloud]
        return builtIns.filter(\.isActive) + connected + builtIns.filter { !$0.isActive }
    }

    private static func sorted(_ models: [ModelPickerItem]) -> [ModelPickerItem] {
        models.sorted {
            if $0.displayName == $1.displayName { return $0.id < $1.id }
            return $0.displayName < $1.displayName
        }
    }
}
