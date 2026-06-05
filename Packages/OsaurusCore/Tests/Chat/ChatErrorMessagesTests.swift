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
}
