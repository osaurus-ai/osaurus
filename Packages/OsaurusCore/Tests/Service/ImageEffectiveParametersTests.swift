import Foundation
import Testing
import vMLXFlux
@testable import OsaurusCore

@Suite(.serialized)
struct ImageEffectiveParametersTests {
    @Test func validationReasonSurvivesFoundationErrorBridge() {
        // Native image-tool failures use localizedDescription. Without LocalizedError,
        // a valid rejection becomes only "ImageGenerationError error 4" to the agent.
        let error: any Error = ImageGenerationError.invalidRequest("strength is an edit-only parameter")
        #expect(error.localizedDescription == "invalid request: strength is an edit-only parameter")
        #expect((error as NSError).localizedDescription == error.localizedDescription)
        let engine: any Error = ImageGenerationError.engine("upscale output exceeds the pixel budget")
        #expect(engine.localizedDescription == "upscale output exceeds the pixel budget")
    }

    @Test func bridgeKeepsRuntimeValuesInsteadOfEchoingRequest() async throws {
        let actual = EffectiveImageParameters(
            width: 768, height: 512, steps: 8, guidance: 1, seed: UInt64.max,
            sampler: "euler", scheduler: "bundle-sigmas", sampleSigmas: [1, 0.5])
        let fixture = ImageProducerFixture(held: [], effectiveParameters: actual)
        let events = try await collectImageEvents(await fixture.service.generate(
            .init(model: fixture.first, prompt: "metadata", steps: 40, seed: UInt64.max), jobID: "metadata"))
        await fixture.service.waitForJobDrain(jobID: "metadata")
        let image = try #require(events.compactMap { event -> GeneratedImage? in
            if case .completed(let images) = event { return images.first }
            return nil
        }.first)
        let parameters = try #require(image.effectiveParameters)
        #expect(parameters.width == 768 && parameters.height == 512)
        #expect(parameters.steps == 8 && parameters.seed == UInt64.max)
        #expect(parameters.sampleSigmas == actual.sampleSigmas)
        let dto = ImageResultDTO(url: image.url.absoluteString, b64_json: nil,
                                 seed: image.seed, effective_parameters: parameters)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
        let result = try #require(json["effective_parameters"] as? [String: Any])
        #expect((result["steps"] as? NSNumber)?.intValue == 8)
        #expect((result["seed"] as? NSNumber)?.uint64Value == UInt64.max)
        let tool = parameters.jsonObject
        #expect(tool["steps"] as? Int == 8)
        #expect(tool["seed"] as? UInt64 == UInt64.max)
        #expect(tool["strength"] == nil && tool["modelRevision"] == nil)
        let details = ImageEffectiveParameters.activityDetails(["steps": "40", "size": "1024x1024"], images: [image])
        #expect(details["steps"] == "8" && details["requested_steps"] == "40")
        #expect(details["size"] == "768x512" && details["requested_size"] == "1024x1024")
        await fixture.service.unload()
    }

    @Test func engineLimitsRejectBeforeCallingLoader() async throws {
        let limits = FluxModelLimits(
            dimensionMultiple: 32, minDimension: 32, minimumSteps: 2,
            supportsNegativePrompt: false, supportsEditNegativePrompt: false,
            supportsStrength: false, supportsMask: false, maxSourceImages: 1, supportedFormats: [.png])
        let fixture = ImageProducerFixture(held: [], limits: limits)
        let events = try await collectImageEvents(await fixture.service.generate(
            .init(model: fixture.first, prompt: "invalid", width: 1000), jobID: "invalid-metadata"))
        await fixture.service.waitForJobDrain(jobID: "invalid-metadata")
        let state = await fixture.probe.snapshot()
        #expect(state.loads.isEmpty && state.starts.isEmpty)
        #expect(events.contains {
            if case .failed(let message, _) = $0 { return message.contains("invalid request: width=1000") }
            return false
        })
    }

    @Test func legacyResultsDoNotInventMetadata() throws {
        let result = ImageResultDTO(url: "file:///image.png", b64_json: nil, seed: 7)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(json["effective_parameters"] == nil)
        let requested = ["steps": "40"]
        #expect(ImageEffectiveParameters.activityDetails(requested, images: [.init(url: URL(fileURLWithPath: "/image.png"), seed: 7)]) == requested)
    }
}
