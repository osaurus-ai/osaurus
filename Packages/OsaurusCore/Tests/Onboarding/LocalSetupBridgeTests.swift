//
//  LocalSetupBridgeTests.swift
//  osaurusTests
//
//  While the local model picked at onboarding downloads, delegated work
//  runs on the Osaurus Cloud stand-in instead of failing on a bundle that
//  is not on disk. Only the first run's non-personal asks may move a
//  local-only writer to the cloud; every other local-only slot waits.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct LocalSetupBridgeTests {
    private static let raptor = "mlx-test/raptor"
    private static let router = "osaurus/deepseek-v4-1-flash"

    private static let routerItem = ModelPickerItem(
        id: router, displayName: "DeepSeek V4.1 Flash",
        source: .remote(providerName: "Osaurus", providerId: RemoteProviderManager.osaurusRouterProviderId),
        inputPriceMicroPerMTok: 100_000, outputPriceMicroPerMTok: 300_000, contextLength: 65_536,
        supportsToolCalling: true)

    private static func state(_ value: DownloadState?) -> (String) -> DownloadState? {
        { $0 == raptor ? value : nil }
    }

    // MARK: - Resolver

    @Test
    func aLocalModelIsPendingOnlyWhileItsDownloadIsUnfinished() {
        for pending: DownloadState in [.downloading(progress: 0.3), .paused(progress: 0.5), .failed(error: "offline")] {
            #expect(LocalSetupBridge.isPending(Self.raptor, availableIds: [], downloadState: Self.state(pending)))
        }
        for settled: DownloadState? in [.completed, .notStarted, nil] {
            #expect(!LocalSetupBridge.isPending(Self.raptor, availableIds: [], downloadState: Self.state(settled)))
        }
        #expect(
            !LocalSetupBridge.isPending(
                Self.raptor, availableIds: [Self.raptor], downloadState: Self.state(.downloading(progress: 0.9))),
            "listed in the picker means usable")
        #expect(!LocalSetupBridge.isPending(nil, availableIds: [], downloadState: Self.state(.downloading(progress: 0))))
    }

    @Test
    func runModel_isTheRouterStandInWhileDownloading_andTheModelOtherwise() {
        let downloading = Self.state(.downloading(progress: 0.4))
        #expect(
            LocalSetupBridge.runModel(for: Self.raptor, items: [Self.routerItem], downloadState: downloading)
                == Self.router)
        #expect(
            LocalSetupBridge.runModel(for: Self.raptor, items: [], downloadState: downloading) == Self.raptor,
            "no Router model listed: the work fails on the real model rather than on another one")
        let local = ModelPickerItem(id: Self.raptor, displayName: "Raptor", source: .local)
        #expect(
            LocalSetupBridge.runModel(for: Self.raptor, items: [Self.routerItem, local], downloadState: Self.state(.completed))
                == Self.raptor)
        #expect(LocalSetupBridge.standIn(for: Self.raptor, items: [Self.routerItem], downloadState: Self.state(nil)) == nil)
    }

    /// Workflow agent steps and spawned agents run on this: a teammate
    /// pinned to the downloading model moves to the stand-in, a teammate
    /// locked to it does not.
    @Test
    func anAgentsDelegatedWork_movesToTheStandIn_unlessItIsLocked() async {
        let agent = Agent(name: "Bridge Agent \(UUID().uuidString)", autonomousExec: AutonomousExecConfig(enabled: false))
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: Self.raptor)
        let downloading = Self.state(.downloading(progress: 0.2))

        #expect(LocalSetupBridge.runModel(forAgent: agent.id, items: [Self.routerItem], downloadState: downloading) == Self.router)
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == Self.raptor, "the pin is untouched")

        AgentManager.shared.updateModelLocked(for: agent.id, locked: true)
        #expect(LocalSetupBridge.runModel(forAgent: agent.id, items: [Self.routerItem], downloadState: downloading) == Self.raptor)
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func onlyTheNonPersonalFirstRunAsksAreBridgeable() {
        #expect(LocalSetupBridge.bridgeableTemplateIDs == [OnboardingPaths.researchBriefId])
    }

    // MARK: - Workflow slots

    private static func env(downloading: Bool = true, bridge: String? = router) -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(
                localModelIds: ["foundation"],
                providers: [.init(prefix: "osaurus", name: "Osaurus", models: ["deepseek-v4-1-flash"])]),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true }, knowledgeCollectionExists: { _ in true })
        env.defaultModel = raptor
        env.defaultModelDownloading = downloading
        env.bridgeModel = bridge
        env.bridgeableTemplateIDs = LocalSetupBridge.bridgeableTemplateIDs
        return env
    }

    private static func modelItems(_ template: Template, _ env: SetupChecker.Environment) -> [SetupItem] {
        SetupChecker.check(template, bindings: InstallBindings(), subjectId: template.id, environment: env)
            .items.filter { $0.kind == .model }
    }

    @Test
    func aCloudAllowedSlot_runsOnTheStandIn_whileTheDefaultDownloads() {
        let slot = ModelRequirement(slot: "writer")
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: Self.env()) == Self.router)
        #expect(
            SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: Self.env(bridge: nil)) == nil)
        var def = WF.intake()
        def.modelSlots = [ModelRequirement(slot: "decision")]
        #expect(Self.modelItems(WF.template(def), Self.env()).isEmpty)
        #expect(
            Self.modelItems(WF.template(def), Self.env(bridge: nil)).first?.detail
                == "This slot waits for \(Self.raptor) to finish downloading.")
    }

    @Test
    func aLocalOnlySlot_waitsForThePrivateModel() throws {
        let slot = ModelRequirement(slot: "writer", locality: .localOnly)
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: Self.env()) == nil)

        var def = WF.intake()
        def.modelSlots = [ModelRequirement(slot: "decision", locality: .localOnly)]
        let item = try #require(Self.modelItems(WF.template(def), Self.env()).first)
        #expect(item.isBlocking)
        #expect(item.detail == "This slot is local only, so it waits for \(Self.raptor) to finish downloading.")
        #expect(!item.hasNoModel, "a model is chosen; it is still downloading")
    }

    @Test
    func theResearchBriefWriter_runsOnTheStandIn_andPersonalAsksDoNot() throws {
        let brief = try #require(TeamSeeder.loadBundled("default-workflow-research-brief"))
        #expect(brief.id == OnboardingPaths.researchBriefId)
        #expect(Self.modelItems(brief, Self.env()).isEmpty)
        let writer = try #require(brief.requirements.models.first)
        let run = SetupChecker.runSlot(writer, templateID: brief.id, environment: Self.env())
        #expect(SetupChecker.resolvedModel(for: run, bindings: InstallBindings(), environment: Self.env()) == Self.router)
        #expect(
            SetupChecker.runSlot(writer, templateID: brief.id, environment: Self.env(bridge: nil)).locality == .localOnly)
        #expect(Self.modelItems(brief, Self.env(bridge: nil)).first?.isBlocking == true)

        let personal = try #require(PreparedAskCatalog.templates().first { $0.id != OnboardingKeep.saveNoteId })
        let installed = try #require(PreparedAskCatalog.installed(id: personal.id, environment: Self.env()))
        #expect(installed.template.requirements.models.map(\.locality) == [.localOnly], "no cloud writer")
        #expect(Self.modelItems(installed.template, Self.env()).first?.isBlocking == true)
    }

    @Test
    func onceTheDownloadLands_slotsAreBackOnTheLocalModel() {
        var env = Self.env(downloading: false, bridge: nil)
        env.modelCatalog = ConfigModelReference.Catalog(localModelIds: [Self.raptor], providers: [])
        let slot = ModelRequirement(slot: "writer", locality: .localOnly)
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: env) == Self.raptor)
    }
}
