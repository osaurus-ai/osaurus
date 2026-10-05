import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import vMLXFlux
@testable import OsaurusCore

// Real HTTP job factory → real service/FluxEngine → tensor-free concrete model.
// This does not reconstruct parameter forwarding from policy expectations or
// claim HTTP socket, GUI, image quality, Metal, or full SubagentSession proof.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QwenImage21EndpointFidelityTests {
    private func q21() -> ImageProducerFixture {
        ImageProducerFixture(held: [], canonical: "qwen-image-2.1",
            capabilities: ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image-2.1"),
            identityStem: "renamed-installed-bundle")
    }

    private func generation(_ json: String) throws -> ImageGenerationRequestDTO {
        try JSONDecoder().decode(ImageGenerationRequestDTO.self, from: Data(json.utf8))
    }

    private func edit(_ fields: [String: Any]) throws -> ImageEditRequestDTO {
        try JSONDecoder().decode(ImageEditRequestDTO.self,
            from: JSONSerialization.data(withJSONObject: fields))
    }

    private func png(_ red: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func failed(_ events: [ImageGenerationEvent]) -> Bool {
        events.contains { if case .failed = $0 { return true }; return false }
    }

    @Test func actualHTTPFactoryPreservesWideAnd2048DimensionsOnRenamedBundle() async throws {
        let f = q21()
        #expect(!f.first.contains("qwen"))
        let request = try generation(#"{"prompt":"wide","size":"1248x832","steps":12,"guidance":2.5,"negative_prompt":"blur","seed":18446744073709551615,"output_format":"png"}"#)
        let job = await f.service.generateHTTP(request, modelID: f.first, jobID: "http-wide")
        let events = try await collectImageEvents(job.stream)
        await f.service.waitForJobDrain(jobID: "http-wide")
        let first = try #require(await f.probe.snapshot().starts.first)
        #expect(!failed(events))
        #expect(first.width == 1248 && first.height == 832 && first.steps == 12)
        #expect(first.guidance == 2.5 && first.negativePrompt == "blur" && first.seed == UInt64.max)
        #expect(first.outputFormat == .png && first.numImages == 1)
        #expect(job.activityDetails["size"] == "1248x832")
        #expect(f.log.events.filter { $0 == "resolve:\(f.first)" }.count == 1)
        let square = await f.service.generateHTTP(try generation(#"{"prompt":"square","width":2048,"height":2048,"steps":2}"#),
            modelID: f.first, jobID: "http-2048")
        _ = try await collectImageEvents(square.stream)
        await f.service.waitForJobDrain(jobID: "http-2048")
        let s = await f.probe.snapshot(), last = try #require(s.starts.last)
        #expect(last.width == 2048 && last.height == 2048 && last.steps == 2)
        #expect(last.guidance == 1 && last.seed == nil)
        #expect(square.activityDetails["size"] == "2048x2048")
        #expect(s.loads == [f.first]) // no reload or second metadata lookup per job
        #expect(f.log.events.filter { $0 == "resolve:\(f.first)" }.count == 2)
        await f.service.unload()
    }

    @Test func actualHTTPFactoryKeepsAllOrderedEditReferencesAndNativeOmissions() async throws {
        let f = q21(), sources = try [png(0.1), png(0.3), png(0.6), png(0.9)]
        let request = try edit(["prompt": "edit", "images": sources.map { $0.base64EncodedString() },
            "width": 1248, "height": 832, "steps": 17, "guidance": 2.5, "seed": 7])
        let job = await f.service.editHTTP(request, modelID: f.first,
            decodedSources: (request.images ?? []).map(HTTPHandler.decodeImageInput), jobID: "http-edit")
        let events = try await collectImageEvents(job.stream)
        await f.service.waitForJobDrain(jobID: "http-edit")
        let r = try #require(await f.probe.snapshot().edits.first)
        #expect(!failed(events))
        #expect(try r.sourceImages.map { try Data(contentsOf: $0) } == sources)
        #expect(r.width == 1248 && r.height == 832 && r.steps == 17 && r.guidance == 2.5 && r.seed == 7)
        #expect(r.strength == 1 && r.mask == nil)
        #expect(job.activityDetails["size"] == "1248x832" && job.activityDetails["source_images"] == "4")
        #expect(f.log.events.filter { $0 == "resolve:\(f.first)" }.count == 1)
        for url in r.sourceImages { try? FileManager.default.removeItem(at: url) }
        await f.service.unload()
    }

    @Test func malformedSizeCapacityOverflowAndInvalidExplicitFieldsDoNotReplaceResident() async throws {
        let f = q21()
        _ = try await collectImageEvents(await f.service.generate(.init(model: f.first, prompt: "prime"), jobID: "prime-size"))
        await f.service.waitForJobDrain(jobID: "prime-size")
        let bad = [
            #"{"prompt":"bad","size":""}"#, #"{"prompt":"bad","size":"1248"}"#,
            #"{"prompt":"bad","size":"1248x"}"#, #"{"prompt":"bad","size":"1248x832junk"}"#,
            #"{"prompt":"bad","size":"1008x1024"}"#, #"{"prompt":"bad","size":"2080x2048"}"#,
            #"{"prompt":"bad","width":0}"#, #"{"prompt":"bad","width":-32}"#,
            #"{"prompt":"bad","width":9223372036854775807}"#,
            #"{"prompt":"bad","size":"oops","width":1248,"height":832}"#,
            #"{"prompt":"bad","size":"1248x832","width":512}"#,
            #"{"prompt":"bad","size":"2048x2048","width":1248,"height":832}"#,
            #"{"prompt":"bad","steps":0}"#, #"{"prompt":"bad","steps":1}"#, #"{"prompt":"bad","steps":51}"#,
            #"{"prompt":"bad","guidance":1e100}"#,
            #"{"prompt":"bad","output_format":"jpeg"}"#,
            #"{"prompt":"bad","output_format":"webp"}"#,
            #"{"prompt":"bad","output_format":"unknown"}"#,
            #"{"prompt":"bad","negative_prompt":"blur","guidance":1}"#,
        ]
        for (index, json) in bad.enumerated() {
            let id = "bad-http-size-\(index)"
            let job = await f.service.generateHTTP(try generation(json), modelID: f.second, jobID: id)
            let events = try await collectImageEvents(job.stream)
            await f.service.waitForJobDrain(jobID: id)
            #expect(failed(events))
            #expect(!events.contains { if case .completed = $0 { return true }; return false })
        }
        let s = await f.probe.snapshot()
        #expect(s.loads == [f.first] && s.starts.count == 1 && s.edits.isEmpty)
        await f.service.unload()
    }

    @Test func partiallyMalformedOrUnsupportedEditNeverDiscardsReferenceAndRuns() async throws {
        let f = q21(), good = try png(0.5).base64EncodedString()
        _ = try await collectImageEvents(await f.service.generate(.init(model: f.first, prompt: "prime"), jobID: "prime-refs"))
        await f.service.waitForJobDrain(jobID: "prime-refs")
        let requests: [[String: Any]] = [
            ["prompt": "bad", "images": [good, "not-base64", good]],
            ["prompt": "bad", "images": [good, "", good]],
            ["prompt": "bad", "images": [good, Data([1, 2, 3]).base64EncodedString()]],
            ["prompt": "bad", "images": [good, "https://example.com/ref.png"]],
            ["prompt": "bad", "images": Array(repeating: good, count: 5)],
            ["prompt": "bad", "images": [good], "strength": 0.75],
            ["prompt": "bad", "images": [good], "strength": 1.5],
            ["prompt": "bad", "images": [good], "negative_prompt": "blur"],
            ["prompt": "bad", "images": [good], "mask": good],
            ["prompt": "bad", "images": [good], "output_format": "jpeg"],
        ]
        for (index, fields) in requests.enumerated() {
            let id = "bad-http-ref-\(index)", request = try edit(fields)
            let job = await f.service.editHTTP(request, modelID: f.second,
                decodedSources: (request.images ?? []).map(HTTPHandler.decodeImageInput), jobID: id)
            let events = try await collectImageEvents(job.stream)
            await f.service.waitForJobDrain(jobID: id)
            #expect(failed(events))
            #expect(!events.contains { if case .completed = $0 { return true }; return false })
        }
        let s = await f.probe.snapshot()
        #expect(s.loads == [f.first] && s.starts.count == 1 && s.edits.isEmpty)
        await f.service.unload()
    }

    @Test func olderHTTPPoliciesAndAdvertisedCapacityStayUnchanged() async throws {
        let f = ImageProducerFixture(held: [], canonical: "qwen-image")
        let job = await f.service.generateHTTP(try generation(#"{"prompt":"old","width":8192,"height":12,"steps":500,"guidance":99}"#),
            modelID: f.first, jobID: "old-http-gen")
        _ = try await collectImageEvents(job.stream)
        await f.service.waitForJobDrain(jobID: "old-http-gen")
        let r = try #require(await f.probe.snapshot().starts.first)
        #expect(r.width == 1024 && r.height == 256 && r.steps == 50 && r.guidance == 99)
        #expect(job.activityDetails["size"] == "1024x256")
        let one = await f.service.generateHTTP(try generation(#"{"prompt":"old floor","steps":1}"#),
            modelID: f.first, jobID: "old-one-step")
        _ = try await collectImageEvents(one.stream)
        await f.service.waitForJobDrain(jobID: "old-one-step")
        #expect(await f.probe.snapshot().starts.last?.steps == 2) // existing older-family floor
        await f.service.unload()
        let e = ImageProducerFixture(held: [], canonical: "qwen-image-edit", kind: .imageEdit)
        let fields: [String: Any] = ["prompt": "old edit", "images": [Data([1]).base64EncodedString(), "bad"],
            "width": 1008, "height": 9000, "steps": 500]
        let req = try edit(fields), old = await e.service.editHTTP(req, modelID: e.first,
            decodedSources: (req.images ?? []).map(HTTPHandler.decodeImageInput), jobID: "old-http-edit")
        _ = try await collectImageEvents(old.stream)
        await e.service.waitForJobDrain(jobID: "old-http-edit")
        let edited = try #require(await e.probe.snapshot().edits.first)
        #expect(edited.sourceImages.count == 1 && edited.strength == 0.75)
        #expect(edited.width == 1008 && edited.height == 1024 && edited.steps == 50)
        #expect(old.activityDetails["size"] == "1008x1024" && old.activityDetails["source_images"] == "1")
        for url in edited.sourceImages { try? FileManager.default.removeItem(at: url) }
        await e.service.unload()
        let info = ImageModelInfo(id: "renamed", canonicalName: "qwen-image-2.1", displayName: "renamed",
            kind: "imageGen", ready: true, quantizationBits: nil, defaultSteps: 40, defaultGuidance: 1,
            capabilities: ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image-2.1"),
            blockedReasons: [], totalBytes: 0)
        let limits = ImageHTTPParameterBuilder.limits(for: info)
        #expect(limits.max_pixels == 2048 * 2048 && limits.size_multiple == 32 && limits.min_steps == 2)
        #expect(limits.supported_sizes.contains("1248x832") && limits.supported_sizes.contains("2048x2048"))
        let oldInfo = ImageModelInfo(id: "old", canonicalName: "qwen-image", displayName: "old",
            kind: "imageGen", ready: true, quantizationBits: nil, defaultSteps: 20, defaultGuidance: 3.5,
            capabilities: ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image"),
            blockedReasons: [], totalBytes: 0)
        let oldLimits = ImageHTTPParameterBuilder.limits(for: oldInfo)
        #expect(oldLimits.max_pixels == 1024 * 1024 && oldLimits.size_multiple == 16 && oldLimits.min_steps == 1)
    }

    @Test func delegationUsesResolvedMetadataAndProductionRequestBuilder() async throws {
        let f = q21(), raw = #"{"prompt":"tool","width":2048,"height":2048,"steps":12,"guidance":23,"seed":18446744073709551615}"#
        let args = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let legacy = ImageTool.buildParams(args: args, prompt: "tool")
        #expect(legacy.guidance == 20) // prove original parser would lose value
        let kind = ImageSubagentKind(params: legacy, argumentsJSON: raw)
        try kind.prepareLocalParameters(canonical: "qwen-image-2.1", defaultGuidance: 1)
        let r = kind.localGenerateRequest(.init(name: "Renamed display", id: f.first, isLocal: true), context: .empty)
        #expect(r.model == f.first && r.width == 2048 && r.height == 2048)
        #expect(r.guidance == 23 && r.steps == 12 && r.seed == UInt64.max && r.numImages == 1)
        _ = try await collectImageEvents(await f.service.generate(.init(model: try #require(r.model), prompt: r.prompt,
            width: r.width, height: r.height, steps: r.steps, guidance: r.guidance, seed: r.seed), jobID: "tool-service"))
        await f.service.waitForJobDrain(jobID: "tool-service")
        let engine = try #require(await f.probe.snapshot().starts.first)
        #expect(engine.width == 2048 && engine.height == 2048 && engine.guidance == 23 && engine.seed == UInt64.max)
        await f.service.unload()
        let old = ImageSubagentKind(params: legacy, argumentsJSON: raw)
        try old.prepareLocalParameters(canonical: "qwen-image", defaultGuidance: 3.5)
        let oldRequest = old.localGenerateRequest(.init(name: "Old display", id: "old-id", isLocal: true), context: .empty)
        #expect(oldRequest.guidance == 20 && oldRequest.model == "Old display")
    }

    @Test func delegationRejectsMalformedAndUnsupportedExplicitQ21FieldsBeforeCoordinator() throws {
        let legacy = ImageTool.buildParams(args: ["prompt": "bad"], prompt: "bad")
        let bad = [
            #"{"width":1008}"#, #"{"height":2080}"#, #"{"width":1.5}"#,
            #"{"steps":0}"#, #"{"steps":1}"#, #"{"steps":51}"#, #"{"guidance":"nan"}"#,
            #"{"seed":-1}"#, #"{"seed":1.5}"#, #"{"seed":"not-a-seed"}"#,
            #"{"seed":18446744073709551616}"#, #"{"source_paths":[]}"#,
            #"{"source_paths":["good.png",""]}"#, #"{"source_paths":["good.png",3]}"#,
            #"{"source_paths":["a.png"],"strength":0.75}"#,
            #"{"source_paths":["a.png"],"strength":1.5}"#,
            #"{"source_paths":["a.png"],"negative_prompt":"blur"}"#,
            #"{"source_paths":["a.png"],"mask":"mask.png"}"#,
            #"{"strength":1}"#,
            #"{"output_format":"jpeg"}"#, #"{"output_format":"webp"}"#,
        ]
        for raw in bad {
            let kind = ImageSubagentKind(params: legacy, argumentsJSON: raw)
            #expect(throws: ImageGenerationError.self) {
                try kind.prepareLocalParameters(canonical: "qwen-image-2.1", defaultGuidance: 1)
            }
        }
        let raw = #"{"source_paths":["b.png","a.png"],"width":1248,"height":832,"seed":"18446744073709551615"}"#
        let p = try ImageTool.paramsForResolvedLocalModel(legacy, argumentsJSON: raw,
            canonical: "qwen-image-2.1", defaultGuidance: 1)
        #expect(p.sourcePaths == ["b.png", "a.png"] && p.width == 1248 && p.height == 832)
        #expect(p.strength == nil && p.guidance == nil && p.steps == nil && p.seed == UInt64.max)
    }
}
