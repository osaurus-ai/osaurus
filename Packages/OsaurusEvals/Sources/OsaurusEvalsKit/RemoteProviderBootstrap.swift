//
//  RemoteProviderBootstrap.swift
//  OsaurusEvalsKit
//
//  Ephemeral remote-provider bootstrap for the eval CLI. The CLI is its
//  own process and never runs `RemoteProviderManager.connectEnabledProviders()`
//  (the host app does that in AppDelegate), so a `--model xai/grok-4.3`
//  run would route to `.none` unless a provider is connected in-process.
//
//  Bootstrap contract:
//    - The API key is read from `<PREFIX>_API_KEY` (e.g. `XAI_API_KEY`)
//      and rides ONLY in the ephemeral provider's in-memory
//      `customHeaders` (`authType: .none`). It is never written to
//      `remote.json` (ephemeral providers are memory-only) and never
//      touches the Keychain.
//    - The provider `name` is chosen so its derived routing prefix
//      (`name.lowercased()`) matches the model's provider segment, so
//      `ModelServiceRouter` resolves `xai/<model>` to it naturally.
//    - Providers already connected in-process (or any provider the
//      developer's running config can route) win — bootstrap only fills
//      the gap when nothing handles the requested model.
//

import Foundation
import OsaurusCore

@MainActor
public enum EvalRemoteProviderBootstrap {

    /// Known provider presets keyed by routing prefix. `envKey` names the
    /// environment variable carrying the API key; `providerType` selects
    /// the wire format (OpenAI-compatible vs. native Anthropic Messages);
    /// `headers` builds the in-memory auth headers for the key.
    struct Preset {
        let name: String
        let host: String
        let basePath: String
        let envKey: String
        var providerType: RemoteProviderType = .openaiLegacy
        var headers: (String) -> [String: String] = { ["Authorization": "Bearer \($0)"] }
    }

    static let presets: [String: Preset] = [
        "xai": Preset(name: "xAI", host: "api.x.ai", basePath: "/v1", envKey: "XAI_API_KEY"),
        "openai": Preset(name: "OpenAI", host: "api.openai.com", basePath: "/v1", envKey: "OPENAI_API_KEY"),
        "groq": Preset(name: "Groq", host: "api.groq.com/openai", basePath: "/v1", envKey: "GROQ_API_KEY"),
        "openrouter": Preset(
            name: "OpenRouter",
            host: "openrouter.ai/api",
            basePath: "/v1",
            envKey: "OPENROUTER_API_KEY"
        ),
        // Native Anthropic Messages API: auth rides in `x-api-key` (plus the
        // required version header), mirroring what `resolvedHeaders` builds
        // for a Keychain-backed provider — but kept in-memory only.
        "anthropic": Preset(
            name: "Anthropic",
            host: "api.anthropic.com",
            basePath: "/v1",
            envKey: "ANTHROPIC_API_KEY",
            providerType: .anthropic,
            headers: { ["x-api-key": $0, "anthropic-version": "2023-06-01"] }
        ),
        // Native Gemini GenerateContent API: auth rides in `x-goog-api-key`,
        // matching the app's Google preset (host + /v1beta base path).
        "google": Preset(
            name: "Google",
            host: "generativelanguage.googleapis.com",
            basePath: "/v1beta",
            envKey: "GEMINI_API_KEY",
            providerType: .gemini,
            headers: { ["x-goog-api-key": $0] }
        ),
        "deepseek": Preset(
            name: "DeepSeek",
            host: "api.deepseek.com",
            basePath: "/v1",
            envKey: "DEEPSEEK_API_KEY"
        ),
    ]

    /// Connect ephemeral providers for every remote `provider/name` model
    /// id in `modelIds` that (a) matches a known preset, (b) has its API
    /// key exported, and (c) is not already routable by a connected
    /// service. Returns the installed provider ids for `teardown`.
    @discardableResult
    public static func connectIfNeeded(
        modelIds: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> [UUID] {
        var installed: [UUID] = []
        var handledPrefixes: Set<String> = []

        for modelId in modelIds {
            guard let slash = modelId.firstIndex(of: "/") else { continue }
            let prefix = String(modelId[..<slash]).lowercased()
            guard !handledPrefixes.contains(prefix) else { continue }
            handledPrefixes.insert(prefix)

            // Already routable (developer has the provider configured +
            // connected in this process)? Leave their setup alone.
            if RemoteProviderManager.shared.findService(forModel: modelId) != nil {
                continue
            }
            guard let preset = presets[prefix] else { continue }
            guard let apiKey = environment[preset.envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !apiKey.isEmpty
            else { continue }

            // `authType: .none` + Authorization in customHeaders keeps the
            // key out of the Keychain entirely; `isEphemeral: true` keeps
            // the provider record out of `remote.json`.
            let provider = RemoteProvider(
                id: UUID(),
                name: preset.name,
                host: preset.host,
                providerProtocol: .https,
                port: nil,
                basePath: preset.basePath,
                customHeaders: preset.headers(apiKey),
                authType: .none,
                providerType: preset.providerType,
                enabled: true,
                autoConnect: false,
                timeout: 300
            )
            RemoteProviderManager.shared.addProvider(provider, apiKey: nil, isEphemeral: true)
            do {
                try await RemoteProviderManager.shared.connect(providerId: provider.id)
                let models =
                    RemoteProviderManager.shared.providerStates[provider.id]?.discoveredModels ?? []
                print(
                    "[evals] connected ephemeral provider '\(preset.name)' "
                        + "(\(models.count) models) for prefix '\(prefix)/'"
                )
                installed.append(provider.id)
            } catch {
                print(
                    "[evals] failed to connect ephemeral provider '\(preset.name)': "
                        + "\(error.localizedDescription)"
                )
                RemoteProviderManager.shared.removeProvider(id: provider.id)
            }
        }
        return installed
    }

    /// Tear down providers installed by `connectIfNeeded`. Ephemeral
    /// providers are memory-only, so this just disconnects and drops
    /// the in-process state.
    public static func teardown(_ ids: [UUID]) {
        for id in ids {
            RemoteProviderManager.shared.removeProvider(id: id)
        }
    }

    /// Candidate model ids for bootstrap: the run model plus the resolved
    /// judge model — both route through `CoreModelService`. The judge is
    /// resolved via `EvalJudgeModel`, so an auto-selected strong judge
    /// (e.g. `xai/grok-4.3` from `XAI_API_KEY` when `JUDGE_MODEL` is unset)
    /// also gets its provider connected, not just an explicit `JUDGE_MODEL`.
    public static func candidateModelIds(
        runModel: ModelSelection,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var ids: [String] = []
        var runModelId: String?
        if case .explicit(let provider, let name) = runModel, let provider, !provider.isEmpty {
            runModelId = "\(provider)/\(name)"
            ids.append(runModelId!)
        }
        let judge = EvalJudgeModel.resolve(runModelId: runModelId, environment: environment)
        if let judgeId = judge.modelId, judgeId.contains("/") {
            ids.append(judgeId)
        }
        return ids
    }
}
