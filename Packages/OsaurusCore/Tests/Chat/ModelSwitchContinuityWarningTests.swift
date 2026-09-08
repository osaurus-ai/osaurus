import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model switch continuity warning")
@MainActor
struct ModelSwitchContinuityWarningTests {

    @Test("model-switch advisory never suppresses RAM or swap safety rows")
    func safetyRowsRemainVisible() throws {
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

        #expect(rows.contains("ramPressureRow"))
        #expect(rows.contains("swapPressureRow"))
        #expect(rows.contains("modelSwitchContinuityRow"))
        #expect(!rows.contains("if modelSwitchContinuityWarning != nil"))
    }

    @Test("warns only for a real mid-conversation model change")
    func warningGate() {
        #expect(
            ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "org/old", newModel: "org/new", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "org/old", newModel: "org/old", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "ORG/OLD", newModel: "org/old", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: nil, newModel: "org/new", hasConversation: true
            )
        )
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "org/old", newModel: "org/new", hasConversation: false
            )
        )
        // Mode 2: the chip is pinned to the remote agent's model and inference
        // runs on the remote host, so a pin change is never a local switch.
        #expect(
            !ChatSession.shouldWarnAboutModelSwitch(
                previousModel: "openai-chatgpt/gpt-5.6-sol", newModel: "foundation",
                hasConversation: true, isRemoteAgentTarget: true
            )
        )
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
}
