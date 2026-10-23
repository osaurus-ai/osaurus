import Foundation
import Testing

@testable import OsaurusCore

@Suite("Media discovery for delegation")
struct MediaDiscoveryTests {
    @Test func nativeVideoUsesFrameGridInsteadOfCloudDurationPresets() throws {
        var model = MediaModelInfo(target: .init(backend: .local, modelID: "wan"),
            displayName: "Wan", providerName: "Local", kind: .textToVideo,
            constraints: .init(durations: ["3.0625s", "5.0625s"]), pricing: nil,
            privacy: nil, offline: false, deprecatedAt: nil)
        var params = VideoJobParams(prompt: "A sailboat", duration: "0.3125s",
            audio: false, width: 160, height: 96, frameCount: 5, fps: 16, steps: 2, seed: 7)
        try VideoSubagentKind(params: params, argumentsJSON: "{}").validate(model: model)
        params.duration = "0.5s"
        #expect(throws: (any Error).self) {
            try VideoSubagentKind(params: params, argumentsJSON: "{}").validate(model: model)
        }
        params.duration = "0.3125s"
        model.target = .init(backend: .osaurusCloud, modelID: "cloud-video")
        #expect(throws: (any Error).self) {
            try VideoSubagentKind(params: params, argumentsJSON: "{}").validate(model: model)
        }
    }

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
