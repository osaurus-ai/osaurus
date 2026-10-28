import Foundation
import Testing

@testable import OsaurusCore

struct DecisionModelRoutingTests {
    @Test func decisionPickerCannotChat() {
        let item = ModelPickerItem(
            id: "fixture", displayName: "Decision fixture", source: .local, isDecision: true)
        #expect(!item.isLikelyChatCapable)
        #expect(
            ModelPickerItem(id: "chat", displayName: "Chat", source: .local).isLikelyChatCapable)
    }

    @Test func systemOneIsPeerInference() {
        #expect(HTTPHandler.isPeerInferenceRoute(method: .POST, path: "/systemone"))
        #expect(!HTTPHandler.isPeerInferenceRoute(method: .GET, path: "/systemone"))
    }
}
