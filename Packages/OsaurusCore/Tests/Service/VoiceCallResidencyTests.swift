import Foundation
import Testing

@testable import OsaurusCore

@Suite("Voice-call model residency")
struct VoiceCallResidencyTests {
    @Test("a call's turn keeps the model loaded 3.5 minutes under the default wait")
    func callTurnStretchesTheDefaultWait() {
        let policy = ModelRuntime.voiceCallIdleResidency(.defaultWarm, configured: .defaultWarm)
        #expect(policy == .afterSeconds(210))
    }

    @Test("a longer configured wait is kept")
    func longerWaitIsKept() {
        let policy = ModelRuntime.voiceCallIdleResidency(.afterSeconds(600), configured: .afterSeconds(600))
        #expect(policy == .afterSeconds(600))
    }

    @Test("a chat-owned immediate unload under a timed policy still waits for the next call turn")
    func chatOwnedImmediateIsStretched() {
        #expect(ModelRuntime.voiceCallIdleResidency(.immediately, configured: .defaultWarm) == .afterSeconds(210))
    }

    @Test("the user's own unload-at-once or keep-loaded choice wins")
    func explicitChoicesWin() {
        #expect(ModelRuntime.voiceCallIdleResidency(.immediately, configured: .immediately) == .immediately)
        #expect(ModelRuntime.voiceCallIdleResidency(.never, configured: .never) == .never)
        #expect(ModelRuntime.voiceCallIdleResidency(.never, configured: .defaultWarm) == .never)
    }
}
