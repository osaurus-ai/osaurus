//
//  ConfigModelReference.swift
//  osaurus
//
//  Resolves a `model:` value from a declarative config document into the
//  canonical id the chat runtime expects. The runtime contract (same as the
//  model picker) is:
//    - "foundation"                  Apple's on-device model
//    - "<repo>/<bundle>"             an installed local MLX bundle id
//    - "<provider-prefix>/<model>"   a cloud model, where the prefix is the
//                                    provider name lowercased with spaces
//                                    replaced by dashes (RemoteProviderManager
//                                    .pickerPrefix)
//
//  A bare cloud id (e.g. "claude-x" instead of "anthropic/claude-x") is
//  stored verbatim by the managers but never routes to a provider, so the
//  agent silently loses its model. This resolver rejects ids it cannot
//  ground and auto-prefixes bare cloud ids when exactly one connected
//  provider offers them.
//

import Foundation

enum ConfigModelReference {

    enum Resolution: Equatable {
        /// The canonical id to persist.
        case resolved(String)
        /// Human-readable reason plus fix guidance.
        case invalid(String)
    }

    struct ProviderModels {
        /// Picker prefix, e.g. "anthropic" for provider "Anthropic".
        let prefix: String
        /// Display name, for error messages.
        let name: String
        /// Bare model ids the provider currently advertises.
        let models: [String]

        init(prefix: String, name: String, models: [String]) {
            self.prefix = prefix
            self.name = name
            self.models = models
        }
    }

    struct Catalog {
        /// Installed local bundle ids.
        let localModelIds: [String]
        let providers: [ProviderModels]

        init(localModelIds: [String], providers: [ProviderModels]) {
            self.localModelIds = localModelIds
            self.providers = providers
        }
    }

    /// Snapshot the current local bundles and cloud provider catalogs.
    /// Includes disconnected providers so an explicitly prefixed id keeps
    /// working while a provider is temporarily offline.
    @MainActor
    static func liveCatalog() -> Catalog {
        let locals = ModelManager.shared.availableModels
            .filter { $0.isDownloaded }
            .map { $0.id }
        let manager = RemoteProviderManager.shared
        let providers = manager.configuration.providers.map { provider in
            ProviderModels(
                prefix: RemoteProviderManager.pickerPrefix(for: provider.name),
                name: provider.name,
                models: manager.providerStates[provider.id]?.discoveredModels ?? []
            )
        }
        return Catalog(localModelIds: locals, providers: providers)
    }

    /// Resolve `raw` against `catalog`. `pendingLocalIds` are local model ids
    /// the same document downloads via `models:`, accepted even though they
    /// are not installed yet.
    static func resolve(
        _ raw: String,
        catalog: Catalog,
        pendingLocalIds: [String] = []
    ) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .resolved(trimmed) }

        if trimmed.lowercased() == "foundation" { return .resolved("foundation") }

        if let local = catalog.localModelIds.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .resolved(local)
        }
        if let pending = pendingLocalIds.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .resolved(pending)
        }

        // Provider-prefixed form. Trust an explicit, existing prefix even
        // when the model is not in the discovered list: the provider may be
        // disconnected or its catalog stale, and rejecting would strand a
        // valid document.
        if let slash = trimmed.firstIndex(of: "/") {
            let prefix = String(trimmed[..<slash]).lowercased()
            let rest = String(trimmed[trimmed.index(after: slash)...])
            if let provider = catalog.providers.first(where: { $0.prefix == prefix }) {
                if let bare = provider.models.first(where: {
                    $0.caseInsensitiveCompare(rest) == .orderedSame
                }) {
                    return .resolved("\(provider.prefix)/\(bare)")
                }
                return .resolved("\(provider.prefix)/\(rest)")
            }
        }

        // Bare cloud id: prefix it when exactly one provider offers it.
        // (Also catches ids containing "/" that are not provider prefixes,
        // e.g. Osaurus Router upstream ids.)
        var candidates: [String] = []
        for provider in catalog.providers {
            if let bare = provider.models.first(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                candidates.append("\(provider.prefix)/\(bare)")
            }
        }
        if candidates.count == 1 { return .resolved(candidates[0]) }
        if candidates.count > 1 {
            return .invalid(
                "`\(trimmed)` is offered by multiple providers — use the prefixed form: "
                    + candidates.joined(separator: ", ") + ".")
        }
        return .invalid(
            "`\(trimmed)` is not `foundation`, not an installed local model, and no cloud "
                + "provider offers it. Cloud models need the provider prefix (e.g. "
                + "`anthropic/claude-...`); use osaurus_inspect {action: \"describe\", "
                + "scope: \"providers\", id: \"<name>\"} to see each provider's model ids. "
                + "For a local model that is not installed yet, list it under `models:` "
                + "in the same document to download it.")
    }
}
