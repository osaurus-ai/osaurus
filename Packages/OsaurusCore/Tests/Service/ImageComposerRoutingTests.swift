import Foundation
import Testing
@testable import OsaurusCore

struct ImageComposerRoutingTests {
    private func item(canonical: String = "qwen-image-2.1", kind: String = "imageGen", id: String = "custom-name") -> ModelPickerItem {
        ModelPickerItem.fromImageModel(ImageModelInfo(id: id, canonicalName: canonical,
            displayName: "Fixture", kind: kind, ready: true, quantizationBits: 8,
            defaultSteps: 40, defaultGuidance: 1,
            capabilities: ImageModelRequestPolicy.capabilities(kind: kind, canonical: canonical),
            blockedReasons: [], totalBytes: 0))
    }

    @Test func dualModelRoutesTextToGenerateAndReferencesToEdit() throws {
        let model = item()
        switch try ImageComposerRequestBuilder.build(item: model, prompt: "text", sourceImages: [], settings: .init()) {
        case .generate(let p):
            #expect(p.model == "custom-name" && p.prompt == "text")
            #expect(p.width == nil && p.height == nil && p.steps == nil && p.guidance == nil)
        case .edit: Issue.record("dual model routed text-only request to edit")
        }
        let references = [Data([1]), Data([2]), Data([3])]
        switch try ImageComposerRequestBuilder.build(item: model, prompt: "edit", sourceImages: references, settings: .init()) {
        case .edit(let p):
            #expect(p.sourceImages == references && p.strength == nil)
            #expect(p.width == nil && p.height == nil && p.steps == nil && p.guidance == nil)
        case .generate: Issue.record("dual model lost reference edit routing")
        }
    }

    @Test func singleOperationFamiliesKeepTheirSourceRequirements() throws {
        let gen = item(canonical: "qwen-image"), edit = item(canonical: "qwen-image-edit", kind: "imageEdit")
        #expect(throws: ImageComposerRequestBuilder.RequestError.self) {
            try ImageComposerRequestBuilder.build(item: gen, prompt: "wrong source", sourceImages: [Data()], settings: .init())
        }
        #expect(throws: ImageComposerRequestBuilder.RequestError.self) {
            try ImageComposerRequestBuilder.build(item: edit, prompt: "missing source", sourceImages: [], settings: .init())
        }
        switch try ImageComposerRequestBuilder.build(item: edit, prompt: "old edit", sourceImages: [Data()], settings: .init()) {
        case .edit(let p):
            #expect(p.strength == 0.75 && p.width == 512 && p.height == 512)
            #expect(p.steps == 20 && p.guidance == 3.5)
        case .generate: Issue.record("edit-only model routed to generate")
        }
    }

    @Test func explicitQwenValuesAreUncoercedAndUnsupportedFieldsAreRetained() throws {
        let settings = ImageComposerSettings(negativePrompt: "blur", steps: 61, guidance: 25.5,
            width: 1248, height: 832, seed: "18446744073709551615", strength: 0.75)
        switch try ImageComposerRequestBuilder.build(item: item(), prompt: "explicit", sourceImages: [Data()], settings: settings) {
        case .edit(let p):
            #expect(p.steps == 61 && p.guidance == 25.5 && p.width == 1248 && p.height == 832)
            #expect(p.seed == UInt64.max && p.strength == 0.75 && p.negativePrompt == "blur")
            #expect(throws: ImageGenerationError.self) {
                try ImageModelRequestPolicy(canonical: "qwen-image-2.1").validate(width: p.width,
                    height: p.height, isEdit: true, guidance: p.guidance ?? 1,
                    negativePrompt: p.negativePrompt, strength: p.strength, sourceCount: p.sourceImages.count)
            }
        case .generate: Issue.record("explicit edit routed to generate")
        }
    }

    @Test func nativeDefaultsRefreshOnlyUnsetSettingsAndKeepUserAssignments() throws {
        var settings = ImageComposerSettings()
        settings.applyModelDefaults(steps: 40, guidance: 1)
        #expect(settings.steps == 40 && settings.guidance == 1)
        #expect(!settings.hasExplicitSteps && !settings.hasExplicitGuidance)
        settings.applyModelDefaults(steps: 28, guidance: 0)
        #expect(settings.steps == 28 && settings.guidance == 0)
        settings.steps = 13; settings.guidance = 2.5
        settings.width = 1248; settings.height = 832; settings.strength = 0.42
        settings.applyModelDefaults(steps: 40, guidance: 1)
        #expect(settings.steps == 13 && settings.guidance == 2.5)
        #expect(settings.hasExplicitSteps && settings.hasExplicitGuidance)
        #expect(settings.hasExplicitImageSize && settings.hasExplicitStrength)
        let restored = try JSONDecoder().decode(ImageComposerSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test func legacyJSONKeepsStoredOverridesAcrossSwitchAndRoundtrip() throws {
        let data = Data(#"{"negativePrompt":"blur","steps":11,"guidance":2.5,"width":1008,"height":832,"seed":"7","strength":0.42}"#.utf8)
        var settings = try JSONDecoder().decode(ImageComposerSettings.self, from: data)
        #expect(settings.hasExplicitSteps && settings.hasExplicitGuidance)
        #expect(settings.hasExplicitImageSize && settings.hasExplicitStrength)
        settings.applyModelDefaults(steps: 40, guidance: 1)
        #expect(settings.steps == 11 && settings.guidance == 2.5)
        let restored = try JSONDecoder().decode(ImageComposerSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        switch try ImageComposerRequestBuilder.build(item: item(), prompt: "legacy", sourceImages: [Data()], settings: restored) {
        case .edit(let p):
            #expect(p.width == 1008 && p.height == 832 && p.strength == 0.42)
            #expect(p.steps == 11 && p.guidance == 2.5 && p.negativePrompt == "blur")
        case .generate: Issue.record("legacy edit lost operation")
        }
    }

    @Test func explicitDefaultNumbersDifferFromNewOmissions() throws {
        let explicit = ImageComposerSettings(steps: 20, guidance: 3.5, width: 512, height: 512, strength: 0.75)
        let defaults = ImageComposerSettings()
        #expect(explicit.hasExplicitImageSize && explicit.hasExplicitStrength)
        #expect(!defaults.hasExplicitImageSize && !defaults.hasExplicitStrength)
        let restored = try JSONDecoder().decode(ImageComposerSettings.self, from: JSONEncoder().encode(defaults))
        #expect(!restored.hasExplicitSteps && !restored.hasExplicitGuidance)
        #expect(!restored.hasExplicitImageSize && !restored.hasExplicitStrength)
        switch try ImageComposerRequestBuilder.build(item: item(), prompt: "explicit numbers", sourceImages: [Data()], settings: explicit) {
        case .edit(let p): #expect(p.width == 512 && p.height == 512 && p.strength == 0.75)
        case .generate: Issue.record("edit lost operation")
        }
    }

    @Test func controlsFollowOperationAndOnlyUserActionClearsUnsupportedOverrides() {
        let caps = item().imageCapabilities
        let gen = ImageComposerRequestBuilder.controls(capabilities: caps, fallbackKind: "imageGen", hasReferences: false)
        let edit = ImageComposerRequestBuilder.controls(capabilities: caps, fallbackKind: "imageGen", hasReferences: true)
        #expect(gen.operation == .generate && gen.negativePrompt && !gen.strength)
        #expect(edit.operation == .edit && !edit.negativePrompt && !edit.strength)
        var settings = ImageComposerSettings(negativePrompt: "blur", strength: 0.75)
        #expect(ImageComposerRequestBuilder.hasUnsupportedEditOverrides(controls: edit, settings: settings))
        settings.strengthWasExplicitlySet = false; settings.negativePrompt = ""
        #expect(!ImageComposerRequestBuilder.hasUnsupportedEditOverrides(controls: edit, settings: settings))
    }

    @Test func invalidSeedAndMissingReferenceAreNotReinterpreted() {
        #expect(throws: ImageComposerRequestBuilder.RequestError.self) {
            try ImageComposerRequestBuilder.build(item: item(), prompt: "invalid seed", sourceImages: [], settings: .init(seed: "-1"))
        }
        #expect(throws: ImageComposerRequestBuilder.RequestError.self) {
            try ImageComposerRequestBuilder.build(item: item(), prompt: "missing reference", sourceImages: [],
                expectedSourceCount: 1, settings: .init())
        }
    }

    @Test func chatBuilderRequestsReachRealServiceWithNativeDefaults() async throws {
        let caps = ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image-2.1")
        let f = ImageProducerFixture(held: [], canonical: "qwen-image-2.1", capabilities: caps)
        let model = item(id: f.first)
        let gen = try ImageComposerRequestBuilder.build(item: model, prompt: "native gen", sourceImages: [], settings: .init())
        guard case .generate(let gp) = gen else { Issue.record("expected generate"); return }
        _ = try await collectImageEvents(await f.service.generate(gp, jobID: "chat-gen"))
        await f.service.waitForJobDrain(jobID: "chat-gen")
        let edit = try ImageComposerRequestBuilder.build(item: model, prompt: "native edit",
            sourceImages: [Data([1]), Data([2])], expectedSourceCount: 2, settings: .init())
        guard case .edit(let ep) = edit else { Issue.record("expected edit"); return }
        _ = try await collectImageEvents(await f.service.edit(ep, jobID: "chat-edit"))
        await f.service.waitForJobDrain(jobID: "chat-edit")
        let s = await f.probe.snapshot(), g = try #require(s.starts.first), e = try #require(s.edits.first)
        #expect(g.steps == 40 && g.guidance == 1 && g.width == 1024 && g.height == 1024)
        #expect(e.steps == 40 && e.guidance == 1 && e.width == nil && e.height == nil && e.strength == 1)
        #expect(try e.sourceImages.map { try Data(contentsOf: $0) } == [Data([1]), Data([2])])
        for url in e.sourceImages { try? FileManager.default.removeItem(at: url) }
        await f.service.unload()
    }
}
