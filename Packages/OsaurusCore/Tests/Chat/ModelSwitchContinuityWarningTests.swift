import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model switch continuity warning")
@MainActor
struct ModelSwitchContinuityWarningTests {

    @Test("model-switch advisory remains without the removed RAM or swap warnings")
    func continuityAdvisoryRemainsVisible() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Views/Chat/FloatingInputCard.swift"),
            encoding: .utf8
        )
        let anchor = try #require(source.range(of: "if !showVoiceOverlay"))
        let tail = String(source[anchor.lowerBound...])
        let end = try #require(tail.range(of: "// Read-only screen-context indicator"))
        let rows = String(tail[..<end.lowerBound])

        #expect(!rows.contains("ramPressureRow"))
        #expect(!rows.contains("swapPressureRow"))
        #expect(rows.contains("modelSwitchContinuityRow"))
        #expect(!rows.contains("if modelSwitchContinuityWarning != nil"))
    }

    @Test("sending dismisses the advisory, which only offers keep-original or new chat")
    func sendDismissesAdvisoryAndDropsContinue() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Views/Chat/FloatingInputCard.swift"),
            encoding: .utf8
        )
        // Send stays available under the advisory and accepts the new model.
        let canSendStart = try #require(source.range(of: "private var canSend: Bool {"))
        let canSendBody = String(source[canSendStart.upperBound...].prefix(2000))
        #expect(!canSendBody.contains("modelSwitchContinuityWarning"))
        let sendStart = try #require(source.range(of: "private func syncAndSend() {"))
        let sendBody = String(source[sendStart.upperBound...].prefix(600))
        #expect(sendBody.contains("onDismissModelSwitchContinuityWarning?()"))

        #expect(source.contains("\"Keep Using \\(previous)\""))
        #expect(!source.contains("Continue with This Model"))
    }

    @Test("warns only for a real mid-conversation switch away from a local model")
    func warningGate() {
        func warns(
            _ previous: String?, _ next: String, conversation: Bool = true,
            remoteAgent: Bool = false, previousLocal: Bool = true, nextMedia: Bool = false
        ) -> Bool {
            ChatSession.shouldWarnAboutModelSwitch(
                previousModel: previous, newModel: next, hasConversation: conversation,
                isRemoteAgentTarget: remoteAgent, previousModelIsLocal: previousLocal,
                newModelIsMedia: nextMedia
            )
        }
        #expect(warns("org/old", "org/new"))
        #expect(!warns("org/old", "org/old"))
        #expect(!warns("ORG/OLD", "org/old"))
        #expect(!warns(nil, "org/new"))
        #expect(!warns("org/old", "org/new", conversation: false))
        // Mode 2: the chip is pinned to the remote agent's model and inference
        // runs on the remote host, so a pin change is never a local switch.
        #expect(!warns("openai-chatgpt/gpt-5.6-sol", "foundation", remoteAgent: true))
        // Only an on-device MLX model holds a prefix/KV cache to lose.
        #expect(!warns("openai/gpt-5.5", "anthropic/claude-sonnet-5-5", previousLocal: false))
        #expect(!warns("cloud:background-remover", "cloud:flux-2-max", previousLocal: false, nextMedia: true))
        // Media models never read the transcript, so switching into one is fine.
        #expect(!warns("org/old", "cloud:flux-2-max", nextMedia: true))
    }

    @Test("remote workspace/shared agent pin changes never raise the advisory")
    func remoteAgentTargetSuppressesWarning() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let session = window.session

            session.selectedModel = "openai-chatgpt/gpt-5.6-sol"
            session.turns = [ChatTurn(role: .user, content: "what's the weather")]
            #expect(session.isRemoteAgentTarget == false)

            // Point the window at a remote agent (what connectToRelayAgent /
            // connectToDiscoveredAgent do), then let the pin move the chip.
            window.selectedDiscoveredAgentProviderId = UUID()
            #expect(session.isRemoteAgentTarget)
            session.selectedModel = "foundation"
            #expect(session.modelSwitchContinuityWarning == nil)

            // A stale advisory is cleared once the window is in remote mode.
            session.modelSwitchContinuityWarning = ModelSwitchContinuityWarning(
                previousModelId: "a", newModelId: "b"
            )
            session.selectedModel = "OsaurusAI/Ornith-1.0"
            #expect(session.modelSwitchContinuityWarning == nil)
        }
    }

    /// Switching to a shared-agent tab briefly has no bound provider
    /// (`adoptAgent` clears it and applies the local default model before
    /// the rebind pins the remote one; a pairing repair swaps providers
    /// mid-connect). The stamped workspace context must keep the advisory
    /// off through those transitions.
    @Test("a stamped shared-agent tab never raises the advisory while unbound")
    func workspaceContextSuppressesWarningWithoutProvider() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.workspaceContext = WorkspaceSessionContext(
                workspaceId: "ws-acme",
                agentAddress: "0xaaaa000000000000000000000000000000000001"
            )
            // Local so the plain-tab control case below can warn at all.
            session.pickerItems = [Self.localItem("weather-agent/foundation")]
            session.selectedModel = "weather-agent/foundation"
            session.turns = [ChatTurn(role: .user, content: "hi what's the weather")]
            #expect(session.isRemoteAgentTarget == false, "no window / provider bound")

            // Local default applied while unbound, then the remote pin returns.
            session.selectedModel = "openai-chatgpt/gpt-5.6-sol"
            #expect(session.modelSwitchContinuityWarning == nil)
            session.selectedModel = "weather-agent/foundation"
            #expect(session.modelSwitchContinuityWarning == nil)

            // The same moves on a plain local tab still warn.
            session.workspaceContext = nil
            session.selectedModel = "openai-chatgpt/gpt-5.6-sol"
            #expect(session.modelSwitchContinuityWarning != nil)
        }
    }

    @Test("session warns on a live model change and reset clears it")
    func sessionLifecycle() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.pickerItems = [Self.localItem("org/old"), Self.localItem("org/new")]

            session.selectedModel = "org/old"
            #expect(session.modelSwitchContinuityWarning == nil)

            session.turns = [ChatTurn(role: .user, content: "hello")]
            session.selectedModel = "org/new"
            #expect(
                session.modelSwitchContinuityWarning
                    == ModelSwitchContinuityWarning(
                        previousModelId: "org/old",
                        newModelId: "org/new"
                    )
            )

            session.reset()
            #expect(session.modelSwitchContinuityWarning == nil)
        }
    }

    @Test("remote model switches never warn and clear a stale local advisory")
    func remoteModelSwitchesStayQuiet() async throws {
        try await ChatHistoryTestStorage.run {
            let providerId = UUID()
            let session = ChatSession()
            session.pickerItems = [
                Self.localItem("org/local"),
                ModelPickerItem.fromRemoteModel(
                    modelId: "openai/gpt-5.5", providerName: "OpenAI", providerId: providerId
                ),
                ModelPickerItem.fromRemoteModel(
                    modelId: "openai/gpt-5.6-sol", providerName: "OpenAI", providerId: providerId
                ),
            ]
            session.selectedModel = "openai/gpt-5.5"
            session.turns = [ChatTurn(role: .user, content: "hello")]

            session.selectedModel = "openai/gpt-5.6-sol"
            #expect(session.modelSwitchContinuityWarning == nil)

            // Remote -> local has no cache to lose either.
            session.selectedModel = "org/local"
            #expect(session.modelSwitchContinuityWarning == nil)

            // Local -> remote warns, and further hops keep naming the local
            // model the conversation still belongs to.
            session.selectedModel = "openai/gpt-5.5"
            #expect(session.modelSwitchContinuityWarning != nil)
            session.selectedModel = "openai/gpt-5.6-sol"
            #expect(
                session.modelSwitchContinuityWarning
                    == ModelSwitchContinuityWarning(
                        previousModelId: "org/local",
                        newModelId: "openai/gpt-5.6-sol"
                    )
            )
            session.selectedModel = "org/local"
            #expect(session.modelSwitchContinuityWarning == nil)
        }
    }

    @Test("switching back to the original model clears the advisory")
    func revertClearsWarning() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.pickerItems = [Self.localItem("org/a"), Self.localItem("org/b")]
            session.selectedModel = "org/a"
            session.turns = [ChatTurn(role: .user, content: "hello")]

            session.selectedModel = "org/b"
            #expect(session.modelSwitchContinuityWarning != nil)

            // b is local too, so before this compared b -> a and re-warned.
            session.selectedModel = "org/a"
            #expect(session.modelSwitchContinuityWarning == nil)
        }
    }

    private static func localItem(_ id: String) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: .local)
    }
}
