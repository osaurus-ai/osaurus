import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DelegatedModelOverrideTests {
    private func item(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .local)
    }

    @Test func admittedModelReachesChildAndSurvivesPickerRefresh() async {
        let agent = Agent(name: "Delegated Model \(UUID().uuidString)")
        AgentManager.shared.add(agent)
        let request = DispatchRequest(
            prompt: "bounded child",
            agentId: agent.id,
            source: .delegation,
            delegationResponseTokenCap: 2048,
            delegationContextPositionCap: 4096,
            delegationAssistantTurnCap: 2,
            delegationModel: "mlx-test/admitted"
        )
        let context = BackgroundTaskManager.shared.makeContextForTesting(request)
        let session = context.chatSession
        session.detachPickerCacheForTesting()
        for _ in 0 ..< 3 { await Task.yield() }
        AgentManager.shared.updateDefaultModel(for: agent.id, model: "mlx-test/default")
        session.applyPickerItems([item("mlx-test/default"), item("mlx-test/admitted")])
        session.applyAgentDefaultModelForDispatch()
        #expect(session.selectedModel == "mlx-test/admitted")
        #expect(session.delegationBudget?.responseTokens == 2048)

        session.applyPickerItems([
            item("mlx-test/default"), item("mlx-test/admitted"), item("mlx-test/new"),
        ])
        #expect(session.selectedModel == "mlx-test/admitted")
        #expect(AgentManager.shared.effectiveModel(for: agent.id) == "mlx-test/default")

        // A removed admitted model is not permission to load another model.
        session.applyPickerItems([item("mlx-test/default")])
        session.applyAgentDefaultModelForDispatch()
        #expect(session.selectedModel == "mlx-test/admitted")
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test func ordinaryDispatchIgnoresDelegationModel() {
        for source in [SessionSource.chat, .schedule, .channel] {
            let request = DispatchRequest(
                prompt: "ordinary",
                agentId: UUID(),
                source: source,
                delegationModel: "mlx-test/not-applicable"
            )
            #expect(request.delegationModel == nil)
            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            #expect(context.chatSession.delegationModel == nil)
        }
    }
}
