import Foundation
import Testing
@testable import OsaurusCore

@Suite("Chat error messages")
struct ChatErrorMessagesTests {
    @Test func resourceExhaustionGetsActionableUserMessage() {
        let error = NSError(
            domain: "ModelRuntime",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Not enough memory to load gemma: needs ~120.0 GB but this Mac has 64.0 GB."
            ]
        )

        let message = ChatErrorMessages.assistantMessage(for: error)

        #expect(message.contains("Ran out of system resources"))
        #expect(message.contains("Free memory"))
    }

    @Test func metalAllocationErrorsAreClassifiedAsResourceExhaustion() {
        #expect(
            ChatErrorMessages.isSystemResourceExhaustion(
                "mlx_error: Metal failed to allocate memory for command buffer"
            )
        )
    }

    @Test func insufficientFundsGetsAddCreditsMessage() {
        let error = NSError(
            domain: "RemoteProviderService",
            code: 402,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Request failed: HTTP 402: {\"error\":{\"code\":\"INSUFFICIENT_FUNDS\",\"message\":\"balance below estimated max cost\"}}"
            ]
        )

        let message = ChatErrorMessages.assistantMessage(for: error)

        #expect(message.contains("out of credits"))
        #expect(message.contains("Add credits"))
    }

    @Test func ordinaryRuntimeErrorsKeepOriginalText() {
        let error = NSError(
            domain: "ModelRuntime",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported model type: gemma4_unified"]
        )

        #expect(
            ChatErrorMessages.assistantMessage(for: error)
                == "Error: Unsupported model type: gemma4_unified"
        )
    }

    @Test func remoteConnectFailureSurfacesProviderErrorDescription() {
        // The Secure-Channel handshake failure copy comes through verbatim (no
        // "Error:" prefix) so the chat connection pill can style it.
        let error = RemoteProviderServiceError.requestFailed(
            "Could not reach the remote agent (Secure Channel handshake failed)."
        )
        let message = ChatErrorMessages.remoteConnectFailure(error)
        #expect(message.contains("Secure Channel handshake failed"))
        #expect(!message.hasPrefix("Error:"))
    }

    @Test func remoteConnectFailureFallsBackForBlankDescription() {
        // An error whose localized description is empty must not produce an
        // empty pill — a neutral fallback is used instead.
        struct BlankError: LocalizedError { var errorDescription: String? { "" } }
        let message = ChatErrorMessages.remoteConnectFailure(BlankError())
        #expect(!message.isEmpty)
    }
}
