//
//  WorkflowMediaStepTests.swift
//  OsaurusCoreTests
//
//  The `media` step without a model: its spec and node mode in JSON,
//  validation against what each action takes, the media types bindings
//  carry, setup's model requirement, trust badges, bypass in the runner,
//  the gallery's pure helpers, and the Architect's `media_models` answer.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OsaurusCore

enum MediaFixtures {
    static func local(
        _ id: String, family: String? = "qwen-image-2.1", generate: Bool = true, edit: Bool = false,
        upscale: Bool = false, ready: Bool = true
    ) -> MediaModelCandidate {
        MediaModelCandidate(
            id: id, displayName: id, family: family, isLocal: true, ready: ready,
            capabilities: ImageModelCapabilities(textToImage: generate, imageEdit: edit, upscale: upscale),
            defaultSteps: 20, defaultGuidance: 4)
    }

    static func remote(
        _ model: String, kind: MediaGenerationKind = .image, constraints: MediaModelConstraints = MediaModelConstraints()
    ) -> MediaModelCandidate {
        let info = MediaModelInfo(
            target: MediaModelTarget(backend: .osaurusCloud, modelID: model), displayName: model, providerName: "Cloud",
            kind: kind, constraints: constraints, offline: false)
        return MediaModelCandidate(id: info.id, displayName: model, family: nil, isLocal: false, ready: true, media: info)
    }

    /// A native Wan bundle, as the picker lists it.
    static func localVideo(_ id: String = "Wan2.1-T2V-1.3B", kind: MediaGenerationKind = .textToVideo)
        -> MediaModelCandidate
    {
        let info = MediaModelInfo(
            target: MediaModelTarget(backend: .local, modelID: id), displayName: id, providerName: "Local (MLX)",
            kind: kind,
            constraints: MediaModelConstraints(
                aspectRatios: ["16:9", "9:16", "1:1"], defaultAspectRatio: "16:9", resolutions: ["480p", "720p"],
                defaultResolution: "480p", durations: ["3.0625s", "5.0625s"], defaultSteps: 50, dimensionDivisor: 16),
            offline: false)
        return MediaModelCandidate(
            id: info.id, displayName: id, family: nil, isLocal: true, ready: true, defaultSteps: 50, media: info)
    }

    static func media(_ id: String, _ spec: MediaSpec, input: WorkflowBinding = .object([:]), mode: NodeMode = .always)
        -> WorkflowNode
    {
        WorkflowNode(id: id, name: id.capitalized, kind: .media(spec), input: input, mode: mode)
    }

    static func definition(
        _ nodes: [WorkflowNode], edges: [WorkflowEdge] = [], output: WorkflowBinding = .object([:]),
        input: JSONValue = WF.object(["subject": WF.string])
    ) -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: input, outputSchema: WF.object([:]), nodes: nodes, edges: edges, output: output)
    }

    /// A real PNG, so ImageIO and the source-image checks accept it.
    @discardableResult
    static func writePNG(_ url: URL, width: Int = 64, height: Int = 64) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }
}

struct WorkflowMediaStepTests {

    static let generate = MediaSpec(model: MediaModelSelector(family: "qwen-image-2.1"), prompt: "a {{input.subject}}")
    static let edit = MediaSpec(action: .edit, prompt: "make it night", sources: ["{{nodes.gen.output.images}}"])
    static let upscale = MediaSpec(action: .upscale, sources: ["{{nodes.edit.output.images.0.path}}"], scale: .value(2))

    static func chain() -> WorkflowDefinition {
        MediaFixtures.definition(
            [
                MediaFixtures.media("gen", generate), MediaFixtures.media("edit", edit),
                MediaFixtures.media("up", upscale),
            ],
            edges: [WorkflowEdge(from: "gen", to: "edit"), WorkflowEdge(from: "edit", to: "up")])
    }

    // MARK: - Spec and mode in JSON

    @Test
    func spec_decodesValuesBindingsAndLooseFields() throws {
        let json = #"""
            {"id":"gen","name":"Gen","kind":"media","mode":"bypass","media":{
              "action":"generate","model":{"family":"qwen-image-2.1","locality":"any"},
              "prompt":"a {{input.subject}}","negative_prompt":"","width":1024,"height":"768",
              "seed":"{{input.seed}}","count":4,"duration":5}}
            """#
        let node = try JSONDecoder().decode(WorkflowNode.self, from: Data(json.utf8))
        guard case .media(let spec) = node.kind else {
            Issue.record("not a media node")
            return
        }
        #expect(node.mode == .bypass)
        #expect(spec.model == MediaModelSelector(family: "qwen-image-2.1", locality: .any))
        #expect(spec.negativePrompt == nil)
        #expect(spec.width == .value(1024))
        #expect(spec.height == .value(768))
        #expect(spec.seed == .bound("{{input.seed}}"))
        #expect(spec.count?.staticValue == 4)
        #expect(spec.duration == "5")
        #expect(spec.effectiveSeedMode == .fixed)
        #expect(node.effectiveOutputSchema == MediaSpec.outputSchema)
        #expect(WorkflowNode.kindNames.contains("media"))

        let again = try JSONDecoder().decode(WorkflowNode.self, from: JSONEncoder().encode(node))
        #expect(again.kind == node.kind)
        #expect(again.mode == .bypass)
    }

    @Test
    func spec_roundTripsTheEngineKeys() throws {
        let json = #"""
            {"action":"generate","prompt":"x","batch_size":2,"sampler":"heun","scheduler":"{{input.scheduler}}",
             "shift":"2.5","preview_interval":4}
            """#
        let spec = try JSONDecoder().decode(MediaSpec.self, from: Data(json.utf8))
        #expect(spec.batchSize == .value(2))
        #expect(spec.sampler == "heun")
        #expect(spec.scheduler == "{{input.scheduler}}")
        #expect(spec.shift == .value(2.5))
        #expect(spec.previewInterval == .value(4))
        #expect(spec.templates.contains("{{input.scheduler}}"))
        let again = try JSONDecoder().decode(MediaSpec.self, from: JSONEncoder().encode(spec))
        #expect(again == spec)

        let video = try JSONDecoder().decode(
            MediaSpec.self, from: Data(#"{"action":"video","prompt":"x","frame_count":81,"fps":"{{input.fps}}"}"#.utf8))
        #expect(video.frameCount == .value(81))
        #expect(video.fps == .bound("{{input.fps}}"))
        let keys = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(video)) as? [String: Any])
        #expect(keys["frame_count"] as? Int == 81)
        for key in ["batch_size", "sampler", "scheduler", "shift", "preview_interval", "frame_count", "fps"] {
            #expect(MediaSpec.overridableKeys.contains(key))
        }
    }

    @Test
    func resolver_listsLocalWanBundlesAsLocalVideo() {
        let wan = MediaFixtures.localVideo()
        let item = ModelPickerItem(
            id: wan.id, displayName: wan.displayName, source: .imageGeneration, imageKind: "videoGen",
            imageReady: true, mediaModel: wan.media)
        let candidates = MediaModelResolver.candidates(from: [item])
        #expect(candidates.count == 1)
        #expect(candidates.first?.isLocal == true)
        #expect(candidates.first?.supports(.video) == true)
        #expect(candidates.first?.supports(.generate) == false)
        func pick(_ locality: MediaLocality, _ pool: [MediaModelCandidate]) -> MediaModelCandidate? {
            try? MediaModelResolver.resolve(
                MediaModelSelector(locality: locality), action: .video, candidates: pool).get()
        }
        let remote = MediaFixtures.remote("seedance", kind: .textToVideo)
        #expect(pick(.local, [remote, wan])?.isLocal == true)
        #expect(pick(.any, [remote, wan])?.isLocal == true)
        #expect(pick(.remote, [remote, wan])?.isLocal == false)
        #expect(pick(.local, [remote]) == nil)
        let byFamily = try? MediaModelResolver.resolve(
            MediaModelSelector(family: "wan-2.1"), action: .video, candidates: [remote, wan]
        ).get()
        #expect(byFamily?.id == wan.id)
        let limits = wan.constraintsSummary
        #expect(limits["frame_rule"] != nil)
        #expect(limits["audio"] == .bool(false))
        #expect(limits["default_steps"] == .number(50))
    }

    @Test
    func spec_acceptsShorthandsAndRejectsJunkValues() throws {
        let one = try JSONDecoder().decode(
            MediaSpec.self, from: Data(#"{"action":"upscale","model":"real-esrgan","source":"{{input.photo}}"}"#.utf8))
        #expect(one.model == MediaModelSelector(id: "real-esrgan"))
        #expect(one.sources == ["{{input.photo}}"])
        #expect(one.effectiveSeedMode == .random)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MediaSpec.self, from: Data(#"{"width":"wide"}"#.utf8))
        }
    }

    @Test
    func defaults_stayOutOfTheJSONSoTemplateHashesHold() throws {
        let node = MediaFixtures.media("gen", Self.generate)
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        #expect(json["mode"] == nil)
        let media = try #require(json["media"] as? [String: Any])
        #expect(Set(media.keys) == ["action", "model", "prompt"])
        let code = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(WF.code("a"))) as? [String: Any])
        #expect(code["mode"] == nil)
    }

    // MARK: - Validation

    static func issues(_ def: WorkflowDefinition) -> [String] {
        WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
    }

    static func issues(_ spec: MediaSpec, input: WorkflowBinding = .object([:])) -> [String] {
        issues(MediaFixtures.definition([MediaFixtures.media("m", spec, input: input)]))
    }

    @Test
    func validator_acceptsAGenerateEditUpscaleChain() {
        #expect(Self.issues(Self.chain()).isEmpty)
    }

    @Test
    func validator_namesWhatEachActionNeeds() {
        func has(_ spec: MediaSpec, _ needle: String, input: WorkflowBinding = .object([:])) -> Bool {
            Self.issues(spec, input: input).contains { $0.contains(needle) }
        }
        #expect(has(MediaSpec(prompt: " "), "needs a `prompt`"))
        #expect(!has(MediaSpec(), "needs a `prompt`", input: .object(["prompt": "{{input.subject}}"])))
        #expect(has(MediaSpec(action: .edit, prompt: "x"), "needs `sources`"))
        #expect(has(MediaSpec(prompt: "x", sources: ["{{input.subject}}"]), "use `edit`"))
        #expect(has(MediaSpec(action: .upscale, sources: ["{{input.a}}", "{{input.b}}"]), "takes one source"))
        #expect(has(MediaSpec(action: .edit, prompt: "x", sources: ["/Users/me/cat.png"]), "names a file on this Mac"))
        #expect(!has(MediaSpec(action: .video, model: MediaModelSelector(locality: .local), prompt: "x", duration: "5"), "locality"))
        #expect(!has(MediaSpec(action: .video, prompt: "x", frameCount: .value(49), fps: .value(16)), "needs a `duration`"))
        #expect(has(MediaSpec(action: .video, prompt: "x", frameCount: .value(48), fps: .value(16)), "4n+1"))
        #expect(has(MediaSpec(prompt: "x", frameCount: .value(49)), "`frame_count` applies to `video` only"))
        #expect(has(MediaSpec(action: .upscale, sources: ["{{input.subject}}"], sampler: "euler"), "`sampler` applies to"))
        #expect(has(MediaSpec(action: .edit, prompt: "x", sources: ["{{input.subject}}"], batchSize: .value(2)), "`batch_size` applies to `generate` only"))
        #expect(has(MediaSpec(prompt: "x", previewInterval: .value(0)), "`preview_interval` must be between"))
        #expect(has(MediaSpec(action: .edit, model: MediaModelSelector(locality: .remote), prompt: "x", sources: ["{{input.subject}}"]), "runs on this Mac"))
        #expect(has(MediaSpec(action: .video, model: MediaModelSelector(locality: .remote), prompt: "x"), "needs a `duration`"))
        #expect(has(MediaSpec(prompt: "x", count: .value(9)), "`count` must be between 1 and 8"))
        #expect(has(MediaSpec(prompt: "x", width: .value(32)), "`width` must be between"))
        #expect(has(MediaSpec(action: .upscale, sources: ["{{input.subject}}"], scale: .value(3)), "`scale` must be 2 or 4"))
        #expect(has(MediaSpec(prompt: "x", strength: .value(0.5)), "`strength` applies to `edit` only"))
        #expect(has(MediaSpec(prompt: "x"), "not a media parameter", input: .object(["temperature": "1"])))
        #expect(has(MediaSpec(prompt: "x"), "must be an object", input: .template("{{input}}")))
    }

    @Test
    func validator_refusesAVideoAsAnImageSource() {
        let video = MediaSpec(action: .video, model: MediaModelSelector(locality: .remote), prompt: "x", duration: "5")
        let def = MediaFixtures.definition(
            [
                MediaFixtures.media("clip", video),
                MediaFixtures.media(
                    "edit", MediaSpec(action: .edit, prompt: "x", sources: ["{{nodes.clip.output.videos.0.path}}"])),
            ],
            edges: [WorkflowEdge(from: "clip", to: "edit")])
        #expect(Self.issues(def).contains { $0.contains("which is a video, not an image") })
    }

    // MARK: - Binding types

    @Test
    func bindingTypes_followTheMediaOutputSchema() {
        let def = Self.chain()
        func type(_ t: String) -> BindingTypeResolver.ValueType { BindingTypeResolver.type(ofTemplate: t, in: def) }
        #expect(type("{{nodes.gen.output.images}}") == .imageList)
        #expect(type("{{nodes.gen.output.images.0.path}}") == .image)
        #expect(type("{{nodes.gen.output.count}}") == .integer)
        #expect(type("{{nodes.gen.output.model}}") == .string)
        #expect(type("Look: {{nodes.gen.output.images.0.path}}") == .string)
        #expect(type("{{input.subject}}") == .string)
        #expect(type("{{nodes.nope.output.x}}") == .unknown)

        let photo = MediaFixtures.definition(
            [], input: WF.object(["photo": .object(["type": .string("string"), "format": .string("image")])]))
        #expect(BindingTypeResolver.type(ofTemplate: "{{input.photo}}", in: photo) == .image)
    }

    @Test
    func edgeTypes_tintOnlyEdgesThatCarryMedia() throws {
        let def = Self.chain()
        let gen = try #require(def.node("gen"))
        let edit = try #require(def.node("edit"))
        let up = try #require(def.node("up"))
        #expect(BindingTypeResolver.edgeType(from: gen, to: edit, in: def) == .image)
        #expect(BindingTypeResolver.edgeType(from: gen, to: up, in: def) == nil)
        #expect(BindingTypeResolver.edgeType(from: WF.code("a"), to: edit, in: def) == nil)
        let clip = MediaFixtures.media("clip", MediaSpec(action: .video, prompt: "x", duration: "5"))
        let post = WF.code("post", input: .object(["file": "{{nodes.clip.output.videos.0.path}}"]))
        #expect(BindingTypeResolver.edgeType(from: clip, to: post, in: def) == .video)
    }

    // MARK: - Requirements, setup, trust

    @Test
    func requirements_listEachDistinctMediaModelOnce() {
        var def = Self.chain()
        def.nodes.append(MediaFixtures.media("gen2", Self.generate))
        let reqs = WorkflowRequirementsDeriver.derive(def).mediaModels
        #expect(reqs.map(\.action) == [.generate, .edit, .upscale])
        #expect(reqs.first?.model.family == "qwen-image-2.1")
        #expect(reqs.first?.label == "Image generation (qwen-image-2.1)")
    }

    @Test
    func setup_blocksUntilAModelCanDoEachAction() {
        let template = WF.template(Self.chain())
        func report(_ candidates: [MediaModelCandidate]) -> [SetupItem] {
            var env = SetupChecker.Environment(
                registeredToolNames: [], modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
                isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
                knowledgeCollectionExists: { _ in true })
            env.mediaCandidates = candidates
            return SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: env)
                .blocking.filter { $0.kind == .mediaModel }
        }
        let none = report([])
        #expect(none.count == 3)
        #expect(none.first?.detail.contains("qwen-image-2.1") == true)

        let partial = report([MediaFixtures.local("qwen-image-2.1-8bit", edit: true)])
        #expect(partial.map(\.title) == ["Image upscaling"])

        let all = report([
            MediaFixtures.local("qwen-image-2.1-8bit", edit: true),
            MediaFixtures.local("esrgan", family: "real-esrgan", generate: false, upscale: true),
        ])
        #expect(all.isEmpty)
        #expect(report([MediaFixtures.local("qwen-image-2.1-8bit", edit: true, ready: false)]).count == 3)
    }

    /// Before the model cache's first build every machine looks empty; that
    /// must not park a test or install as "needs setup".
    @Test
    func setup_doesNotBlockBeforeTheModelCacheLoads() {
        var env = SetupChecker.Environment(
            registeredToolNames: [], modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.mediaCandidatesLoaded = false
        let report = SetupChecker.check(
            WF.template(Self.chain()), bindings: InstallBindings(), subjectId: UUID(), environment: env)
        let media = report.items.filter { $0.kind == .mediaModel }
        #expect(media.count == 3)
        #expect(media.allSatisfy { !$0.isBlocking })
        #expect(!report.hasBlockers)
    }

    @Test
    func trust_saysWhereTheJobRuns() throws {
        func kinds(_ spec: MediaSpec) -> [WorkflowStepBadge.Kind: WorkflowStepBadge.Tone] {
            let node = MediaFixtures.media("m", spec)
            let def = MediaFixtures.definition([node])
            return Dictionary(
                WorkflowStepRisk.badges(for: node, in: def, locality: { _ in .local }).map { ($0.kind, $0.tone) },
                uniquingKeysWith: { a, _ in a })
        }
        let local = kinds(Self.generate)
        #expect(local[.media] == .neutral)
        #expect(local[.localModel] == .neutral)
        #expect(local[.cloudModel] == nil)
        let video = kinds(MediaSpec(action: .video, model: MediaModelSelector(locality: .remote), prompt: "x", duration: "5"))
        #expect(video[.cloudModel] == .caution)
        let localVideo = kinds(MediaSpec(action: .video, model: MediaModelSelector(locality: .local), prompt: "x"))
        #expect(localVideo[.cloudModel] == nil)
        #expect(localVideo[.localModel] == .neutral)
    }

    // MARK: - Bypass

    @Test
    func bypass_handsSourcesOnWithoutRunningTheStep() async {
        let log = NodeCallLog()
        var def = Self.chain()
        def.nodes[1].mode = .bypass
        def.outputSchema = WF.object(["final": WF.string])
        def.output = .object(["final": "{{nodes.up.output.images.0.path}}"])
        let executor = ClosureExecutor { ctx, _ in
            await log.enter(ctx.node.id)
            let path =
                ctx.node.id == "gen"
                ? "/tmp/gen-1.png"
                : MediaSourceList.paths(Self.upscale.sources, overrides: .object([:]), in: ctx.bindings).joined()
            return WorkflowNodeOutcome(output: Self.mediaOutput(path))
        }
        let template = WF.template(def)
        let run = await WorkflowRunner(
            request: WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template, caller: WorkflowCaller(kind: .user),
                input: .object(["subject": .string("a fox")]), workspace: WF.tempDir()),
            executor: executor
        ).execute()

        #expect(run.status == .completed)
        #expect(await log.calls == ["gen", "up"])
        let bypassed = run.node("edit")
        #expect(bypassed?.status == .done)
        #expect(bypassed?.output?.value(atPath: "bypassed") == .bool(true))
        #expect(bypassed?.output?.value(atPath: "images.0.path") == .string("/tmp/gen-1.png"))
        #expect(run.output?.value(atPath: "final") == .string("/tmp/gen-1.png"))
    }

    static func mediaOutput(_ path: String) -> JSONValue {
        .object([
            "images": .array([.object(["path": .string(path)])]), "videos": .array([]), "model": .string("fake"),
            "count": .number(1),
        ])
    }

    @Test
    func bypass_onAnyStepPassesItsRenderedInput() {
        let node = WF.code("tidy", input: .object(["text": "{{input.subject}}"]))
        #expect(node.bypassOutput(input: .object(["text": .string("fox")]), bindings: BindingContext(input: .object([:])))
            == .object(["text": .string("fox")]))
        #expect(node.bypassPassesData)
        #expect(!WF.code("empty").bypassPassesData)
        #expect(!MediaFixtures.media("gen", Self.generate).bypassPassesData)
        #expect(MediaFixtures.media("edit", Self.edit).bypassPassesData)
    }

    @Test
    func qwen21Sizes_areCheckedWhereTheyWouldBeRefused() {
        #expect(MediaSpec.qwen21SizeFix(1024) == nil)
        #expect(MediaSpec.qwen21SizeFix(1000) == 992)
        #expect(MediaSpec.qwen21SizeFix(3000) == 2048)
        #expect(MediaModelSelector(family: "qwen-image-2.1").selectsQwen21)
        #expect(MediaModelSelector(id: "Qwen-Image-2.1-8bit").selectsQwen21)
        #expect(!MediaModelSelector(family: "flux").selectsQwen21)

        func issues(_ selector: MediaModelSelector) -> [String] {
            WorkflowValidator.mediaIssues(
                MediaSpec(model: selector, prompt: "x", width: .value(1000), height: .value(1024)),
                node: MediaFixtures.media("gen", Self.generate), def: MediaFixtures.definition([]))
        }
        #expect(issues(MediaModelSelector(family: "qwen-image-2.1")).contains { $0.contains("use 992") })
        #expect(!issues(MediaModelSelector(family: "flux")).contains { $0.contains("Qwen-Image 2.1") })
    }

    @Test
    func linkedField_namesTheInputsItReads() {
        typealias Field = MediaParameterField<Int>
        #expect(Field.inputNames(in: "{{input.seed}}") == ["seed"])
        #expect(Field.inputNames(in: "{{ input.size.w }} and {{input.n}}") == ["size", "n"])
        #expect(Field.inputNames(in: "{{item}} {{nodes.a.output.seed}}").isEmpty)
    }

    @Test
    func clipboard_reencodesJPEGAsPNG() throws {
        let png = try MediaFixtures.writePNG(WF.tempDir().appendingPathComponent("a.png"))
        let jpeg = WF.tempDir().appendingPathComponent("a.jpg")
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let out = try #require(CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, image, nil)
        #expect(CGImageDestinationFinalize(out))

        let data = try #require(ImageActions.pngData(from: jpeg))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// A bypassed step's input stands in for its output, so it is held to
    /// the output schema later steps were promised.
    @Test
    func bypass_isCheckedAgainstTheStepsOutputSchema() async {
        func run(_ input: WorkflowBinding) async -> WorkflowRun {
            var node = WF.code("tidy", input: input, output: WF.object(["summary": WF.string], required: ["summary"]))
            node.mode = .bypass
            let template = WF.template(MediaFixtures.definition([node], input: WF.object(["subject": WF.string])))
            return await WorkflowRunner(
                request: WorkflowRunner.Request(
                    workflowID: UUID(), workflowName: template.name, template: template,
                    caller: WorkflowCaller(kind: .user), input: .object(["subject": .string("a fox")]),
                    workspace: WF.tempDir()),
                executor: ClosureExecutor { _, _ in Issue.record("a bypassed step ran"); return WorkflowNodeOutcome(output: .null) }
            ).execute()
        }
        let mismatched = await run(.object(["text": "{{input.subject}}"]))
        #expect(mismatched.status == .failed)
        #expect(mismatched.node("tidy")?.error?.contains("bypassed") == true)

        let shaped = await run(.object(["summary": "{{input.subject}}"]))
        #expect(shaped.status == .completed)
        #expect(shaped.node("tidy")?.output == .object(["summary": .string("a fox")]))
    }

    @Test
    func specHash_changesWithTheStepOrItsInput() {
        let a = MediaFixtures.media("gen", Self.generate)
        var b = a
        b.kind = .media(MediaSpec(model: Self.generate.model, prompt: "a {{input.subject}} at dusk"))
        #expect(a.specHash(input: .object([:])) == a.specHash(input: .object([:])))
        #expect(a.specHash(input: .object([:])) != b.specHash(input: .object([:])))
        #expect(a.specHash(input: .object([:])) != a.specHash(input: .object(["seed": .number(1)])))
        #expect(a.specHash(input: .object([:])).count == 24)
    }

    // MARK: - Gallery helpers

    @Test
    func gallery_stepsWrapBothWays() {
        #expect(WorkflowMediaGalleryModel.step(0, by: -1, count: 3) == 2)
        #expect(WorkflowMediaGalleryModel.step(2, by: 1, count: 3) == 0)
        #expect(WorkflowMediaGalleryModel.step(1, by: 1, count: 3) == 2)
        #expect(WorkflowMediaGalleryModel.step(0, by: 1, count: 0) == 0)
    }

    static let metadata: [String: JSONValue] = [
        "action": .string("generate"), "model": .string("Qwen Image 2.1"), "model_id": .string("qwen-image-2.1-8bit"),
        "family": .string("qwen-image-2.1"), "backend": .string("local"), "prompt": .string("a fox"),
        "width": .number(1024), "height": .number(768), "seed": .number(42), "steps": .number(20),
        "guidance": .number(4.5), "format": .string("png"), "node_id": .string("gen"),
    ]

    @Test
    func gallery_settingsReadInOrderWithReadableNumbers() {
        let lines = WorkflowMediaGalleryModel.settingsLines(Self.metadata)
        #expect(lines.map(\.label) == ["Prompt", "Model", "Size", "Seed", "Steps", "Guidance"])
        #expect(lines.first { $0.label == "Size" }?.value == "1024 × 768")
        #expect(lines.first { $0.label == "Guidance" }?.value == "4.50")
        #expect(lines.first { $0.label == "Seed" }?.value == "42")
        #expect(WorkflowMediaGalleryModel.settingsLines(nil).isEmpty)
    }

    @Test
    func gallery_reusableSpecMakesTheSameImageAgain() throws {
        let spec = try #require(WorkflowMediaGalleryModel.reusableSpec(Self.metadata))
        #expect(spec.action == .generate)
        #expect(spec.model == MediaModelSelector(family: "qwen-image-2.1", id: "qwen-image-2.1-8bit", locality: .local))
        #expect(spec.seed == .value(42))
        #expect(spec.effectiveSeedMode == .fixed)
        #expect(spec.width == .value(1024))
        #expect(spec.format == nil)
        #expect(Self.issues(spec).isEmpty)
        #expect(WorkflowMediaGalleryModel.reusableSpec(["prompt": .string("x")]) == nil)

        let file = WorkflowArtifact(
            source: .generated, nodeID: "gen", filename: "gen-1.png", mimeType: "image/png", path: "/nope.png",
            metadata: Self.metadata)
        let json = try #require(WorkflowMediaGalleryModel.settingsJSON(file))
        var step = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).objectValue)
        step["id"] = .string("again")
        step["name"] = .string("Again")
        let node = try JSONDecoder().decode(WorkflowNode.self, from: JSONEncoder().encode(JSONValue.object(step)))
        #expect(node.kind == .media(spec))
    }

    @Test
    func gallery_saveAllNeverOverwrites() throws {
        let folder = WF.tempDir()
        try Data().write(to: folder.appendingPathComponent("gen-1.png"))
        let file = WorkflowArtifact(source: .generated, filename: "gen-1.png", mimeType: "image/png", path: "/x/gen-1.png")
        #expect(WorkflowMediaGalleryModel.destination(for: file, in: folder, taken: []).lastPathComponent == "gen-1 2.png")
        #expect(
            WorkflowMediaGalleryModel.destination(for: file, in: folder, taken: ["gen-1 2.png"]).lastPathComponent
                == "gen-1 3.png")
        let items = WorkflowMediaGalleryModel.items([
            file,
            WorkflowArtifact(source: .generated, filename: "notes.txt", mimeType: "text/plain", path: "/x/notes.txt"),
            WorkflowArtifact(source: .generated, filename: "gone.png", mimeType: "image/png", path: "/x/gone.png", problem: "missing"),
        ])
        #expect(items.map(\.filename) == ["gen-1.png"])
    }

    // MARK: - Architect

    @Test
    func architect_mediaModelsListsReadyModelsAndWhatIsMissing() throws {
        let out = WorkflowDraftTool.mediaModels([
            MediaFixtures.local("qwen-image-2.1-8bit", edit: true),
            MediaFixtures.local("broken", ready: false),
            MediaFixtures.remote("seedance", kind: .textToVideo, constraints: MediaModelConstraints(durations: ["5", "10"])),
        ])
        #expect(out["count"] as? Int == 2)
        let models = try #require(out["models"] as? [[String: Any]])
        let local = try #require(models.first { $0["id"] as? String == "qwen-image-2.1-8bit" })
        #expect(local["locality"] as? String == "local")
        #expect(local["actions"] as? [String] == ["generate", "edit"])
        #expect(local["billable"] == nil)
        let limits = try #require(local["limits"] as? [String: Any])
        #expect(limits["png_only"] as? Bool == true)
        #expect(limits["max_dimension"] as? Int == 2048 || limits["max_dimension"] as? Double == 2048)
        let video = try #require(models.first { $0["locality"] as? String == "remote" })
        #expect(video["actions"] as? [String] == ["video"])
        #expect(video["billable"] as? Bool == true)
        let missing = try #require(out["unavailable"] as? [[String: Any]])
        #expect(missing.compactMap { $0["action"] as? String } == ["upscale"])

        let q21 = MediaNodeExecutorTests.q21.constraintsSummary
        #expect(q21["samplers"] == .array([.string("euler"), .string("heun")]))
        #expect(q21["schedulers"] == .array([.string("qwen-image-2.1"), .string("linear")]))
        #expect(q21["default_sampler"] == .string("euler"))
        #expect(q21["shift"] == .bool(true))
        #expect(q21["max_images"] == .number(8))
        #expect(MediaNodeExecutorTests.turbo.constraintsSummary["shift"] == .bool(false))

        let localVideo = WorkflowDraftTool.mediaModels([MediaFixtures.localVideo()])
        let wan = try #require((localVideo["models"] as? [[String: Any]])?.first)
        #expect(wan["locality"] as? String == "local")
        #expect(wan["actions"] as? [String] == ["video"])
        #expect(wan["billable"] == nil)
    }
}
