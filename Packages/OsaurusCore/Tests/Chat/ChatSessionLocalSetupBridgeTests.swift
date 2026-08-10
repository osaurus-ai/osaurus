//
//  ChatSessionLocalSetupBridgeTests.swift
//  osaurusTests
//
//  Pins the included temporary-Cloud contract for onboarding's local-first
//  path: while the agent's pinned local default downloads, the session
//  automatically selects a lower-cost, tool-capable Osaurus Router model
//  (never Foundation, another local model, or BYOK); an unreachable Router
//  leaves the selection empty with recovery UI; and once the local download
//  lands, the pinned local model replaces the temporary Cloud session.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionLocalSetupBridgeTests {

    private static let routerProviderId = RemoteProviderManager.osaurusRouterProviderId

    // MARK: - Fixtures

    private func makeFoundationItem() -> ModelPickerItem {
        ModelPickerItem(id: "foundation", displayName: "Foundation", source: .foundation)
    }

    private func makeRouterItem(
        id: String = "osaurus/deepseek-ai/deepseek-v4-flash",
        inputPrice: Int64 = 100_000,
        outputPrice: Int64 = 300_000,
        contextLength: Int = 65_536,
        supportsTools: Bool? = true
    ) -> ModelPickerItem {
        ModelPickerItem(
            id: id,
            displayName: "Test Cloud Model",
            source: .remote(providerName: "Osaurus", providerId: Self.routerProviderId),
            inputPriceMicroPerMTok: inputPrice,
            outputPriceMicroPerMTok: outputPrice,
            contextLength: contextLength,
            supportsToolCalling: supportsTools
        )
    }

    private func makeOtherRemoteItem() -> ModelPickerItem {
        ModelPickerItem(
            id: "byok/gpt-test",
            displayName: "BYOK Model",
            source: .remote(providerName: "Other Provider", providerId: UUID())
        )
    }

    /// A session whose agent has a pinned local default that is still
    /// downloading (absent from the picker with an in-flight download state).
    /// Callers must run `cleanup` when done.
    private func makePendingLocalSession() -> (
        session: ChatSession, localModelId: String, cleanup: () async -> Void
    ) {
        let localModelId = "mlx-test/pending-local-\(UUID().uuidString)"
        let agent = Agent(name: "Bridge Test Agent \(UUID().uuidString)")
        AgentManager.shared.add(agent)
        AgentManager.shared.updateDefaultModel(for: agent.id, model: localModelId)
        ModelManager.shared.downloadService.downloadStates[localModelId] =
            .downloading(progress: 0.4)

        let session = ChatSession()
        session.agentId = agent.id

        let cleanup: () async -> Void = {
            ModelManager.shared.downloadService.downloadStates[localModelId] = nil
            _ = await AgentManager.shared.delete(id: agent.id)
        }
        return (session, localModelId, cleanup)
    }

    /// Drain the session's initial `ModelPickerItemCache.$items` snapshot
    /// application (queued as a main-actor task at init) so it can't clobber
    /// the items a test applies afterwards.
    private func drainInitialCacheSnapshot() async {
        for _ in 0 ..< 3 { await Task.yield() }
    }

    // MARK: - Automatic included Cloud

    /// While the pinned local default downloads, the included Router model is
    /// selected automatically, while the durable agent pin remains local.
    @Test func pendingLocalAutomaticallySelectsIncludedRouterModel() async {
        let (session, localModelId, cleanup) = makePendingLocalSession()
        await drainInitialCacheSnapshot()

        let router = makeRouterItem()
        session.applyPickerItems([
            makeFoundationItem(), makeOtherRemoteItem(), router,
        ])

        #expect(session.selectedModel == router.id)
        #expect(session.temporaryCloudModelDisplayName == "DeepSeek V4 Flash")
        #expect(AgentManager.shared.effectiveModel(for: session.agentId!) == localModelId)
        // Progress must remain addressable while Cloud is selected so the
        // empty state keeps rendering the local download.
        #expect(session.pendingLocalSetupModelId == localModelId)
        await cleanup()
    }

    // MARK: - Bridge candidate is Router-only

    /// The value candidate is Router-only even when Foundation, local, and
    /// other remote models appear earlier in picker order.
    @Test func valueCandidateSelectsOnlyRouterModel() {
        let localItem = ModelPickerItem(
            id: "mlx-test/some-other-local",
            displayName: "Other Local",
            source: .local
        )
        let router = makeRouterItem()
        let items = [makeFoundationItem(), localItem, makeOtherRemoteItem(), router]

        #expect(ChatSession.osaurusRouterValueCandidate(in: items)?.id == router.id)
    }

    /// No Router model in the list — the bridge offers nothing, even though
    /// other chat-capable models exist.
    @Test func valueCandidateIsNilWithoutRouterModels() {
        let items = [makeFoundationItem(), makeOtherRemoteItem()]
        #expect(ChatSession.osaurusRouterValueCandidate(in: items) == nil)
    }

    /// Pure cheapest is not enough: a tiny model without tools / useful
    /// context must not beat the cheapest candidate that can run the agent
    /// experience. Among capable models, the lower combined rate wins.
    @Test func valueCandidatePrefersCheapestToolCapableModelWithUsefulContext() {
        let tiny = makeRouterItem(
            id: "osaurus/tiny",
            inputPrice: 1,
            outputPrice: 1,
            contextLength: 8_192,
            supportsTools: false
        )
        let capableValue = makeRouterItem(
            id: "osaurus/capable-value",
            inputPrice: 100,
            outputPrice: 300
        )
        let capableExpensive = makeRouterItem(
            id: "osaurus/capable-expensive",
            inputPrice: 500,
            outputPrice: 900
        )

        let selected = ChatSession.osaurusRouterValueCandidate(
            in: [tiny, capableExpensive, capableValue]
        )
        #expect(selected?.id == capableValue.id)
    }

    /// Product policy outranks generic value sorting for first-run: DeepSeek
    /// V4 Flash wins even when another capable Router model is cheaper.
    @Test func valueCandidatePinsDeepSeekV4FlashForFirstRun() {
        let cheaper = makeRouterItem(
            id: "osaurus/provider/cheaper-capable",
            inputPrice: 1,
            outputPrice: 1
        )
        let deepSeek = makeRouterItem(
            inputPrice: 500,
            outputPrice: 1_000
        )

        #expect(
            ChatSession.osaurusRouterValueCandidate(in: [cheaper, deepSeek])?.id
                == deepSeek.id
        )
    }

    /// The recovery adoption path selects the Router model for the session
    /// without touching the agent's pinned local default.
    @Test func recoveryAdoptionSelectsRouterModelAndKeepsLocalPin() async {
        let (session, localModelId, cleanup) = makePendingLocalSession()
        await drainInitialCacheSnapshot()

        let router = makeRouterItem()
        session.applyPickerItems([makeFoundationItem(), makeOtherRemoteItem()])
        #expect(session.selectedModel == nil)
        session.applyPickerItems([makeFoundationItem(), makeOtherRemoteItem(), router])

        let adopted = await session.adoptOsaurusRouterModelWhileLocalSetupPending(
            maxConnectAttempts: 1
        )

        #expect(adopted == true)
        #expect(session.selectedModel == router.id)
        // The agent default must still be the (downloading) local model.
        #expect(AgentManager.shared.effectiveModel(for: session.agentId!) == localModelId)
        await cleanup()
    }

    /// A stale non-Router session selection must not be mistaken for a
    /// successful bridge. Replace it with the included Router model while
    /// preserving the pinned local default.
    @Test func recoveryAdoptionReplacesNonRouterSelection() async {
        let (session, localModelId, cleanup) = makePendingLocalSession()
        await drainInitialCacheSnapshot()

        let foundation = makeFoundationItem()
        let router = makeRouterItem()
        session.applyPickerItems([foundation, router])
        session.selectedModel = foundation.id
        // A direct assignment normally persists as a manual pick; restore the
        // pinned local default to model the stale session-only selection this
        // recovery path is designed to replace.
        AgentManager.shared.updateDefaultModel(for: session.agentId!, model: localModelId)

        let adopted = await session.adoptOsaurusRouterModelWhileLocalSetupPending(
            maxConnectAttempts: 1,
            connectIfNeeded: false
        )

        #expect(adopted == true)
        #expect(session.selectedModel == router.id)
        #expect(AgentManager.shared.effectiveModel(for: session.agentId!) == localModelId)
        await cleanup()
    }

    // MARK: - Unavailable Router

    /// When no Router model is reachable (empty catalog, connect no-op), the
    /// bridge reports failure and leaves the selection empty — no fallback to
    /// Foundation, local, or BYOK models.
    @Test func unavailableRouterLeavesSelectionEmpty() async {
        let (session, localModelId, cleanup) = makePendingLocalSession()
        await drainInitialCacheSnapshot()

        session.applyPickerItems([makeFoundationItem(), makeOtherRemoteItem()])
        #expect(session.selectedModel == nil)

        let adopted = await session.adoptOsaurusRouterModelWhileLocalSetupPending(
            maxConnectAttempts: 1,
            connectIfNeeded: false
        )

        #expect(adopted == false)
        #expect(session.selectedModel == nil)
        #expect(session.pendingLocalSetupModelId == localModelId)
        await cleanup()
    }

    // MARK: - Local completion restores the pin

    /// After a temporary Cloud session via the bridge, the local download
    /// landing (model appears in the picker) restores the pinned local model
    /// through normal picker reconciliation — the bridge selection was never
    /// recorded as a manual pick or agent default.
    @Test func localCompletionRestoresPinnedLocalModel() async {
        let (session, localModelId, cleanup) = makePendingLocalSession()
        await drainInitialCacheSnapshot()

        let router = makeRouterItem()
        session.applyPickerItems([router])
        let adopted = await session.adoptOsaurusRouterModelWhileLocalSetupPending(
            maxConnectAttempts: 1
        )
        #expect(adopted == true)
        #expect(session.selectedModel == router.id)

        // Download lands: the local bundle shows up in the next picker rebuild.
        ModelManager.shared.downloadService.downloadStates[localModelId] = .completed
        let localItem = ModelPickerItem(
            id: localModelId,
            displayName: "Pending Local",
            source: .local
        )
        session.applyPickerItems([router, localItem])

        #expect(session.selectedModel == localModelId)
        #expect(session.pendingLocalSetupModelId == nil)
        await cleanup()
    }
}
