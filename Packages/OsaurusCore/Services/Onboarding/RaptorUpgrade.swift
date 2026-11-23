//
//  RaptorUpgrade.swift
//  osaurus
//
//  Moves agents off a retired Raptor once Raptor 0.7 is on this Mac. The
//  Classic upgrade screen starts the 0.7 download and leaves this pending;
//  nobody is pointed at 0.7 while it downloads, because a chat on a model
//  that is still downloading runs on Osaurus Cloud in the meantime. Each
//  model change after that, and each launch, checks again until 0.7 lands.
//

import Foundation

@MainActor
enum RaptorUpgrade {
    static let pendingKey = "raptorUpgradePending"

    static var targetModelId: String { ConfigureAIState.preferredOnboardingModelId }

    private static var observer: NSObjectProtocol?
    private static var checking = false

    /// Where the stored model ids live: the Orchestrator's own store, the
    /// custom agents, and the seed model for new agents.
    struct Store {
        var orchestratorModel: @MainActor () -> String?
        var setOrchestratorModel: @MainActor (String) -> Void
        /// Custom agents with a model of their own that may change. A locked
        /// model stays.
        var agentModels: @MainActor () -> [(id: UUID, model: String)]
        var setAgentModel: @MainActor (UUID, String) -> Void
        var seedModel: @MainActor () -> String?
        var setSeedModel: @MainActor (String) -> Void

        static var live: Store {
            Store(
                orchestratorModel: { DefaultAgentConfigurationStore.load().defaultModel },
                setOrchestratorModel: { AgentManager.shared.updateDefaultModel(for: Agent.defaultId, model: $0) },
                agentModels: {
                    AgentManager.shared.agents.compactMap { agent in
                        guard !agent.isBuiltIn, agent.modelLocked != true, let model = agent.defaultModel else {
                            return nil
                        }
                        return (agent.id, model)
                    }
                },
                setAgentModel: { AgentManager.shared.updateDefaultModel(for: $0, model: $1) },
                seedModel: { ChatConfigurationStore.load().defaultModel },
                setSeedModel: { model in
                    var config = ChatConfigurationStore.load()
                    config.defaultModel = model
                    ChatConfigurationStore.save(config)
                }
            )
        }
    }

    static func markPending(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }

    static func isPending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingKey)
    }

    /// Whether `modelId` names a retired Raptor, as a full `org/repo` id or
    /// the bare repo name older builds stored.
    nonisolated static func isRetiredRaptor(_ modelId: String) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return false }
        if ModelManager.retiredRaptorIds.contains(id) { return true }
        return !id.contains("/") && ModelManager.retiredRaptorIds.contains { $0.hasSuffix("/" + id) }
    }

    /// Checks once now and again whenever the local models change, while an
    /// upgrade is pending.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .localModelsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { checkIfPending() }
        }
        checkIfPending()
    }

    static func checkIfPending(defaults: UserDefaults = .standard) {
        guard isPending(defaults: defaults), !checking else { return }
        checking = true
        let target = targetModelId
        let root = DirectoryPickerService.effectiveModelsDirectory()
        Task { @MainActor in
            defer { checking = false }
            let downloaded = await Task.detached(priority: .utility) {
                isLoadable(MLXModel(id: target, name: target, description: "", downloadURL: "", rootDirectory: root))
            }.value
            apply(isTargetDownloaded: downloaded, defaults: defaults)
        }
    }

    /// Whether the bundle is complete enough to load. The index and tokenizer
    /// land in the first seconds of a download, so the file check alone
    /// passes mid-download; the in-progress marker stays until every file is
    /// verified, across pauses and relaunches.
    nonisolated static func isLoadable(_ model: MLXModel) -> Bool {
        model.computeIsDownloadedFromDisk() && ModelManifest.loadFailure(at: model.localDirectory) == nil
    }

    /// Moves every stored model on a retired Raptor to Raptor 0.7 once it is
    /// on disk, then clears the pending flag. Returns how many moved; `nil`
    /// when nothing was pending or 0.7 is not here yet.
    @discardableResult
    static func apply(
        isTargetDownloaded: Bool, defaults: UserDefaults = .standard, store: Store = .live
    ) -> Int? {
        guard isPending(defaults: defaults), isTargetDownloaded else { return nil }
        let target = targetModelId
        var moved = 0
        if let model = store.orchestratorModel(), isRetiredRaptor(model) {
            store.setOrchestratorModel(target)
            moved += 1
        }
        for (id, model) in store.agentModels() where isRetiredRaptor(model) {
            store.setAgentModel(id, target)
            moved += 1
        }
        if let model = store.seedModel(), isRetiredRaptor(model) {
            store.setSeedModel(target)
        }
        defaults.removeObject(forKey: pendingKey)
        FeatureTelemetry.raptorUpgradeApplied(agents: moved)
        return moved
    }
}
