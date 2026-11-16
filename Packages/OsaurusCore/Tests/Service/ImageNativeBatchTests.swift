import Foundation
import Testing
import vMLXFlux
@testable import OsaurusCore

@Suite(.serialized)
struct ImageNativeBatchTests {
    private var limits: FluxModelLimits {
        .init(dimensionMultiple: 32, minDimension: 32, minimumSteps: 2,
            supportsNegativePrompt: true, supportsEditNegativePrompt: false,
            supportsStrength: false, supportsMask: false, maxSourceImages: 10,
            supportedFormats: [.png], maximumImages: 8, maximumParallelImages: 1)
    }

    @Test func nativeBatchUsesOneProducerAndReportsOrderedResults() async throws {
        let fixture = ImageProducerFixture(held: [], limits: limits)
        let seeds: [UInt64] = [7, UInt64.max, 7, 0]
        let events = try await collectImageEvents(await fixture.service.generate(
            .init(model: fixture.first, prompt: "batch", numImages: 4, seeds: seeds, batchSize: 4), jobID: "native-batch"))
        await fixture.service.waitForJobDrain(jobID: "native-batch")
        let state = await fixture.probe.snapshot()
        #expect(state.starts.count == 1)
        #expect(state.starts.first?.numImages == 4)
        #expect(state.starts.first?.seeds == seeds)
        #expect(state.maximumActive == 1 && state.active == 0)
        let partial = events.compactMap { event -> UInt64? in
            if case .imageCompleted(let image, _) = event { return image.seed }
            return nil
        }
        #expect(partial == seeds)
        let finals = events.compactMap { event -> [UInt64]? in
            if case .completed(let images) = event { return images.map(\.seed) }
            return nil
        }
        #expect(finals == [seeds])
        await fixture.service.unload()
    }

    @Test func malformedSeedsFailBeforeLoadingAndDoNotIndexEmptyArray() async throws {
        let fixture = ImageProducerFixture(held: [], limits: limits)
        let events = try await collectImageEvents(await fixture.service.generate(
            .init(model: fixture.first, prompt: "invalid", numImages: 4, seeds: []), jobID: "invalid-batch"))
        await fixture.service.waitForJobDrain(jobID: "invalid-batch")
        let state = await fixture.probe.snapshot()
        #expect(state.loads.isEmpty && state.starts.isEmpty)
        #expect(events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func laterImageFailureKeepsReportedImageWithoutFalseCancellationOrCompletion() async throws {
        let fixture = ImageProducerFixture(held: [], limits: limits, failAfterImages: 1)
        let events = try await collectImageEvents(await fixture.service.generate(
            .init(model: fixture.first, prompt: "batch", seed: 7, numImages: 4), jobID: "batch-failure"))
        await fixture.service.waitForJobDrain(jobID: "batch-failure")
        let partial = events.compactMap { event -> UInt64? in
            if case .imageCompleted(let image, _) = event { return image.seed }
            return nil
        }
        #expect(partial == [7])
        #expect(events.filter { if case .failed = $0 { return true }; return false }.count == 1)
        #expect(!events.contains { if case .cancelled = $0 { return true }; return false })
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
        #expect(await fixture.probe.snapshot().active == 0)
        await fixture.service.unload()
    }

    @Test func localHTTPKeepsRequestedBatchFields() throws {
        let request = try JSONDecoder().decode(ImageGenerationRequestDTO.self,
            from: Data(#"{"prompt":"cube","n":4,"seeds":[7,8,9,10],"batch_size":2}"#.utf8))
        let info = ImageModelInfo(id: "renamed", canonicalName: "qwen-image-2.1-turbo",
            displayName: "fixture", kind: "imageGen", ready: true, quantizationBits: 4,
            defaultSteps: 8, defaultGuidance: 1, capabilities: .init(textToImage: true), blockedReasons: [], totalBytes: 0)
        let parameters = try ImageHTTPParameterBuilder.generation(request, info: info)
        #expect(parameters.numImages == 4 && parameters.seeds == [7, 8, 9, 10] && parameters.batchSize == 2)
    }

    @Test func remoteBatchFieldsAreRejectedRatherThanSilentlyIgnored() throws {
        for json in [#"{"prompt":"cube","seeds":[7]}"#, #"{"prompt":"cube","batch_size":1}"#] {
            let request = try JSONDecoder().decode(ImageGenerationRequestDTO.self, from: Data(json.utf8))
            #expect(throws: ImageGenerationError.self) {
                try ImageHTTPParameterBuilder.validateRemoteBatch(request)
            }
        }
        let ordinary = try JSONDecoder().decode(ImageGenerationRequestDTO.self,
            from: Data(#"{"prompt":"cube","n":4,"seed":7}"#.utf8))
        try ImageHTTPParameterBuilder.validateRemoteBatch(ordinary)
    }
}
