//
//  MediaNodeExecutorTests.swift
//  OsaurusCoreTests
//
//  Media steps through the real runner against a fake image runtime:
//  one job per batch with a seed per image, a failed batch keeping its
//  finished images, sampler/scheduler/shift and previews, memory admission,
//  seed modes and input overrides, generate -> edit -> upscale chaining
//  through saved files, map seed sweeps, the files and settings each image
//  keeps, Qwen-Image 2.1 rules refused before a job starts, missing models,
//  local Wan video, and provider jobs that need approval.
//

import Foundation
import Testing

@testable import OsaurusCore

/// What the fake runtime was asked to do.
actor MediaJobLog {
    private(set) var generates: [NativeImageGenerateJobRequest] = []
    private(set) var edits: [NativeImageEditJobRequest] = []
    private(set) var upscales: [NativeImageUpscaleJobRequest] = []
    private(set) var remoteImages: [MediaImageGenerationRequest] = []
    private(set) var videos: [MediaVideoGenerationRequest] = []
    private(set) var localVideos: [MediaVideoGenerationRequest] = []
    func recordLocal(_ r: MediaVideoGenerationRequest) { localVideos.append(r) }
    private(set) var approvals: [(tool: String, arguments: String)] = []
    private var running = 0
    private(set) var peakRunning = 0

    func enter() {
        running += 1
        peakRunning = max(peakRunning, running)
    }
    func leave() { running -= 1 }

    func record(_ r: NativeImageGenerateJobRequest) { generates.append(r) }
    func record(_ r: NativeImageEditJobRequest) { edits.append(r) }
    func record(_ r: NativeImageUpscaleJobRequest) { upscales.append(r) }
    func record(_ r: MediaImageGenerationRequest) { remoteImages.append(r) }
    func record(_ r: MediaVideoGenerationRequest) { videos.append(r) }
    func approval(_ tool: String, _ arguments: String) { approvals.append((tool, arguments)) }
}

/// The interrupt token a fake job was handed.
actor TokenBox {
    private(set) var token: InterruptToken?
    func set(_ token: InterruptToken) { self.token = token }
}

@Suite(.serialized)
struct MediaNodeExecutorTests {

    static let qwen = MediaFixtures.local("qwen-image-2.1-8bit", edit: true)
    static let esrgan = MediaFixtures.local("esrgan-x4", family: "real-esrgan", generate: false, upscale: true)
    /// The engine's published limits for these families at vmlx-swift f3586f93.
    static let turbo: MediaModelCandidate = {
        var c = MediaFixtures.local("qwen-image-2.1-turbo-4bit", family: "qwen-image-2.1-turbo", edit: true)
        c.limits = ImageRequestLimits(
            minimumSteps: 2, fixedSteps: 8, dimensionMultiple: 32, minimumDimension: 32, maximumImages: 8,
            maximumSourceImages: 10, formats: ["png"], samplers: ["euler"], schedulers: ["bundle-sigmas"],
            defaultSampler: "euler", defaultScheduler: "bundle-sigmas", supportsNegativePrompt: true)
        return c
    }()
    static let q21: MediaModelCandidate = {
        var c = MediaFixtures.local("qwen-image-2.1-8bit", family: "qwen-image-2.1", edit: true)
        c.limits = ImageRequestLimits(
            minimumSteps: 2, dimensionMultiple: 32, minimumDimension: 32, maximumImages: 8, maximumSourceImages: 10,
            formats: ["png"], samplers: ["euler", "heun"], schedulers: ["qwen-image-2.1", "linear"],
            defaultSampler: "euler", defaultScheduler: "qwen-image-2.1", supportsShift: true,
            supportsNegativePrompt: true)
        return c
    }()
    static let seedvr2: MediaModelCandidate = {
        var c = MediaFixtures.local("SeedVR2-3B-mlx-int8", family: "seedvr2", generate: false, upscale: true)
        c.limits = ImageRequestLimits(
            minimumSteps: 1, maximumSteps: 1, fixedSteps: 1, dimensionMultiple: 2, minimumDimension: 2,
            maximumPixels: 4096 * 4096, maximumSourceImages: 1, formats: ["png"])
        return c
    }()

    static func runtime(
        _ log: MediaJobLog, candidates: [MediaModelCandidate], approve: MediaRemoteApproval = .approved,
        jobSeconds: Double = 0
    ) -> MediaNodeRuntime
    {
        let dir = WF.tempDir()
        @Sendable func image(_ seed: UInt64, _ width: Int?, _ height: Int?) throws -> GeneratedImage {
            let url = dir.appendingPathComponent("raw-\(UUID().uuidString).png")
            try MediaFixtures.writePNG(url, width: width ?? 64, height: height ?? 64)
            return GeneratedImage(url: url, seed: seed)
        }
        @Sendable func result(_ images: [GeneratedImage]) -> NativeImageJobResult {
            NativeImageJobResult(
                jobID: "job", model: "fake", images: images, unloadedAfterJob: false, unloadedChatModels: [],
                restoredChatModels: [])
        }
        return MediaNodeRuntime(
            candidates: { candidates },
            preferredModel: { _ in nil },
            generateLocal: { request, _ in
                await log.record(request)
                await log.enter()
                if jobSeconds > 0 { try? await Task.sleep(for: .seconds(jobSeconds)) }
                await log.leave()
                let seed = request.seed ?? 0
                return result(
                    try (0 ..< request.numImages).map {
                        try image(request.seeds?[$0] ?? seed &+ UInt64($0), request.width, request.height)
                    })
            },
            editLocal: { request, _ in
                await log.record(request)
                return result([try image(request.seed ?? 0, request.width, request.height)])
            },
            upscaleLocal: { request, _ in
                await log.record(request)
                return result([try image(request.seed ?? 0, 128, 128)])
            },
            generateLocalVideo: { request, _, _, progress in
                await log.recordLocal(request)
                await log.enter()
                if jobSeconds > 0 { try? await Task.sleep(for: .seconds(jobSeconds)) }
                await log.leave()
                progress(.running(progress: 0.5, etaSeconds: 2))
                let url = dir.appendingPathComponent("wan-\(UUID().uuidString).mp4")
                try Data("frames".utf8).write(to: url)
                let policy = try LocalVideoRequestPolicy(request)
                return GeneratedMedia(
                    url: url, mimeType: "video/mp4", modelID: request.target.modelID, kind: .textToVideo,
                    effectiveVideo: VideoEffectiveParameters(
                        width: policy.width, height: policy.height, frameCount: policy.frames, fps: policy.fps,
                        steps: policy.steps, guidance: policy.guidance, seed: request.seed ?? 0))
            },
            generateRemoteImage: { request in
                await log.record(request)
                let url = dir.appendingPathComponent("remote-\(UUID().uuidString).png")
                try MediaFixtures.writePNG(url)
                return [
                    GeneratedMedia(
                        url: url, mimeType: "image/png", modelID: request.target.modelID, kind: .image,
                        settledCostUSD: 0.04)
                ]
            },
            quoteVideo: { _ in MediaVideoQuote(usd: 0.5) },
            generateVideo: { request, _, progress in
                await log.record(request)
                progress(.running(progress: 0.5, etaSeconds: 3))
                let url = dir.appendingPathComponent("clip-\(UUID().uuidString).mp4")
                try Data("not really a movie".utf8).write(to: url)
                return GeneratedMedia(url: url, mimeType: "video/mp4", modelID: request.target.modelID, kind: .textToVideo)
            },
            approveRemote: { tool, _, arguments in
                await log.approval(tool, arguments)
                return approve
            })
    }

    static let executor = ClosureExecutor { ctx, _ in
        guard case .media(let spec) = ctx.node.kind else { return WorkflowNodeOutcome(output: ctx.input) }
        return try await MediaNodeExecutor.run(spec: spec, context: ctx)
    }

    static func run(
        _ def: WorkflowDefinition, input: JSONValue = .object(["subject": .string("fox")]),
        workspace: URL = WF.tempDir(), runtime: MediaNodeRuntime
    ) async -> WorkflowRun {
        MediaNodeExecutor.runtime = runtime
        defer { MediaNodeExecutor.runtime = .live }
        return await runner(def, input: input, workspace: workspace).execute()
    }

    static func runner(
        _ def: WorkflowDefinition, input: JSONValue = .object(["subject": .string("fox")]),
        workspace: URL = WF.tempDir()
    ) -> WorkflowRunner {
        let template = WF.template(def)
        return WorkflowRunner(
            request: WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template, caller: WorkflowCaller(kind: .user),
                input: input, workspace: workspace),
            executor: executor)
    }

    static func one(_ spec: MediaSpec, input: WorkflowBinding = .object([:])) -> WorkflowDefinition {
        MediaFixtures.definition(
            [MediaFixtures.media("gen", spec, input: input)],
            input: WF.object(["subject": WF.string, "seed": WF.number]))
    }

    // MARK: - Local generate

    @Test
    func generate_oneJobMakesEveryImageWithItsOwnSeed() async throws {
        let log = MediaJobLog()
        let spec = MediaSpec(
            model: MediaModelSelector(family: "qwen-image-2.1"), prompt: "a {{input.subject}}", width: .value(64),
            height: .value(64), steps: .value(8), seed: .value(100), count: .value(6))
        let run = await Self.run(Self.one(spec), runtime: Self.runtime(log, candidates: [Self.qwen]))

        #expect(run.status == .completed)
        let jobs = await log.generates
        #expect(jobs.map(\.numImages) == [6])
        #expect(jobs.first?.seeds == (100 ... 105).map { UInt64($0) })
        #expect(jobs.first?.context.returnsPartialImages == true)
        #expect(jobs.allSatisfy { $0.prompt == "a fox" && $0.model == "qwen-image-2.1-8bit" && $0.steps == 8 })
        #expect(jobs.first?.context.trigger == .workflow)

        let files = run.artifacts.filter { $0.nodeID == "gen" }
        #expect(files.count == 6)
        #expect(files.allSatisfy { $0.source == .generated && $0.isImage && $0.isAvailable })
        #expect(files.compactMap { $0.metadata?["seed"] } == (100 ... 105).map { .number(Double($0)) })
        #expect(files.first?.metadata?["model_id"] == .string("qwen-image-2.1-8bit"))
        #expect(files.first?.metadata?["prompt"] == .string("a fox"))

        let output = try #require(run.node("gen")?.output)
        #expect(output.value(atPath: "count") == .number(6))
        #expect(output.value(atPath: "backend") == .string("local"))
        #expect(output.value(atPath: "images.0.seed") == .number(100))
        #expect(output.value(atPath: "images.0.width") == .number(64))
        #expect(output.value(atPath: "images.0.format") == .string("png"))
        #expect(output.value(atPath: "images.5.path") == .string(files[5].path))

        let stored = try #require(MediaNodeExecutor.readPNGSettings(URL(fileURLWithPath: files[0].path)))
        #expect(stored["prompt"] == .string("a fox"))
        #expect(stored["seed"] == .number(100))
        #expect(stored["width"] == .number(64))
        #expect(WorkflowMediaGalleryModel.thumbnails(run)["gen"] != nil)
    }

    @Test
    func seed_inputOverrideFixesTheSeedAndRandomVaries() async {
        let log = MediaJobLog()
        let runtime = Self.runtime(log, candidates: [Self.qwen])
        let overridden = Self.one(
            MediaSpec(prompt: "a {{input.subject}}", width: .value(64), height: .value(64)),
            input: .object(["seed": "{{input.seed}}", "prompt": "a {{input.subject}} at dusk"]))
        let run = await Self.run(
            overridden, input: .object(["subject": .string("fox"), "seed": .number(7)]), runtime: runtime)
        #expect(run.status == .completed)
        #expect(await log.generates.first?.seed == 7)
        #expect(await log.generates.first?.prompt == "a fox at dusk")

        let random = Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64)))
        _ = await Self.run(random, runtime: runtime)
        _ = await Self.run(random, runtime: runtime)
        let seeds = await log.generates.dropFirst().compactMap(\.seed)
        #expect(seeds.count == 2)
        #expect(Set(seeds).count == 2)
    }

    @Test
    func sweep_mapStepsTheSeedPerItem() async throws {
        let log = MediaJobLog()
        let step: JSONValue = .object([
            "name": .string("Look"), "kind": .string("media"),
            "media": .object([
                "prompt": .string("a fox, {{item}}"), "seed": .number(10), "seed_mode": .string("increment"),
                "width": .number(64), "height": .number(64),
            ]),
        ])
        let def = MediaFixtures.definition(
            [WorkflowNode(id: "sweep", name: "Sweep", kind: .map(MapSpec(items: "{{input.styles}}", step: step)))],
            input: WF.object(["styles": .object(["type": .string("array"), "items": WF.string])]))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        let run = await Self.run(
            def, input: .object(["styles": .array([.string("ink"), .string("oil"), .string("neon")])]),
            runtime: Self.runtime(log, candidates: [Self.qwen], jobSeconds: 0.05))

        #expect(run.status == .completed)
        #expect(await log.peakRunning == 1)
        #expect(run.nodes.first { $0.nodeID == "sweep" }?.logs.contains { $0.contains("one at a time") } == true)
        let jobs = await log.generates
        #expect(jobs.map(\.seed) == [10, 11, 12])
        #expect(jobs.map(\.prompt) == ["a fox, ink", "a fox, oil", "a fox, neon"])
        let files = run.artifacts.filter { $0.nodeID == "sweep" }
        #expect(files.count == 3)
        #expect(Set(files.compactMap { $0.metadata?["item_index"]?.numberValue }) == [0, 1, 2])
    }

    @Test
    func lane_twoRunsAtOnceTakeTurnsOnTheGPU() async {
        let log = MediaJobLog()
        let spec = MediaSpec(
            model: MediaModelSelector(family: "qwen-image-2.1"), prompt: "a {{input.subject}}", width: .value(64),
            height: .value(64))
        MediaNodeExecutor.runtime = Self.runtime(log, candidates: [Self.qwen], jobSeconds: 0.1)
        defer { MediaNodeExecutor.runtime = .live }
        async let first = Self.runner(Self.one(spec)).execute()
        async let second = Self.runner(Self.one(spec)).execute()
        let runs = await [first, second]

        #expect(runs.allSatisfy { $0.status == .completed })
        #expect(await log.generates.count == 2)
        #expect(await log.peakRunning == 1)
    }

    @Test
    func mapConcurrency_isOneOnlyForARunningMediaBody() {
        let spec = MapSpec(items: "{{input.styles}}", step: .object([:]), concurrency: 4)
        let media = WorkflowNode(id: "m", name: "M", kind: .media(MediaSpec(prompt: "x")))
        var bypassed = media
        bypassed.mode = .bypass
        let http = WorkflowNode(id: "h", name: "H", kind: .http(HTTPSpec(method: "get", url: "https://example.com")))
        #expect(spec.effectiveConcurrency(body: media) == 1)
        #expect(spec.effectiveConcurrency(body: bypassed) == 4)
        #expect(spec.effectiveConcurrency(body: http) == 4)
    }

    // MARK: - Chaining

    @Test
    func chain_generateEditUpscaleFeedsEachStepTheLastOnesFile() async throws {
        let log = MediaJobLog()
        let def = MediaFixtures.definition(
            [
                MediaFixtures.media(
                    "gen", MediaSpec(prompt: "a {{input.subject}}", width: .value(64), height: .value(64), seed: .value(3))),
                MediaFixtures.media("edit", MediaSpec(action: .edit, prompt: "make it night", sources: ["{{nodes.gen.output.images}}"])),
                MediaFixtures.media("up", MediaSpec(action: .upscale, sources: ["{{nodes.edit.output.images.0.path}}"], scale: .value(2))),
            ],
            edges: [WorkflowEdge(from: "gen", to: "edit"), WorkflowEdge(from: "edit", to: "up")],
            output: .object(["final": "{{nodes.up.output.images.0.path}}"]))
        let run = await Self.run(def, runtime: Self.runtime(log, candidates: [Self.qwen, Self.esrgan]))

        #expect(run.status == .completed)
        let edit = try #require(await log.edits.first)
        #expect(edit.sourceImages.count == 1)
        #expect(edit.prompt == "make it night")
        #expect(edit.strength == nil)
        let up = try #require(await log.upscales.first)
        #expect(up.model == "esrgan-x4")
        #expect(up.scale == 2)
        #expect(run.artifacts.compactMap(\.nodeID) == ["gen", "edit", "up"])
        let final = try #require(run.output?.value(atPath: "final")?.stringValue)
        #expect(FileManager.default.fileExists(atPath: final))
        #expect(run.node("up")?.output?.value(atPath: "images.0.width") == .number(128))
    }

    // MARK: - Refusals

    @Test
    func qwen21_rulesFailTheStepBeforeAnyJob() async {
        let log = MediaJobLog()
        let run = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64), format: .jpeg)),
            runtime: Self.runtime(log, candidates: [Self.qwen]))
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("PNG output only") == true)
        #expect(await log.generates.isEmpty)
    }

    @Test
    func missingModel_saysWhatToInstall() async {
        let log = MediaJobLog()
        let def = MediaFixtures.definition(
            [MediaFixtures.media("up", MediaSpec(action: .upscale, sources: ["{{input.subject}}"]))])
        let run = await Self.run(def, runtime: Self.runtime(log, candidates: [Self.qwen]))
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("No image upscaling model is installed") == true)
    }

    @Test
    func upscale_refusesAScaleOverrideOtherThanTwoOrFour() async throws {
        let log = MediaJobLog()
        let photo = try MediaFixtures.writePNG(WF.tempDir().appendingPathComponent("photo.png"))
        let def = MediaFixtures.definition(
            [
                MediaFixtures.media(
                    "up", MediaSpec(action: .upscale, sources: ["{{input.subject}}"]),
                    input: .object(["scale": "{{input.seed}}"]))
            ],
            input: WF.object(["subject": WF.string, "seed": WF.number]))
        let run = await Self.run(
            def, input: .object(["subject": .string(photo.path), "seed": .number(3)]),
            runtime: Self.runtime(log, candidates: [Self.esrgan]))
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("must be 2 or 4") == true)
        #expect(await log.upscales.isEmpty)
    }

    // MARK: - Engine contract (vmlx-flux-media-requests 1.1, 1.3, 1.4)

    /// Stopping a run while an upscale is on the GPU fires the token the job
    /// was handed, the step ends cancelled with no file, and the lane frees
    /// once the job's stream ends.
    @Test
    func upscale_stopReachesTheRunningJobAndTheLaneFrees() async throws {
        let log = MediaJobLog()
        let handed = TokenBox()
        let workspace = WF.tempDir()
        let photo = try MediaFixtures.writePNG(workspace.appendingPathComponent("photo.png"))
        var runtime = Self.runtime(log, candidates: [Self.seedvr2])
        runtime.upscaleLocal = { request, interrupt in
            await log.record(request)
            await handed.set(interrupt)
            while !interrupt.isInterrupted { try? await Task.sleep(for: .milliseconds(10)) }
            throw NativeImageJobCoordinatorError.cancelled
        }
        let def = MediaFixtures.definition(
            [MediaFixtures.media("up", MediaSpec(action: .upscale, sources: ["{{input.subject}}"], scale: .value(4)))])
        MediaNodeExecutor.runtime = runtime
        defer { MediaNodeExecutor.runtime = .live }
        let runner = Self.runner(def, input: .object(["subject": .string(photo.path)]), workspace: workspace)
        let task = Task { await runner.execute() }
        let deadline = Date().addingTimeInterval(5)
        while await log.upscales.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await log.upscales.first?.scale == 4)
        task.cancel()
        let run = await task.value

        #expect(run.status == .cancelled)
        #expect(await handed.token?.isInterrupted == true)
        #expect(run.artifacts.isEmpty)
        #expect(try await MediaJobLane.shared.run { 1 } == 1)
    }

    @Test
    func limits_refuseAnOffGridRequestNamingTheFieldBeforeAnyJob() async throws {
        let log = MediaJobLog()
        let run = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(1000), height: .value(1024))),
            runtime: Self.runtime(log, candidates: [Self.turbo]))
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("refuses `width` = 1000") == true)
        #expect(run.error?.reason.contains("multiples of 32") == true)
        #expect(await log.generates.isEmpty)

        let workspace = WF.tempDir()
        let photo = try MediaFixtures.writePNG(workspace.appendingPathComponent("photo.png"))
        let up = MediaFixtures.definition(
            [MediaFixtures.media("up", MediaSpec(action: .upscale, sources: ["{{input.subject}}"], format: .jpeg))])
        let refused = await Self.run(
            up, input: .object(["subject": .string(photo.path)]), workspace: workspace,
            runtime: Self.runtime(log, candidates: [Self.seedvr2]))
        #expect(refused.status == .failed)
        #expect(refused.error?.reason.contains("refuses `format` = jpeg") == true, "\(refused.error?.reason ?? "")")
        #expect(await log.upscales.isEmpty)

        #expect(throws: ImageRequestFieldError(field: "width", value: "1000", allowed: "multiples of 32, minimum 32")) {
            try Self.turbo.limits?.validateGenerate(
                width: 1000, height: 1024, steps: 8, guidance: 1, negativePrompt: nil, format: .png)
        }
    }

    /// Turbo runs its bundle's 8-step schedule whatever the step asks for:
    /// the file, the run record and the output say 8, keep the 20 that was
    /// asked for beside it, and "reuse settings" makes what ran.
    @Test
    func effective_recordsWhatRanAndKeepsWhatWasAskedFor() async throws {
        let log = MediaJobLog()
        let dir = WF.tempDir()
        var runtime = Self.runtime(log, candidates: [Self.turbo])
        runtime.generateLocal = { request, _ in
            await log.record(request)
            let images = try (0 ..< request.numImages).map { index -> GeneratedImage in
                let seed = (request.seed ?? 0) &+ UInt64(index)
                let url = try MediaFixtures.writePNG(dir.appendingPathComponent("raw-\(UUID().uuidString).png"))
                return GeneratedImage(
                    url: url, seed: seed,
                    effectiveParameters: ImageEffectiveParameters(
                        width: 64, height: 64, steps: 8, guidance: 1, seed: seed, sampleSigmas: [1, 0.5]))
            }
            return NativeImageJobResult(
                jobID: "job", model: "fake", images: images, unloadedAfterJob: false, unloadedChatModels: [],
                restoredChatModels: [])
        }
        let spec = MediaSpec(
            prompt: "a {{input.subject}}", width: .value(64), height: .value(64), steps: .value(20), guidance: .value(4),
            seed: .value(5))
        let run = await Self.run(Self.one(spec), runtime: runtime)

        #expect(run.status == .completed)
        #expect(await log.generates.first?.steps == 20)
        #expect(run.node("gen")?.logs.contains { $0.contains("ran 8 steps; the step asked for 20") } == true)
        let file = try #require(run.artifacts.first)
        let metadata = try #require(file.metadata)
        #expect(metadata["parameters"] == .string("effective"))
        #expect(metadata["steps"] == .number(8))
        #expect(metadata["requested_steps"] == .number(20))
        #expect(metadata["guidance"] == .number(1))
        #expect(metadata["requested_guidance"] == .number(4))
        #expect(metadata["requested_width"] == nil)
        #expect(metadata["sample_sigmas"] == .array([.number(1), .number(0.5)]))

        let stored = try #require(MediaNodeExecutor.readPNGSettings(URL(fileURLWithPath: file.path)))
        #expect(stored["steps"] == .number(8))
        let output = try #require(run.node("gen")?.output)
        #expect(output.value(atPath: "images.0.effective_parameters.steps") == .number(8))
        #expect(output.value(atPath: "images.0.effective_parameters.seed") == .number(5))
        #expect(output.value(atPath: "images.0.effective_parameters.sampleSigmas.1") == .number(0.5))

        #expect(WorkflowMediaGalleryModel.reusableSpec(metadata)?.steps == .value(8))
        let lines = WorkflowMediaGalleryModel.settingsLines(metadata)
        #expect(lines.contains { $0.label == "Steps" && $0.value == "8 (asked for 20)" })
    }

    @Test
    func requested_isLabeledWhenTheEngineDoesNotReport() async throws {
        let log = MediaJobLog()
        let run = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64), steps: .value(12))),
            runtime: Self.runtime(log, candidates: [Self.qwen]))
        let metadata = try #require(run.artifacts.first?.metadata)
        #expect(metadata["parameters"] == .string("requested"))
        #expect(metadata["steps"] == .number(12))
        #expect(run.node("gen")?.output?.value(atPath: "images.0.effective_parameters") == nil)
    }

    @MainActor
    @Test
    func limits_driveTheArchitectSummaryAndTheEditor() {
        let summary = Self.turbo.constraintsSummary
        #expect(summary["fixed_steps"] == .number(8))
        #expect(summary["max_dimension"] == .number(2048))
        #expect(summary["max_steps"] == .number(50))
        #expect(summary["max_sources"] == .number(Double(MediaSpec.maximumSources)))
        #expect(summary["formats"] == .array([.string("png")]))
        #expect(summary["edit_strength"] == .bool(false))
        #expect(Self.seedvr2.constraintsSummary["max_pixels"] == .number(Double(4096 * 4096)))
        #expect(Self.seedvr2.constraintsSummary["max_dimension"] == nil)

        #expect(Self.turbo.sizeFix(1000) == 992)
        #expect(Self.turbo.sizeFix(4096) == 2048)
        #expect(Self.turbo.sizeFix(1024) == nil)
        let warning = MediaStepEditor.sizeWarning(width: 1000, height: 1024, model: Self.turbo, selectsQwen21: false)
        #expect(warning?.contains("Try 992") == true)
        #expect(MediaStepEditor.sizeWarning(width: 1024, height: 768, model: Self.turbo, selectsQwen21: false) == nil)
        #expect(MediaStepEditor.sizeWarning(width: 1000, height: nil, model: nil, selectsQwen21: true)?.contains("Try 992") == true)
        #expect(MediaStepEditor.formats(Self.turbo) == [.png])
        #expect(MediaStepEditor.formats(Self.esrgan) == ImageOutputFormat.allCases)
        #expect(!MediaStepEditor.takesNegativePrompt(Self.turbo, action: .edit))
        #expect(MediaStepEditor.takesNegativePrompt(Self.turbo, action: .generate))
        #expect(MediaStepEditor.describe(Self.turbo).contains("a fixed 8-step schedule"))
        #expect(!MediaStepEditor.describe(Self.seedvr2).contains("sizes in steps"))
    }

    @MainActor
    @Test
    func editorWarnsWhenTheModelRefusesTheSampling() {
        let base = MediaSpec(prompt: "x", sampler: "heun", scheduler: "linear", shift: .value(3))
        #expect(MediaStepEditor.samplingWarning(base, model: Self.q21) == nil)
        let warning = MediaStepEditor.samplingWarning(base, model: Self.turbo)
        #expect(warning?.contains("`sampler` = heun") == true, "\(warning ?? "")")
        #expect(warning?.contains("euler") == true)
        let bound = MediaSpec(prompt: "x", sampler: "{{input.sampler}}")
        #expect(MediaStepEditor.samplingWarning(bound, model: Self.turbo) == nil)
    }

    // MARK: - Provider jobs

    @Test
    func remoteImage_asksFirstAndRunsOnlyWhenApproved() async throws {
        let remote = MediaFixtures.remote("flux-pro")
        let spec = MediaSpec(model: MediaModelSelector(locality: .remote), prompt: "a {{input.subject}}", count: .value(2))

        let denied = MediaJobLog()
        let refused = await Self.run(Self.one(spec), runtime: Self.runtime(denied, candidates: [Self.qwen, remote], approve: .denied))
        #expect(refused.status == .failed)
        #expect(refused.error?.reason.contains("not approved") == true)
        #expect(await denied.remoteImages.isEmpty)
        let asked = try #require(await denied.approvals.first)
        #expect(asked.tool == "image")
        #expect(asked.arguments.contains("\"count\":2"))
        #expect(asked.arguments.contains("\"prompt\":\"a fox\""))

        let approved = MediaJobLog()
        let run = await Self.run(Self.one(spec), runtime: Self.runtime(approved, candidates: [Self.qwen, remote]))
        #expect(run.status == .completed)
        #expect(await approved.remoteImages.first?.count == 2)
        #expect(run.node("gen")?.output?.value(atPath: "backend") == .string("remote"))
        #expect(run.artifacts.first?.metadata?["backend"] == .string("remote"))
        #expect(run.node("gen")?.logs.contains { $0.contains("Provider charged") } == true)
    }

    /// The job's own copy in generated-images goes once the run has its
    /// copy; a file the step was handed stays.
    @Test
    func save_dropsOnlyTheJobsOwnOriginal() throws {
        let folder = OsaurusPaths.generatedImages()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = try MediaFixtures.writePNG(folder.appendingPathComponent("job-\(UUID().uuidString).png"))
        let handed = try MediaFixtures.writePNG(WF.tempDir().appendingPathComponent("source.png"))
        MediaNodeExecutor.discardOriginal(original)
        MediaNodeExecutor.discardOriginal(handed)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: handed.path))
    }

    @Test
    func remote_unattendedRunFailsWithTheFixInsteadOfWaiting() async {
        let remote = MediaFixtures.remote("flux-pro")
        let spec = MediaSpec(model: MediaModelSelector(locality: .remote), prompt: "a {{input.subject}}")
        let log = MediaJobLog()
        let run = await Self.run(
            Self.one(spec), runtime: Self.runtime(log, candidates: [remote], approve: .nobodyToAsk))
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("Always Allow") == true)
        #expect(await log.remoteImages.isEmpty)
    }

    @Test
    func decide_neverPromptsACallerNobodyIsWatching() async {
        let asked = MediaJobLog()
        func decide(_ policy: SubagentPermissionPolicy, _ caller: WorkflowCaller, answer: Bool = true) async
            -> MediaRemoteApproval
        {
            await MediaNodeRuntime.decide(policy: policy, caller: caller) {
                await asked.approval("ask", "")
                return answer
            }
        }
        let scheduled = WorkflowCaller(kind: .event, isUnattendedDispatch: true)
        let http = WorkflowCaller(kind: .agent, isExternalSurface: true)
        let phone = WorkflowCaller(kind: .agent, isExternalSurface: true, hasRemoteReviewer: true)
        #expect(await decide(.ask, scheduled) == .nobodyToAsk)
        #expect(await decide(.ask, http) == .nobodyToAsk)
        #expect(await asked.approvals.isEmpty)
        #expect(await decide(.alwaysAllow, scheduled) == .approved)
        #expect(await decide(.deny, WorkflowCaller(kind: .user)) == .denied)
        #expect(await decide(.ask, phone) == .approved)
        #expect(await decide(.ask, WorkflowCaller(kind: .user), answer: false) == .denied)
        #expect(await asked.approvals.count == 2)
    }

    @Test
    func video_checksTheDurationThenQuotesAndAsks() async throws {
        let remote = MediaFixtures.remote(
            "seedance", kind: .textToVideo, constraints: MediaModelConstraints(durations: ["5", "10"]))
        func spec(_ duration: String) -> MediaSpec {
            MediaSpec(action: .video, model: MediaModelSelector(locality: .remote), prompt: "a {{input.subject}}", duration: duration)
        }
        let log = MediaJobLog()
        let wrong = await Self.run(Self.one(spec("7")), runtime: Self.runtime(log, candidates: [remote]))
        #expect(wrong.status == .failed)
        #expect(wrong.error?.reason.contains("takes durations 5, 10") == true)
        #expect(await log.approvals.isEmpty)

        let run = await Self.run(Self.one(spec("5")), runtime: Self.runtime(log, candidates: [remote]))
        #expect(run.status == .completed)
        let asked = try #require(await log.approvals.first)
        #expect(asked.tool == "video")
        #expect(asked.arguments.contains("\"quote_usd\":0.5"))
        #expect(await log.videos.first?.duration == "5")
        let file = try #require(run.artifacts.first)
        #expect(file.isVideo)
        #expect(run.node("gen")?.output?.value(atPath: "videos.0.mime_type") == .string("video/mp4"))
        #expect(run.node("gen")?.output?.value(atPath: "images") == .array([]))
    }

    // MARK: - Progress

    @Test
    func progress_readsAsAFractionAndAPlainLine() {
        let step = MediaNodeExecutor.progress(
            NativeImageJobProgress(jobID: "j", phase: .generating, step: 5, total: 20, etaSeconds: 12))
        #expect(step.fraction == 0.25)
        #expect(step.detail == "Image step 5 of 20 · ~12s left")
        let loading = MediaNodeExecutor.progress(NativeImageJobProgress(jobID: "j", phase: .loadingModel, model: "Qwen"))
        #expect(loading.fraction == nil)
        #expect(loading.detail == "Loading Qwen")
    }

    @Test
    func progress_keepsTheLatestPreviewUntilGeneratingEnds() {
        var preview: Data?
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let drawn = MediaNodeExecutor.progress(
            NativeImageJobProgress(jobID: "j", phase: .generating, step: 4, total: 8, previewPNG: png),
            keeping: &preview)
        #expect(drawn.previewPNG == png)
        #expect(drawn.fraction == 0.5)
        let next = MediaNodeExecutor.progress(
            NativeImageJobProgress(jobID: "j", phase: .generating, step: 5, total: 8), keeping: &preview)
        #expect(next.previewPNG == png)
        let done = MediaNodeExecutor.progress(NativeImageJobProgress(jobID: "j", phase: .unloading), keeping: &preview)
        #expect(done.previewPNG == nil)
        #expect(preview == nil)
    }

    @Test
    func progress_previewIsNotSavedWithTheRun() throws {
        let live = WorkflowNodeProgress(fraction: 0.5, detail: "Step 4 of 8", previewPNG: Data([1, 2, 3]))
        let decoded = try JSONDecoder().decode(WorkflowNodeProgress.self, from: JSONEncoder().encode(live))
        #expect(decoded == WorkflowNodeProgress(fraction: 0.5, detail: "Step 4 of 8"))
    }

    // MARK: - Engine contract (vmlx-flux-media-requests 1.2, 1.5, 1.7, 1.8)

    @Test
    func sampling_reachesTheJobAndIsRecorded() async throws {
        let log = MediaJobLog()
        let spec = MediaSpec(
            model: MediaModelSelector(family: "qwen-image-2.1"), prompt: "a {{input.subject}}", width: .value(64),
            height: .value(64), seed: .value(1), count: .value(2), batchSize: .value(2), sampler: "heun",
            scheduler: "linear", shift: .value(2.5), previewInterval: .value(5))
        let run = await Self.run(Self.one(spec), runtime: Self.runtime(log, candidates: [Self.q21]))

        #expect(run.status == .completed, "\(run.error?.reason ?? "")")
        let job = try #require(await log.generates.first)
        #expect(job.sampler == "heun")
        #expect(job.scheduler == "linear")
        #expect(job.shift == 2.5)
        #expect(job.previewInterval == 5)
        #expect(job.batchSize == 2)
        #expect(job.seeds == [1, 2])
        #expect(run.node("gen")?.logs.contains { $0.contains("at most 1 image(s) at once") } == true)
        let metadata = try #require(run.artifacts.first?.metadata)
        #expect(metadata["sampler"] == .string("heun"))
        #expect(metadata["scheduler"] == .string("linear"))
        #expect(metadata["shift"] == .number(2.5))
        #expect(WorkflowMediaGalleryModel.reusableSpec(metadata)?.sampler == "heun")
        #expect(WorkflowMediaGalleryModel.reusableSpec(metadata)?.shift == .value(2.5))
    }

    @Test
    func sampling_anUnlistedChoiceFailsBeforeAnyJob() async {
        let log = MediaJobLog()
        let wrongSampler = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64), sampler: "dpm")),
            runtime: Self.runtime(log, candidates: [Self.q21]))
        #expect(wrongSampler.status == .failed)
        #expect(wrongSampler.error?.reason.contains("refuses `sampler` = dpm: it takes euler, heun") == true)

        let shiftOnTurbo = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64), shift: .value(3))),
            runtime: Self.runtime(log, candidates: [Self.turbo]))
        #expect(shiftOnTurbo.status == .failed)
        #expect(shiftOnTurbo.error?.reason.contains("refuses `shift`") == true)

        let noLimits = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64), scheduler: "linear")),
            runtime: Self.runtime(log, candidates: [Self.qwen]))
        #expect(noLimits.status == .failed)
        #expect(noLimits.error?.reason.contains("`scheduler` cannot be set") == true)
        #expect(await log.generates.isEmpty)
    }

    @Test
    func batch_aFailedBatchKeepsTheImagesItFinished() async throws {
        let log = MediaJobLog()
        let dir = WF.tempDir()
        var runtime = Self.runtime(log, candidates: [Self.q21])
        runtime.generateLocal = { request, _ in
            await log.record(request)
            let done = try (0 ..< 2).map { index -> GeneratedImage in
                let url = try MediaFixtures.writePNG(dir.appendingPathComponent("raw-\(index).png"))
                return GeneratedImage(url: url, seed: request.seeds?[index] ?? 0)
            }
            throw NativeImageJobPartialFailure(
                images: done, underlying: NativeImageJobCoordinatorError.requestFailed("the GPU gave up"))
        }
        let spec = MediaSpec(prompt: "x", width: .value(64), height: .value(64), seed: .value(40), count: .value(4))
        let run = await Self.run(Self.one(spec), runtime: runtime)

        #expect(run.status == .failed)
        let reason = run.error?.reason ?? ""
        #expect(reason.contains("failed after 2 of 4 images"), "\(reason)")
        #expect(reason.contains("the GPU gave up"))
        let kept = reason.components(separatedBy: "kept: ").last?.components(separatedBy: ", ") ?? []
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(kept.first?.contains("-s40-") == true)
    }

    @Test
    func memoryAdmission_namesTheSettingAndTheEstimate() async {
        let log = MediaJobLog()
        var runtime = Self.runtime(log, candidates: [Self.q21])
        runtime.generateLocal = { request, _ in
            await log.record(request)
            throw ImageGenerationError.memoryAdmission(
                field: "memorySafety.requestEstimate", estimatedBytes: 48 * 1024 * 1024 * 1024,
                budgetBytes: 5 * 1024 * 1024 * 1024,
                message: "Reduce the context length.")
        }
        let run = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64))), runtime: runtime)
        #expect(run.status == .failed)
        let reason = run.error?.reason ?? ""
        #expect(reason.contains("`memorySafety.requestEstimate`"), "\(reason)")
        #expect(reason.contains("48 GB"))
        #expect(reason.contains("allows 5 GB"))
        #expect(!reason.contains("context length"))
    }

    @Test
    func memoryAdmission_withoutABudgetKeepsTheEngineReason() async {
        let log = MediaJobLog()
        var runtime = Self.runtime(log, candidates: [Self.q21])
        runtime.generateLocal = { request, _ in
            await log.record(request)
            throw ImageGenerationError.memoryAdmission(
                field: "memorySafety.requestEstimate", estimatedBytes: 1024 * 1024 * 1024,
                budgetBytes: nil,
                message: "Strict memory safety requires a request working-set estimate before launch.")
        }
        let run = await Self.run(
            Self.one(MediaSpec(prompt: "x", width: .value(64), height: .value(64))), runtime: runtime)
        let reason = run.error?.reason ?? ""
        #expect(reason.contains("requires a request working-set estimate"), "\(reason)")
        #expect(reason.contains("Memory Safety"))
    }

    // MARK: - Local video (1.9)

    @Test
    func localVideo_runsWithoutApprovalAndRecordsWhatRan() async throws {
        let log = MediaJobLog()
        let spec = MediaSpec(
            action: .video, model: MediaModelSelector(locality: .local), prompt: "a {{input.subject}} running",
            steps: .value(30), seed: .value(9), frameCount: .value(49), fps: .value(16))
        #expect(WorkflowValidator.mediaIssues(spec, node: MediaFixtures.media("gen", spec), def: Self.one(spec)).isEmpty)
        let run = await Self.run(Self.one(spec), runtime: Self.runtime(log, candidates: [MediaFixtures.localVideo()]))

        #expect(run.status == .completed, "\(run.error?.reason ?? "")")
        #expect(await log.approvals.isEmpty)
        #expect(await log.videos.isEmpty)
        let request = try #require(await log.localVideos.first)
        #expect(request.target.backend == .local)
        #expect(request.frameCount == 49)
        #expect(request.fps == 16)
        #expect(request.duration == "3.0625")
        #expect(request.steps == 30)
        #expect(request.seed == 9)
        #expect(request.resolution == "480p")

        let output = try #require(run.node("gen")?.output)
        #expect(output.value(atPath: "backend") == .string("local"))
        #expect(output.value(atPath: "videos.0.effective_parameters.frame_count") == .number(49))
        #expect(output.value(atPath: "videos.0.effective_parameters.width") == .number(832))
        let file = try #require(run.artifacts.first)
        #expect(file.isVideo)
        #expect(file.metadata?["parameters"] == .string("effective"))
        #expect(file.metadata?["frame_count"] == .number(49))
        #expect(file.metadata?["fps"] == .number(16))
        #expect(WorkflowMediaGalleryModel.reusableSpec(file.metadata)?.frameCount == .value(49))
    }

    @Test
    func localVideo_aFrameCountOffTheGridFailsBeforeTheJob() async {
        let log = MediaJobLog()
        let spec = MediaSpec(
            action: .video, model: MediaModelSelector(locality: .local), prompt: "x", frameCount: .value(50),
            fps: .value(16))
        #expect(
            WorkflowValidator.mediaIssues(spec, node: MediaFixtures.media("gen", spec), def: Self.one(spec))
                .contains { $0.contains("4n+1") })
        let overridden = Self.one(
            MediaSpec(action: .video, model: MediaModelSelector(locality: .local), prompt: "x", fps: .value(16)),
            input: .object(["frame_count": "{{input.seed}}"]))
        let run = await Self.run(
            overridden, input: .object(["subject": .string("fox"), "seed": .number(50)]),
            runtime: Self.runtime(log, candidates: [MediaFixtures.localVideo()]))
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("refuses this video") == true, "\(run.error?.reason ?? "")")
        #expect(run.error?.reason.contains("4n+1") == true)
        #expect(await log.localVideos.isEmpty)

        let i2v = await Self.run(
            Self.one(
                MediaSpec(action: .video, model: MediaModelSelector(locality: .local), prompt: "x", duration: "3.0625s")),
            runtime: Self.runtime(log, candidates: [MediaFixtures.localVideo("Wan2.1-I2V-14B", kind: .imageToVideo)]))
        #expect(i2v.status == .failed)
        #expect(i2v.error?.reason.contains("set `sources` to one image") == true, "\(i2v.error?.reason ?? "")")
    }

    @Test
    func localVideo_stopReachesTheJob() async throws {
        let log = MediaJobLog()
        let handed = TokenBox()
        var runtime = Self.runtime(log, candidates: [MediaFixtures.localVideo()])
        runtime.generateLocalVideo = { request, _, interrupt, _ in
            await log.recordLocal(request)
            await handed.set(interrupt)
            while !interrupt.isInterrupted { try? await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        let spec = MediaSpec(action: .video, model: MediaModelSelector(locality: .any), prompt: "x", duration: "3.0625s")
        MediaNodeExecutor.runtime = runtime
        defer { MediaNodeExecutor.runtime = .live }
        let task = Task { await Self.runner(Self.one(spec)).execute() }
        let deadline = Date().addingTimeInterval(5)
        while await log.localVideos.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let run = await task.value
        #expect(run.status == .cancelled)
        #expect(await handed.token?.isInterrupted == true)
        #expect(run.artifacts.isEmpty)
        #expect(try await MediaJobLane.shared.run { 1 } == 1)
    }

    @Test
    func remote_saysWhichLocalOnlyFieldsWereNotSent() async {
        let remote = MediaFixtures.remote("flux-pro")
        let spec = MediaSpec(
            model: MediaModelSelector(locality: .remote), prompt: "x", sampler: "euler", previewInterval: .value(2))
        let log = MediaJobLog()
        let run = await Self.run(Self.one(spec), runtime: Self.runtime(log, candidates: [remote]))
        #expect(run.status == .completed)
        #expect(run.node("gen")?.logs.contains { $0.contains("`sampler`, `preview_interval`; they were not sent") } == true)
    }

    // MARK: - The run's own model

    /// write (inference) -> gen (media), with the image job's invocation
    /// recorded.
    static func afterInference(
        caller: WorkflowCaller, resident: @escaping @Sendable (String) async -> String?
    ) async -> (WorkflowRun, ModelJobInvocation?) {
        actor Seen {
            var invocation: ModelJobInvocation?
            func set(_ value: ModelJobInvocation) { invocation = value }
        }
        let seen = Seen()
        let log = MediaJobLog()
        var runtime = Self.runtime(log, candidates: [Self.qwen])
        let generate = runtime.generateLocal
        runtime.generateLocal = { request, interrupt in
            await seen.set(request.context.invocation)
            return try await generate(request, interrupt)
        }
        runtime.residentLocalModel = resident
        let spec = MediaSpec(
            model: MediaModelSelector(family: "qwen-image-2.1"), prompt: "a fox", width: .value(64), height: .value(64),
            steps: .value(8))
        let def = MediaFixtures.definition(
            [
                WorkflowNode(
                    id: "write", name: "Write", kind: .inference(InferenceSpec(modelSlot: "main", instructions: "x"))),
                MediaFixtures.media("gen", spec),
            ],
            edges: [WorkflowEdge(from: "write", to: "gen")])
        let template = WF.template(def)
        let executor = ClosureExecutor { ctx, awaiting in
            if case .inference = ctx.node.kind {
                return WorkflowNodeOutcome(output: .object(["text": .string("hi")]), model: "qwen3.8-27b")
            }
            return try await Self.executor.execute(ctx, awaitingUser: awaiting)
        }
        MediaNodeExecutor.runtime = runtime
        defer { MediaNodeExecutor.runtime = .live }
        let run = await WorkflowRunner(
            request: WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template, caller: caller,
                input: .object([:]), workspace: WF.tempDir()),
            executor: executor
        ).execute()
        return (run, await seen.invocation)
    }

    @Test
    func localImage_namesTheRunsLoadedModelAsItsParent() async {
        let (run, invocation) = await Self.afterInference(
            caller: WorkflowCaller(kind: .agent, isUnattendedDispatch: true),
            resident: { $0 == "qwen3.8-27b" ? "qwen3.8-27b" : nil })
        #expect(run.status == .completed, "\(run.error?.reason ?? "")")
        #expect(invocation?.parentModelName == "qwen3.8-27b")
        #expect(invocation?.source == .schedule)
    }

    @Test
    func localImage_hasNoParentWhenTheRunsModelIsNotLoaded() async {
        let (run, invocation) = await Self.afterInference(caller: WorkflowCaller(kind: .user), resident: { _ in nil })
        #expect(run.status == .completed)
        #expect(invocation == ModelJobInvocation(parentModelName: nil, source: nil))
    }

    @Test
    func refusedLocalJob_keepsItsMessageAndSaysWhereTheFixBelongs() async {
        let log = MediaJobLog()
        var runtime = Self.runtime(log, candidates: [Self.qwen])
        runtime.generateLocal = { _, _ in throw SubagentError.unavailable("Another model is loaded for an API request.") }
        let spec = MediaSpec(model: MediaModelSelector(family: "qwen-image-2.1"), prompt: "x", width: .value(64), height: .value(64))
        let run = await Self.run(Self.one(spec), runtime: runtime)
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("Another model is loaded for an API request.") == true, "\(run.error?.reason ?? "")")
        #expect(run.error?.reason.contains("error 2") == false)
        #expect(run.error?.failure?.kind == "unavailable")
        #expect(run.error?.failure?.fixIn == .settings)
        #expect(run.node("gen")?.failure?.errorType == "SubagentError.unavailable")
    }
}
