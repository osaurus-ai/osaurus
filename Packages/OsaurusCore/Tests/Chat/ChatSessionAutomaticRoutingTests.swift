import Foundation
import Testing

@testable import OsaurusCore

@Suite("Chat session automatic model routing", .serialized)
@MainActor
struct ChatSessionAutomaticRoutingTests {
    @Test("session selects a concrete safe local route without replacing Automatic setting")
    func initialAutomaticRoutePreservesSetting() async {
        await StoragePathsTestLock.shared.run {
            let agentId = await MainActor.run {
                let agent = Agent(name: "Automatic Route Test \(UUID().uuidString)")
                AgentManager.shared.add(agent)
                AgentManager.shared.updateDefaultModel(
                    for: agent.id,
                    model: AutomaticModelRoutingPolicy.modelId
                )
                let small = ModelPickerItem(
                    id: "local/small",
                    displayName: "Small",
                    source: .local,
                    estimatedMemoryGB: 3,
                    hardwareCompatibility: .compatible
                )
                let strong = ModelPickerItem(
                    id: "local/strong",
                    displayName: "Strong",
                    source: .local,
                    estimatedMemoryGB: 8,
                    hardwareCompatibility: .compatible
                )
                let cloud = ModelPickerItem.fromRemoteModel(
                    modelId: "cloud/frontier",
                    providerName: "Cloud",
                    providerId: UUID()
                )

                let session = ChatSession()
                session.agentId = agent.id
                session.applyPickerItems([cloud, small, strong])

                #expect(session.selectedModel == strong.id)
                #expect(session.automaticRoutingDecision?.modelId == strong.id)
                #expect(session.usesAutomaticModelRouting)
                #expect(
                    AgentManager.shared.configuredModel(for: agent.id)
                        == AutomaticModelRoutingPolicy.modelId
                )

                // Clicking the row Automatic already resolved to is a same-value
                // binding write. It must still be treated as an intentional manual
                // selection and replace the persisted sentinel.
                session.selectModelFromPicker(strong.id)
                #expect(AgentManager.shared.configuredModel(for: agent.id) == strong.id)
                #expect(!session.usesAutomaticModelRouting)
                return agent.id
            }
            _ = await AgentManager.shared.delete(id: agentId)
        }
    }
}
