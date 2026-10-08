import Foundation
import Testing
import vMLXFlux
@testable import OsaurusCore

// Request forwarding/admission is executed through the REAL service and
// FluxEngine, not reconstructed from the policy under test. The loader key is
// unique; canonical Q21 metadata is separate, so global models are not replaced.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QwenImage21ServiceWiringTests {
    private func q21() -> ImageProducerFixture {
        ImageProducerFixture(held: [], canonical: "qwen-image-2.1",
            capabilities: ImageGenerationService.capabilities(
                kind: .imageGen, canonical: "qwen-image-2.1", entry: nil))
    }

    @Test func oneBundleSupportsGenerateAndEditWithNativeDefaults() async throws {
        let f = q21()
        let generated = try await collectImageEvents(await f.service.generate(
            .init(model: f.first, prompt: "native generation"), jobID: "q21-default-gen"))
        await f.service.waitForJobDrain(jobID: "q21-default-gen")
        let source = Data([1, 2, 3])
        let edited = try await collectImageEvents(await f.service.edit(
            .init(model: f.first, prompt: "native edit", sourceImages: [source]), jobID: "q21-default-edit"))
        await f.service.waitForJobDrain(jobID: "q21-default-edit")
        let s = await f.probe.snapshot()
        #expect(s.loads == [f.first])
        let gen = try #require(s.starts.first)
        #expect(gen.steps == 40 && gen.guidance == 1 && gen.seed == nil)
        #expect(gen.width == 1024 && gen.height == 1024)
        let edit = try #require(s.edits.first)
        #expect(edit.steps == 40 && edit.guidance == 1 && edit.seed == nil)
        #expect(edit.width == nil && edit.height == nil && edit.strength == 1)
        #expect(try Data(contentsOf: edit.sourceImage) == source)
        #expect(generated.contains { if case .completed = $0 { return true }; return false })
        #expect(edited.contains { if case .completed = $0 { return true }; return false })
        try? FileManager.default.removeItem(at: edit.sourceImage)
        await f.service.unload()
    }

    @Test func explicitGenerationFieldsAreForwardedWithoutSamplerCoercion() async throws {
        let f = q21()
        _ = try await collectImageEvents(await f.service.generate(.init(model: f.first,
            prompt: "exact prompt", negativePrompt: "blur", width: 1248, height: 832,
            steps: 12, guidance: 2.5, seed: UInt64.max, outputFormat: .png), jobID: "q21-explicit"))
        await f.service.waitForJobDrain(jobID: "q21-explicit")
        let s = await f.probe.snapshot(), r = try #require(s.starts.first)
        #expect(r.prompt == "exact prompt" && r.negativePrompt == "blur")
        #expect(r.width == 1248 && r.height == 832 && r.steps == 12)
        #expect(r.guidance == 2.5 && r.seed == UInt64.max && r.outputFormat == .png)
        let invalid = try await collectImageEvents(await f.service.generate(.init(model: f.second,
            prompt: "invalid explicit steps", steps: 1), jobID: "q21-one-step"))
        await f.service.waitForJobDrain(jobID: "q21-one-step")
        let after = await f.probe.snapshot()
        #expect(invalid.contains { if case .failed = $0 { return true }; return false })
        #expect(after.starts.count == 1 && after.loads == [f.first]) // reject before replacing resident bundle
        await f.service.unload()
    }

    @Test func orderedEditSourcesAndExplicitDimensionsReachEngineUnchanged() async throws {
        let f = q21(), data = [Data([1]), Data([2]), Data([3]), Data([4])]
        _ = try await collectImageEvents(await f.service.edit(.init(model: f.first,
            prompt: "edit exact", sourceImages: data, strength: 1, width: 1248, height: 832,
            steps: 17, guidance: 2.5, seed: 7), jobID: "q21-four-refs"))
        await f.service.waitForJobDrain(jobID: "q21-four-refs")
        let s = await f.probe.snapshot(), r = try #require(s.edits.first)
        #expect(try r.sourceImages.map { try Data(contentsOf: $0) } == data)
        #expect(r.sourceImage == r.sourceImages.first && r.mask == nil && r.strength == 1)
        #expect(r.width == 1248 && r.height == 832 && r.steps == 17 && r.guidance == 2.5 && r.seed == 7)
        for url in r.sourceImages { try? FileManager.default.removeItem(at: url) }
        await f.service.unload()
    }

    @Test func invalidAndUnsupportedRequestsFailBeforeReplacingResidentBundle() async throws {
        let f = q21()
        _ = try await collectImageEvents(await f.service.generate(
            .init(model: f.first, prompt: "prime"), jobID: "q21-prime"))
        await f.service.waitForJobDrain(jobID: "q21-prime")
        let badGeneration: [ImageGenerationParameters] = [
            .init(model: f.second, prompt: "bad width", width: 1008),
            .init(model: f.second, prompt: "bad height", height: 0),
            .init(model: f.second, prompt: "negative width", width: -32),
            .init(model: f.second, prompt: "nan", guidance: .nan),
            .init(model: f.second, prompt: "infinite", guidance: .infinity),
            .init(model: f.second, prompt: "ignored negative", negativePrompt: "blur", guidance: 1),
            .init(model: f.second, prompt: "unsupported JPEG", outputFormat: .jpeg),
            .init(model: f.second, prompt: "unsupported WEBP", outputFormat: .webp),
        ]
        for (index, request) in badGeneration.enumerated() {
            let id = "q21-invalid-gen-\(index)"
            let events = try await collectImageEvents(await f.service.generate(request, jobID: id))
            await f.service.waitForJobDrain(jobID: id)
            #expect(events.contains { if case .failed = $0 { return true }; return false })
            #expect(!events.contains { if case .completed = $0 { return true }; return false })
        }
        let badEdits: [ImageEditParameters] = [
            .init(model: f.second, prompt: "negative", sourceImages: [Data()], negativePrompt: "blur"),
            .init(model: f.second, prompt: "partial strength", sourceImages: [Data()], strength: 0.75),
            .init(model: f.second, prompt: "nan strength", sourceImages: [Data()], strength: .nan),
            .init(model: f.second, prompt: "mask", sourceImages: [Data()], maskImage: Data()),
            .init(model: f.second, prompt: "zero refs", sourceImages: []),
            .init(model: f.second, prompt: "five refs", sourceImages: Array(repeating: Data(), count: 5)),
            .init(model: f.second, prompt: "unsupported JPEG", sourceImages: [Data()], outputFormat: .jpeg),
        ]
        for (index, request) in badEdits.enumerated() {
            let id = "q21-invalid-edit-\(index)"
            let events = try await collectImageEvents(await f.service.edit(request, jobID: id))
            await f.service.waitForJobDrain(jobID: id)
            #expect(events.contains { if case .failed = $0 { return true }; return false })
            #expect(!events.contains { if case .completed = $0 { return true }; return false })
        }
        let s = await f.probe.snapshot(), resident = await f.service.loadedModelSummary()
        #expect(s.loads == [f.first] && s.starts.count == 1 && s.edits.isEmpty)
        #expect(resident?.name == f.first)
        await f.service.unload()
    }

    @Test func olderGenerationAdmissionAndEditStrengthRemainCompatible() async throws {
        let gen = ImageProducerFixture(held: [], canonical: "qwen-image",
            capabilities: ImageGenerationService.capabilities(kind: .imageGen, canonical: "qwen-image", entry: nil))
        _ = try await collectImageEvents(await gen.service.generate(.init(model: gen.first,
            prompt: "old generation", width: 1008, guidance: 3.5), jobID: "old-gen"))
        await gen.service.waitForJobDrain(jobID: "old-gen")
        let rejected = try await collectImageEvents(await gen.service.edit(.init(model: gen.second,
            prompt: "wrong operation", sourceImages: [Data()]), jobID: "old-wrong-edit"))
        await gen.service.waitForJobDrain(jobID: "old-wrong-edit")
        let gs = await gen.probe.snapshot()
        #expect(gs.starts.first?.width == 1008 && gs.starts.first?.guidance == 3.5)
        #expect(gs.loads == [gen.first] && gs.edits.isEmpty)
        #expect(rejected.contains { if case .failed = $0 { return true }; return false })
        await gen.service.unload()
        let edit = ImageProducerFixture(held: [], canonical: "qwen-image-edit", kind: .imageEdit,
            capabilities: ImageGenerationService.capabilities(kind: .imageEdit, canonical: "qwen-image-edit", entry: nil))
        _ = try await collectImageEvents(await edit.service.edit(.init(model: edit.first,
            prompt: "old edit", sourceImages: [Data([9])]), jobID: "old-edit"))
        await edit.service.waitForJobDrain(jobID: "old-edit")
        let es = await edit.probe.snapshot(), r = try #require(es.edits.first)
        #expect(r.strength == 0.75 && r.width == nil && r.height == nil)
        try? FileManager.default.removeItem(at: r.sourceImage)
        await edit.service.unload()
    }

    @Test func manualTextRejectsInvalidExplicitValuesAndKeepsOmissions() throws {
        let defaults = try ImagePanelParameterInput(steps: "  ", guidance: "", seed: "\n")
        #expect(defaults.steps == nil && defaults.guidance == nil && defaults.seed == nil)
        let explicit = try ImagePanelParameterInput(steps: "1", guidance: "2.5", seed: "18446744073709551615")
        #expect(explicit.steps == 1 && explicit.guidance == 2.5 && explicit.seed == UInt64.max)
        for seed in ["-1", "1.5", "seed", "18446744073709551616"] {
            #expect(throws: ImagePanelParameterInput.InputError.self) {
                try ImagePanelParameterInput(steps: "", guidance: "", seed: seed)
            }
        }
        for guidance in ["nan", "inf", "1e100", "guidance"] {
            #expect(throws: ImagePanelParameterInput.InputError.self) {
                try ImagePanelParameterInput(steps: "", guidance: guidance, seed: "")
            }
        }
        for steps in ["0", "-1", "1.5", "steps"] {
            #expect(throws: ImagePanelParameterInput.InputError.self) {
                try ImagePanelParameterInput(steps: steps, guidance: "", seed: "")
            }
        }
    }

    @Test func httpSeedDecodingRejectsInvalidExplicitNumbers() throws {
        let decoder = JSONDecoder()
        let maxSeed = try decoder.decode(ImageGenerationRequestDTO.self,
            from: Data(#"{"prompt":"valid","seed":18446744073709551615}"#.utf8))
        #expect(maxSeed.seed == UInt64.max)
        for seed in ["-1", "1.5", "18446744073709551616", "\"seed\""] {
            let data = Data("{\"prompt\":\"invalid\",\"seed\":\(seed)}".utf8)
            #expect(throws: DecodingError.self) { try decoder.decode(ImageGenerationRequestDTO.self, from: data) }
        }
    }
}
