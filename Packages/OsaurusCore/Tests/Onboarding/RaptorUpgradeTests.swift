//
//  RaptorUpgradeTests.swift
//  osaurusTests
//
//  The Classic upgrade screen's Raptor 0.7 offer: when its switch shows and
//  what it defaults to, and the move of agents on a retired Raptor to 0.7
//  once the download has landed.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RaptorUpgradeTests {

    // MARK: The switch on the upgrade card

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-raptor-offer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func raptor(root: URL, onDisk: Bool) throws -> MLXModel {
        let model = MLXModel(
            id: ConfigureAIState.preferredOnboardingModelId,
            name: "Raptor 0.7 4B",
            description: "",
            downloadURL: "https://huggingface.co/\(ConfigureAIState.preferredOnboardingModelId)",
            isTopSuggestion: true,
            downloadSizeBytes: 3_677_829_017,
            rootDirectory: root
        )
        if onDisk {
            let dir = model.localDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            try Data().write(to: dir.appendingPathComponent("model-00001-of-00001.safetensors"))
        }
        return model
    }

    @Test func offeredOnByDefault_whenItRunsComfortably() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offer = try #require(
            ClassicUpgradeState.raptorOffer(from: [try raptor(root: root, onDisk: false)], totalMemoryGB: 64))
        #expect(offer.compatibility == .compatible)
        #expect(offer.onByDefault)
    }

    @Test func offeredOffByDefault_whenItWouldBeTight() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: false)
        let tightGB = try #require(
            stride(from: 2.0, through: 64, by: 0.5).first { model.compatibility(totalMemoryGB: $0) == .tight })
        let offer = try #require(ClassicUpgradeState.raptorOffer(from: [model], totalMemoryGB: tightGB))
        #expect(offer.compatibility == .tight)
        #expect(!offer.onByDefault)
    }

    @Test func notOffered_whenTooLarge_alreadyOnDisk_orMissingFromTheCatalog() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: false)
        #expect(model.compatibility(totalMemoryGB: 2) == .tooLarge)
        #expect(ClassicUpgradeState.raptorOffer(from: [model], totalMemoryGB: 2) == nil)
        let seededRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: seededRoot) }
        #expect(
            ClassicUpgradeState.raptorOffer(from: [try raptor(root: seededRoot, onDisk: true)], totalMemoryGB: 64) == nil)
        #expect(ClassicUpgradeState.raptorOffer(from: [], totalMemoryGB: 64) == nil)
    }

    @Test func theSwitchFollowsTheOffer() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let offer = ClassicUpgradeState.raptorOffer(from: [try raptor(root: root, onDisk: false)], totalMemoryGB: 64)
        let state = ClassicUpgradeState(roster: [.planner, .scout], raptorOffer: offer, asksUsageConsent: false)
        #expect(state.downloadRaptor)
        #expect(state.rosterNames == "Planner and Scout")
        let none = ClassicUpgradeState(roster: [], raptorOffer: nil, asksUsageConsent: false)
        #expect(!none.downloadRaptor)
        #expect(none.startRaptorDownloadIfChosen(), "no offer never blocks the button")
    }

    // MARK: Moving agents once 0.7 lands

    /// The index, config, and tokenizer land in the first seconds of a
    /// download while the weights are still a `.part` file; the bundle only
    /// counts once the downloader clears its in-progress marker.
    @Test func aBundleMidDownload_isNotLoadable_untilItsMarkerClears() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: false)
        let dir = model.localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "model.safetensors.index.json"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        try Data().write(to: dir.appendingPathComponent("model-00001-of-00001.safetensors.part"))
        let marker = dir.appendingPathComponent(ModelManifest.pendingUpdateFilename)
        try Data().write(to: marker)

        #expect(model.computeIsDownloadedFromDisk(), "the file check alone passes mid-download")
        #expect(!RaptorUpgrade.isLoadable(model))
        #expect(ClassicUpgradeState.raptorOffer(from: [model], totalMemoryGB: 64) != nil)

        try FileManager.default.removeItem(at: marker)
        #expect(RaptorUpgrade.isLoadable(model))
    }

    @Test func retiredRaptorIds_matchFullIdsAndBareRepoNames_anyCase() {
        #expect(RaptorUpgrade.isRetiredRaptor("OsaurusAI/Raptor-0.6-4B-JANG_6M"))
        #expect(RaptorUpgrade.isRetiredRaptor("osaurusai/raptor-0.6-4b-jang_4m"))
        #expect(RaptorUpgrade.isRetiredRaptor("OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M"))
        #expect(RaptorUpgrade.isRetiredRaptor("Raptor-0.6-4B-JANG_6M"))
        #expect(!RaptorUpgrade.isRetiredRaptor(ConfigureAIState.preferredOnboardingModelId))
        #expect(!RaptorUpgrade.isRetiredRaptor("openai/gpt-5"))
        #expect(!RaptorUpgrade.isRetiredRaptor(""))
        #expect(ModelManager.retiredRaptorIds.isSubset(of: ModelManager.retiredOsaurusOrgIds))
    }

    /// An in-memory stand-in for the stores the move writes.
    private final class Models {
        var orchestrator: String?
        var agents: [UUID: String]
        var seed: String?

        init(orchestrator: String?, agents: [UUID: String], seed: String?) {
            self.orchestrator = orchestrator
            self.agents = agents
            self.seed = seed
        }

        @MainActor var store: RaptorUpgrade.Store {
            RaptorUpgrade.Store(
                orchestratorModel: { self.orchestrator },
                setOrchestratorModel: { self.orchestrator = $0 },
                agentModels: { self.agents.map { ($0.key, $0.value) } },
                setAgentModel: { self.agents[$0] = $1 },
                seedModel: { self.seed },
                setSeedModel: { self.seed = $0 }
            )
        }
    }

    private func pendingDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "raptor-upgrade-\(UUID().uuidString)"))
        RaptorUpgrade.markPending(defaults: defaults)
        return defaults
    }

    @Test func nothingMoves_whileRaptor07IsNotHere() throws {
        let defaults = try pendingDefaults()
        let models = Models(orchestrator: "OsaurusAI/Raptor-0.6-4B-JANG_6M", agents: [:], seed: nil)
        #expect(RaptorUpgrade.apply(isTargetDownloaded: false, defaults: defaults, store: models.store) == nil)
        #expect(models.orchestrator == "OsaurusAI/Raptor-0.6-4B-JANG_6M")
        #expect(RaptorUpgrade.isPending(defaults: defaults))
    }

    @Test func onlyRetiredRaptorModelsMove_onceItLands_andThePendingFlagClears() throws {
        let defaults = try pendingDefaults()
        let onOld = UUID()
        let onOther = UUID()
        let models = Models(
            orchestrator: "OsaurusAI/Raptor-0.6-4B-JANG_6M",
            agents: [onOld: "osaurusai/raptor-v0.5-8b-a1b-jang_6m", onOther: "openai/gpt-5"],
            seed: "OsaurusAI/Raptor-0.6-4B-JANG_4M")
        let target = ConfigureAIState.preferredOnboardingModelId

        #expect(RaptorUpgrade.apply(isTargetDownloaded: true, defaults: defaults, store: models.store) == 2)
        #expect(models.orchestrator == target)
        #expect(models.agents[onOld] == target)
        #expect(models.agents[onOther] == "openai/gpt-5")
        #expect(models.seed == target)
        #expect(!RaptorUpgrade.isPending(defaults: defaults))
    }

    @Test func otherModelsStay() throws {
        let defaults = try pendingDefaults()
        let agent = UUID()
        let models = Models(orchestrator: "anthropic/claude", agents: [agent: "OsaurusAI/Qwen"], seed: nil)
        #expect(RaptorUpgrade.apply(isTargetDownloaded: true, defaults: defaults, store: models.store) == 0)
        #expect(models.orchestrator == "anthropic/claude")
        #expect(models.agents[agent] == "OsaurusAI/Qwen")
        #expect(models.seed == nil)
    }

    @Test func nothingHappens_withoutThePendingFlag() throws {
        let defaults = try #require(UserDefaults(suiteName: "raptor-upgrade-\(UUID().uuidString)"))
        let models = Models(orchestrator: "OsaurusAI/Raptor-0.6-4B-JANG_6M", agents: [:], seed: nil)
        #expect(RaptorUpgrade.apply(isTargetDownloaded: true, defaults: defaults, store: models.store) == nil)
        #expect(models.orchestrator == "OsaurusAI/Raptor-0.6-4B-JANG_6M")
    }
}
