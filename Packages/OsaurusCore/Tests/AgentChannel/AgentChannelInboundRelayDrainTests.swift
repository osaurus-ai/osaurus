//
//  AgentChannelInboundRelayDrainTests.swift
//  osaurusTests
//
//  The notice a sender gets when the safety gate refuses their queued
//  messages, so a denied drain is never silent (#3184).
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelInboundRelayDrainTests {

    @Test func denialNoticeAsksToResend() {
        #expect(
            AgentChannelInboundRelay.denialNotice(retryAfterSeconds: nil)
                == "Couldn't start your last message. Please send it again."
        )
        #expect(
            AgentChannelInboundRelay.denialNotice(retryAfterSeconds: 0)
                == "Couldn't start your last message. Please send it again."
        )
    }

    @Test func denialNoticeRoundsRetryDelayUp() {
        #expect(
            AgentChannelInboundRelay.denialNotice(retryAfterSeconds: 12.2)
                == "Couldn't start your last message. Please send it again in 13 seconds."
        )
    }
}
