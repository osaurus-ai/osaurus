import Foundation
import Testing

@testable import OsaurusCore

@Suite("Media discovery for delegation")
struct MediaDiscoveryTests {
    @Test func inspectionReflectsMediaToggles() {
        var agent = Agent(name: "Media helper")
        agent.settings.imageEnabled = true
        agent.settings.videoEnabled = true
        let enabled = AgentCapabilitiesPayload.payload(for: agent)
        #expect(enabled["image_enabled"] as? Bool == true)
        #expect(enabled["video_enabled"] as? Bool == true)
        agent.settings.videoEnabled = false
        #expect(AgentCapabilitiesPayload.payload(for: agent)["video_enabled"] as? Bool == false)
    }

    @Test func videoCatalogEntryDoesNotPretendToBeAChatModel() {
        let model = ImageModelInfo(id: "local-video", canonicalName: "wan-2.1",
            displayName: "Local video", kind: "videoGen", ready: true,
            quantizationBits: nil, defaultSteps: 50, defaultGuidance: 5,
            capabilities: ImageModelCapabilities(), blockedReasons: [], totalBytes: 100)
        let payload = OsaurusInspectTool.mediaModelPayload(model)
        #expect(payload["kind"] as? String == "videoGen")
        #expect(payload["installed"] as? Bool == true)
        #expect(payload["chat_model"] as? Bool == false)
    }
}
