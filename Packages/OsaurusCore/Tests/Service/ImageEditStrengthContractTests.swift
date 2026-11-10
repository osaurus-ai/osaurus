import Foundation
import Testing
import vMLXFlux
@testable import OsaurusCore

@Suite(.serialized)
struct ImageEditStrengthContractTests {
    private func limits(partialDenoising: Bool) -> FluxModelLimits {
        FluxModelLimits(
            dimensionMultiple: 16, minDimension: 16, minimumSteps: 1,
            supportsNegativePrompt: true, supportsEditNegativePrompt: true,
            supportsStrength: partialDenoising, supportsMask: false,
            maxSourceImages: 1, supportedFormats: [.png])
    }

    @Test(arguments: [false, true])
    func omittedStrengthUsesDeclaredEngineContract(partialDenoising: Bool) async throws {
        // A unique registry identity prevents a family-name special case from
        // satisfying this test. The real service and engine wrappers run.
        let fixture = ImageProducerFixture(
            held: [], kind: .imageEdit, limits: limits(partialDenoising: partialDenoising))
        let events = try await collectImageEvents(await fixture.service.edit(
            .init(model: fixture.first, prompt: "edit", sourceImages: [Data([1, 2, 3])]),
            jobID: "omitted-strength"))
        await fixture.service.waitForJobDrain(jobID: "omitted-strength")
        let state = await fixture.probe.snapshot()
        let request = try #require(state.edits.first)
        #expect(request.strength == (partialDenoising ? 0.75 : 1))
        #expect(events.contains { if case .completed = $0 { return true }; return false })
        await fixture.service.unload()
    }

    @Test func explicitUnsupportedStrengthFailsBeforeLoad() async throws {
        let fixture = ImageProducerFixture(
            held: [], kind: .imageEdit, limits: limits(partialDenoising: false))
        let params = ImageEditParameters(
            model: fixture.first, prompt: "edit", sourceImages: [Data([1, 2, 3])], strength: 0.6)
        do {
            _ = try await fixture.service.estimatedPeakBytes(for: params)
            Issue.record("Unsupported explicit strength must fail metadata-only admission")
        } catch FluxError.invalidField(let field, let value, let allowed) {
            #expect(field == "strength" && value == "0.6")
            #expect(allowed == "omitted or 1; partial denoising is not supported")
        }
        let events = try await collectImageEvents(await fixture.service.edit(params, jobID: "invalid-strength"))
        await fixture.service.waitForJobDrain(jobID: "invalid-strength")
        let state = await fixture.probe.snapshot()
        #expect(state.loads.isEmpty && state.edits.isEmpty)
        #expect(events.contains {
            if case .failed(let message, _) = $0 { return message.contains("partial denoising") }
            return false
        })
    }

    @Test func explicitSupportedStrengthReachesEngineUnchanged() async throws {
        let fixture = ImageProducerFixture(
            held: [], kind: .imageEdit, limits: limits(partialDenoising: true))
        _ = try await collectImageEvents(await fixture.service.edit(
            .init(model: fixture.first, prompt: "edit", sourceImages: [Data([1, 2, 3])], strength: 0.4),
            jobID: "explicit-strength"))
        await fixture.service.waitForJobDrain(jobID: "explicit-strength")
        let request = try #require(await fixture.probe.snapshot().edits.first)
        #expect(request.strength == 0.4)
        await fixture.service.unload()
    }

    @Test(arguments: [false, true])
    func composerControlsUseDeclaredEngineContract(partialDenoising: Bool) {
        let capabilities = ImageGenerationService.capabilities(
            kind: .imageEdit, canonical: "unlisted-edit-family", entry: nil,
            limits: limits(partialDenoising: partialDenoising))
        let controls = ImageComposerRequestBuilder.controls(
            capabilities: capabilities, fallbackKind: "imageEdit", hasReferences: true)
        #expect(controls.strength == partialDenoising)
        let explicit = ImageComposerSettings(strength: 0.6)
        #expect(ImageComposerRequestBuilder.hasUnsupportedEditOverrides(
            controls: controls, settings: explicit) == !partialDenoising)
    }
}
