//
//  AppKeys.swift
//  osaurus
//
//  Keys the app itself uses (model providers, web search, voice,
//  downloads). They stay in their own stores and the Keys page edits them
//  in place.
//

import Foundation

/// A key that lives in its own store and is edited in place.
public struct AppKeyRow: Identifiable, Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case models = "Models"
        case webSearch = "Web Search"
        case voice = "Voice"
        case downloads = "Downloads"
    }

    public enum Store: Hashable, Sendable {
        case remoteProvider(UUID)
        case search(definitionId: String, field: String)
        case tts
        case huggingFace
        case gitHub
    }

    /// The settings page that owns this key, as a `SettingsSearchIndex` id.
    public struct Destination: Equatable, Sendable {
        /// Menu command ("Open Voice Settings").
        public let title: String
        /// Where the key is used ("Voice → Text to Speech").
        public let place: String
        public let settingId: String
    }

    public let store: Store
    public let group: Group
    public let title: String
    public let detail: String
    public let isSet: Bool
    /// One line on what the key is for.
    public var purpose: String? = nil
    public var destination: Destination? = nil

    public var id: String {
        switch store {
        case .remoteProvider(let id): return "remote:\(id.uuidString)"
        case .search(let definitionId, let field): return "search:\(definitionId):\(field)"
        case .tts: return "tts"
        case .huggingFace: return "huggingface"
        case .gitHub: return "github"
        }
    }
}

extension CredentialRegistry {
    struct AppKeyInput: Sendable {
        let store: AppKeyRow.Store
        let group: AppKeyRow.Group
        let title: String
        let detail: String
        var purpose: String? = nil
        var destination: AppKeyRow.Destination? = nil
        /// Listed only when a value is stored, so an unused key can still be removed.
        var onlyWhenSet = false

        func resolve() -> AppKeyRow? {
            let isSet = AppKeys.isSet(store)
            if onlyWhenSet, !isSet { return nil }
            return AppKeyRow(
                store: store, group: group, title: title, detail: detail, isSet: isSet,
                purpose: purpose, destination: destination)
        }
    }

    /// The text-to-speech key is only sent while Voice uses an OpenAI-compatible server.
    nonisolated static func ttsAppKeyInput(_ configuration: TTSConfiguration) -> AppKeyInput {
        let host = URL(string: configuration.remoteEndpoint)?.host(percentEncoded: false)
        return AppKeyInput(
            store: .tts, group: .voice, title: L("Text-to-Speech Server"),
            detail: host.map { L("API key for \($0)") } ?? L("API key"),
            purpose: L("Sent when Voice reads replies aloud through this server."),
            destination: .init(
                title: L("Open Voice Settings"), place: L("Voice → Text to Speech"), settingId: "voice.tts.remote"),
            onlyWhenSet: configuration.provider != .openAICompatible)
    }

    static func liveAppKeyInputs() -> [AppKeyInput] {
        var out: [AppKeyInput] = []
        for provider in RemoteProviderManager.shared.configuration.providers where provider.authType == .apiKey {
            out.append(
                AppKeyInput(
                    store: .remoteProvider(provider.id), group: .models, title: provider.name, detail: "API key"))
        }
        let search = SearchProviderManager.shared
        for provider in search.configuration.providers {
            guard let definition = search.definition(id: provider.definitionId) else { continue }
            for field in definition.secrets ?? [] {
                out.append(
                    AppKeyInput(
                        store: .search(definitionId: definition.id, field: field.id), group: .webSearch,
                        title: definition.name, detail: field.label))
            }
        }
        out.append(ttsAppKeyInput(TTSConfigurationStore.load()))
        out.append(
            AppKeyInput(
                store: .huggingFace, group: .downloads, title: "Hugging Face", detail: L("Access token"),
                purpose: L("Raises model download limits and opens gated models you have access to.")))
        out.append(
            AppKeyInput(
                store: .gitHub, group: .downloads, title: "GitHub", detail: L("API token"),
                purpose: L("Raises GitHub rate limits when importing skills and plugins.")))
        return out
    }
}

/// Reads and writes through each app key's own store.
enum AppKeys {
    nonisolated static func isSet(_ store: AppKeyRow.Store) -> Bool {
        switch store {
        case .remoteProvider(let id): return RemoteProviderKeychain.apiKeyAvailability(for: id) == .present
        case .search(let definitionId, let field):
            return SearchProviderKeychain.getSecret(field: field, for: definitionId)?.isEmpty == false
        case .tts: return TTSRemoteAPIKeyStore.loadSync() != nil
        case .huggingFace: return HuggingFaceAuth.hasToken
        case .gitHub: return GitHubAuth.hasToken
        }
    }

    /// Reads one value for Show / Copy. Call off the main actor.
    nonisolated static func value(_ store: AppKeyRow.Store) -> String? {
        switch store {
        case .remoteProvider(let id): return RemoteProviderKeychain.getAPIKey(for: id)
        case .search(let definitionId, let field): return SearchProviderKeychain.getSecret(field: field, for: definitionId)
        case .tts: return TTSRemoteAPIKeyStore.loadSync()
        case .huggingFace: return HuggingFaceAuth.token
        case .gitHub: return GitHubAuth.token
        }
    }

    /// Saves (or removes, when blank) through the owning store, with the
    /// Keychain write off the main actor. False when the write failed.
    @MainActor
    static func save(_ value: String, to store: AppKeyRow.Store) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: Bool
        switch store {
        case .remoteProvider(let id):
            saved = await Task.detached(priority: .userInitiated) {
                trimmed.isEmpty
                    ? RemoteProviderKeychain.deleteAPIKey(for: id) : RemoteProviderKeychain.saveAPIKey(trimmed, for: id)
            }.value
        case .search(let definitionId, let field):
            saved = await Task.detached(priority: .userInitiated) {
                trimmed.isEmpty
                    ? SearchProviderKeychain.deleteSecret(field: field, for: definitionId)
                    : SearchProviderKeychain.saveSecret(trimmed, field: field, for: definitionId)
            }.value
            SearchProviderManager.shared.refreshConfiguredProviderIds()
        case .tts:
            TTSRemoteAPIKeyStore.save(trimmed)
            saved = true
        case .huggingFace:
            HuggingFaceAuth.setToken(trimmed.isEmpty ? nil : trimmed)
            saved = true
        case .gitHub:
            GitHubAuth.setToken(trimmed.isEmpty ? nil : trimmed)
            saved = true
        }
        CredentialRegistry.shared.refresh()
        return saved
    }
}
