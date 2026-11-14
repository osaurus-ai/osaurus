//
//  MediaSpec.swift
//  osaurus
//
//  Media steps: make an image (generate, edit, upscale) with an image
//  model on this Mac, or a video on this Mac or a connected provider. Every
//  parameter is either a value or a `{{...}}` binding, so a step can take
//  its seed from a map item or its size from an earlier step. The output
//  lists the files it made with the settings that made them; those files
//  join the run's files without a `share_artifact` step.
//

import CryptoKit
import Foundation

/// What a media step makes.
public enum MediaAction: String, Codable, Sendable, CaseIterable {
    /// A new image from a prompt.
    case generate
    /// One to four source images changed by a prompt.
    case edit
    /// One source image made larger.
    case upscale
    /// A video from a prompt (and optionally a source image), by a local
    /// video model or a connected provider.
    case video

    var usesSources: Bool { self == .edit || self == .upscale }
    var usesPrompt: Bool { self != .upscale }
    var makesVideo: Bool { self == .video }
}

/// Where the model may run.
public enum MediaLocality: String, Codable, Sendable, CaseIterable {
    /// An image model installed on this Mac.
    case local
    /// A connected provider (billable).
    case remote
    /// Either, preferring this Mac.
    case any

    var allowsLocal: Bool { self != .remote }
    var allowsRemote: Bool { self != .local }
}

/// Which model a media step runs on. A shared workflow names a family
/// (`qwen-image-2.1`) and each Mac binds whichever installed bundle of
/// that family it has; `id` pins one bundle or provider model exactly.
public struct MediaModelSelector: Codable, Equatable, Sendable, Hashable {
    public var family: String?
    public var id: String?
    public var locality: MediaLocality

    public init(family: String? = nil, id: String? = nil, locality: MediaLocality = .local) {
        self.family = family?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.locality = locality
    }

    /// Accepts `{family?, id?, locality?}` or a bare model id.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self.init(id: raw)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            family: try c.decodeIfPresent(String.self, forKey: .family),
            id: try c.decodeIfPresent(String.self, forKey: .id),
            locality: try c.decodeIfPresent(MediaLocality.self, forKey: .locality) ?? .local)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(family, forKey: .family)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(locality, forKey: .locality)
    }

    enum CodingKeys: String, CodingKey { case family, id, locality }

    /// What the person sees: the pinned id, the family, or "default".
    public var label: String { id ?? family ?? L("the default image model") }
}

/// How the seed moves from one image (or one map item) to the next.
public enum MediaSeedMode: String, Codable, Sendable, CaseIterable {
    /// Every image uses `seed` (the engine still offsets images within one
    /// step so they differ).
    case fixed
    /// A fresh seed each run; `seed` is ignored.
    case random
    /// `seed` plus the map item's index, so a map over N items sweeps N
    /// consecutive seeds.
    case increment
}

// MARK: - Value or binding

/// A scalar a media parameter holds.
public protocol MediaScalar: Codable, Equatable, Sendable {
    init?(json: JSONValue)
    var json: JSONValue { get }
}

extension Int: MediaScalar {
    public init?(json: JSONValue) {
        switch json {
        case .number(let n) where n.rounded() == n && abs(n) < 9e15: self = Int(n)
        case .string(let s): guard let v = Int(s.trimmingCharacters(in: .whitespaces)) else { return nil }; self = v
        default: return nil
        }
    }
    public var json: JSONValue { .number(Double(self)) }
}

extension Double: MediaScalar {
    public init?(json: JSONValue) {
        switch json {
        case .number(let n): self = n
        case .string(let s): guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }; self = v
        default: return nil
        }
    }
    public var json: JSONValue { .number(self) }
}

extension Bool: MediaScalar {
    public init?(json: JSONValue) {
        switch json {
        case .bool(let b): self = b
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": self = true
            case "false", "no", "0": self = false
            default: return nil
            }
        default: return nil
        }
    }
    public var json: JSONValue { .bool(self) }
}

/// A parameter set on the step (`.value`) or taken from the run
/// (`.bound`, a `{{...}}` template rendered when the step starts). In
/// JSON it is the plain scalar or the template string.
public enum MediaValue<T: MediaScalar>: Codable, Equatable, Sendable {
    case value(T)
    case bound(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let raw = try? c.decode(String.self) {
            if raw.contains("{{") {
                self = .bound(raw)
            } else if let value = T(json: .string(raw)) {
                self = .value(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "`\(raw)` is neither a value nor a {{...}} binding.")
            }
            return
        }
        self = .value(try c.decode(T.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(let v): try c.encode(v)
        case .bound(let template): try c.encode(template)
        }
    }

    public var staticValue: T? {
        if case .value(let v) = self { return v }
        return nil
    }

    public var binding: String? {
        if case .bound(let t) = self { return t }
        return nil
    }

    /// The value for this run, or nil when a binding renders to nothing
    /// usable.
    public func resolve(in ctx: BindingContext) -> T? {
        switch self {
        case .value(let v): return v
        case .bound(let template): return T(json: BindingRenderer.renderValue(template, in: ctx))
        }
    }
}

// MARK: - Spec

public struct MediaSpec: Codable, Equatable, Sendable {
    public var action: MediaAction
    public var model: MediaModelSelector
    /// What to make, or how to change the sources. A template string.
    public var prompt: String
    public var negativePrompt: String?
    /// Source image paths for edit, upscale, and image-to-video, each a
    /// template. A binding may render to a path, a list of paths, or a
    /// media step's `images` list (`{{nodes.gen.output.images}}`).
    public var sources: [String]
    public var width: MediaValue<Int>?
    public var height: MediaValue<Int>?
    public var steps: MediaValue<Int>?
    public var guidance: MediaValue<Double>?
    /// Edit only, 0...1: how far the result may move from the source.
    public var strength: MediaValue<Double>?
    public var seed: MediaValue<Int>?
    /// Nil follows `seed`: fixed when set, random otherwise.
    public var seedMode: MediaSeedMode?
    /// Images to make (generate only).
    public var count: MediaValue<Int>?
    /// Generate only: how many of `count` the engine denoises together,
    /// for families that batch (1 runs them one after another).
    public var batchSize: MediaValue<Int>?
    /// The model's sampler and scheduler names, as its limits list them.
    /// Templates.
    public var sampler: String?
    public var scheduler: String?
    /// Timestep shift, for families that take one.
    public var shift: MediaValue<Double>?
    /// Draw a preview every N steps while the image is made (local only).
    public var previewInterval: MediaValue<Int>?
    public var format: ImageOutputFormat?
    /// Upscale only: 2 or 4.
    public var scale: MediaValue<Int>?
    /// Video only, as the provider lists it (e.g. "5"). A template.
    public var duration: String?
    public var resolution: String?
    public var aspectRatio: String?
    public var audio: MediaValue<Bool>?
    /// Local video only: frames (4n+1) and frames per second. Together they
    /// set the length, so `duration` may be left out.
    public var frameCount: MediaValue<Int>?
    public var fps: MediaValue<Int>?

    public static let maximumCount = 8
    public static let maximumSources = 4
    public static let upscaleScales = [2, 4]
    public static let sizePresets = [512, 768, 1024, 1536, 2048]

    public init(
        action: MediaAction = .generate, model: MediaModelSelector = MediaModelSelector(), prompt: String = "",
        negativePrompt: String? = nil, sources: [String] = [], width: MediaValue<Int>? = nil,
        height: MediaValue<Int>? = nil, steps: MediaValue<Int>? = nil, guidance: MediaValue<Double>? = nil,
        strength: MediaValue<Double>? = nil, seed: MediaValue<Int>? = nil, seedMode: MediaSeedMode? = nil,
        count: MediaValue<Int>? = nil, format: ImageOutputFormat? = nil, scale: MediaValue<Int>? = nil,
        duration: String? = nil, resolution: String? = nil, aspectRatio: String? = nil, audio: MediaValue<Bool>? = nil,
        batchSize: MediaValue<Int>? = nil, sampler: String? = nil, scheduler: String? = nil,
        shift: MediaValue<Double>? = nil, previewInterval: MediaValue<Int>? = nil, frameCount: MediaValue<Int>? = nil,
        fps: MediaValue<Int>? = nil
    ) {
        self.action = action
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.sources = sources
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.strength = strength
        self.seed = seed
        self.seedMode = seedMode
        self.count = count
        self.format = format
        self.scale = scale
        self.duration = duration
        self.resolution = resolution
        self.aspectRatio = aspectRatio
        self.audio = audio
        self.batchSize = batchSize
        self.sampler = sampler?.nonEmptyOrNil
        self.scheduler = scheduler?.nonEmptyOrNil
        self.shift = shift
        self.previewInterval = previewInterval
        self.frameCount = frameCount
        self.fps = fps
    }

    enum CodingKeys: String, CodingKey {
        case action, model, prompt, sources, width, height, steps, guidance, strength, seed, count, format, scale
        case duration, resolution, audio, sampler, scheduler, shift, fps
        case negativePrompt = "negative_prompt"
        case batchSize = "batch_size"
        case previewInterval = "preview_interval"
        case frameCount = "frame_count"
        case seedMode = "seed_mode"
        case aspectRatio = "aspect_ratio"
        case source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(MediaAction.self, forKey: .action) ?? .generate
        model = try c.decodeIfPresent(MediaModelSelector.self, forKey: .model) ?? MediaModelSelector()
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt)?.nonEmptyOrNil
        if let list = try? c.decodeIfPresent([String].self, forKey: .sources) {
            sources = list
        } else if let one = try c.decodeIfPresent(String.self, forKey: .sources) ?? c.decodeIfPresent(
            String.self, forKey: .source)
        {
            sources = [one]
        } else {
            sources = []
        }
        width = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .width)
        height = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .height)
        steps = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .steps)
        guidance = try c.decodeIfPresent(MediaValue<Double>.self, forKey: .guidance)
        strength = try c.decodeIfPresent(MediaValue<Double>.self, forKey: .strength)
        seed = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .seed)
        seedMode = try c.decodeIfPresent(MediaSeedMode.self, forKey: .seedMode)
        count = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .count)
        format = try c.decodeIfPresent(ImageOutputFormat.self, forKey: .format)
        scale = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .scale)
        duration = try Self.decodeLooseString(c, .duration)
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution)?.nonEmptyOrNil
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio)?.nonEmptyOrNil
        audio = try c.decodeIfPresent(MediaValue<Bool>.self, forKey: .audio)
        batchSize = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .batchSize)
        sampler = try c.decodeIfPresent(String.self, forKey: .sampler)?.nonEmptyOrNil
        scheduler = try c.decodeIfPresent(String.self, forKey: .scheduler)?.nonEmptyOrNil
        shift = try c.decodeIfPresent(MediaValue<Double>.self, forKey: .shift)
        previewInterval = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .previewInterval)
        frameCount = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .frameCount)
        fps = try c.decodeIfPresent(MediaValue<Int>.self, forKey: .fps)
    }

    /// `duration: 5` and `duration: "5"` both mean five seconds.
    private static func decodeLooseString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return BindingRenderer.textValue(.number(n)) }
        return try c.decodeIfPresent(String.self, forKey: key)?.nonEmptyOrNil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(model, forKey: .model)
        if action.usesPrompt || !prompt.isEmpty { try c.encode(prompt, forKey: .prompt) }
        try c.encodeIfPresent(negativePrompt, forKey: .negativePrompt)
        if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(steps, forKey: .steps)
        try c.encodeIfPresent(guidance, forKey: .guidance)
        try c.encodeIfPresent(strength, forKey: .strength)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(seedMode, forKey: .seedMode)
        try c.encodeIfPresent(count, forKey: .count)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(audio, forKey: .audio)
        try c.encodeIfPresent(batchSize, forKey: .batchSize)
        try c.encodeIfPresent(sampler, forKey: .sampler)
        try c.encodeIfPresent(scheduler, forKey: .scheduler)
        try c.encodeIfPresent(shift, forKey: .shift)
        try c.encodeIfPresent(previewInterval, forKey: .previewInterval)
        try c.encodeIfPresent(frameCount, forKey: .frameCount)
        try c.encodeIfPresent(fps, forKey: .fps)
    }

    public var effectiveSeedMode: MediaSeedMode { seedMode ?? (seed == nil ? .random : .fixed) }

    /// The template strings this step renders, for binding checks.
    var templates: [String] {
        var out = [prompt] + sources
        if let negativePrompt { out.append(negativePrompt) }
        for value in [duration, resolution, aspectRatio, sampler, scheduler] { if let value { out.append(value) } }
        let bound: [String?] = [
            width?.binding, height?.binding, steps?.binding, guidance?.binding, strength?.binding, seed?.binding,
            count?.binding, scale?.binding, audio?.binding, batchSize?.binding, shift?.binding,
            previewInterval?.binding, frameCount?.binding, fps?.binding,
        ]
        out += bound.compactMap { $0 }
        return out
    }

    /// Parameter keys a node `input` object may override at run time, in
    /// the spelling the JSON uses.
    public static let overridableKeys: Set<String> = [
        "prompt", "negative_prompt", "sources", "width", "height", "steps", "guidance", "strength", "seed",
        "seed_mode", "count", "format", "scale", "duration", "resolution", "aspect_ratio", "audio", "batch_size",
        "sampler", "scheduler", "shift", "preview_interval", "frame_count", "fps",
    ]

    /// What the step outputs. `path` fields carry `format: "image"` or
    /// `"video"` so a binding into another step's `sources` can be checked
    /// before the run.
    public static let outputSchema: JSONValue = {
        func string(_ format: String? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["type": .string("string")]
            if let format { o["format"] = .string(format) }
            return .object(o)
        }
        let number: JSONValue = .object(["type": .string("number")])
        let integer: JSONValue = .object(["type": .string("integer")])
        // What the engine ran, for families that report it; absent otherwise.
        let effective: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "width": integer, "height": integer, "steps": integer, "guidance": number, "seed": number,
                "sampler": string(), "scheduler": string(), "shift": number, "strength": number, "scale": integer,
                "modelRevision": string(),
                "sampleSigmas": .object(["type": .string("array"), "items": number]),
            ]),
        ])
        let effectiveVideo: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "width": integer, "height": integer, "frame_count": integer, "fps": integer, "steps": integer,
                "guidance": number, "seed": number, "sampler": string(), "scheduler": string(), "shift": number,
            ]),
        ])
        let image: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": string("image"), "url": string(), "seed": number, "width": integer, "height": integer,
                "format": string(), "effective_parameters": effective,
            ]),
            "required": .array([.string("path")]),
        ])
        let video: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": string("video"), "url": string(), "mime_type": string(), "effective_parameters": effectiveVideo,
            ]),
            "required": .array([.string("path")]),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "images": .object(["type": .string("array"), "items": image]),
                "videos": .object(["type": .string("array"), "items": video]),
                "model": string(),
                "backend": string(),
                "count": integer,
                "duration_ms": integer,
                "bypassed": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("images"), .string("videos"), .string("model"), .string("count")]),
        ])
    }()

    /// One line for summaries: "Makes 4 images with qwen-image-2.1".
    public var summary: String {
        let model = self.model.label
        switch action {
        case .generate:
            if let n = count?.staticValue, n > 1 { return L("Makes \(n) images with \(model)") }
            return L("Makes an image with \(model)")
        case .edit: return L("Edits an image with \(model)")
        case .upscale:
            if let s = scale?.staticValue { return L("Upscales an image \(s)× with \(model)") }
            return L("Upscales an image with \(model)")
        case .video: return L("Makes a video with \(model)")
        }
    }
}

/// A media model a workflow needs on this Mac: what it must do, and which
/// family or model.
public struct MediaModelRequirement: Codable, Equatable, Sendable, Hashable, Identifiable {
    public var action: MediaAction
    public var model: MediaModelSelector

    public init(action: MediaAction, model: MediaModelSelector) {
        self.action = action
        self.model = model
    }

    public var id: String { "\(action.rawValue):\(model.id ?? model.family ?? "*"):\(model.locality.rawValue)" }

    /// "Image generation (qwen-image-2.1)".
    public var label: String {
        let what: String
        switch action {
        case .generate: what = L("Image generation")
        case .edit: what = L("Image editing")
        case .upscale: what = L("Image upscaling")
        case .video: what = L("Video generation")
        }
        guard let name = model.id ?? model.family else { return what }
        return "\(what) (\(name))"
    }
}

// MARK: - Node mode

/// Whether a step runs. A bypassed step does not run: it hands its input
/// straight to the steps after it (a media edit or upscale hands on its
/// sources as `images`), so a long chain can be switched off in parts
/// while iterating.
public enum NodeMode: String, Codable, Sendable, CaseIterable {
    case always
    case bypass
}

extension MediaSpec {
    /// The nearest size Qwen-Image 2.1 takes when `value` is off its grid
    /// (steps of 32, 32 through 2048), else nil. Other families take what
    /// their adapter takes.
    static func qwen21SizeFix(_ value: Int) -> Int? {
        let maximum = ImageModelRequestPolicy.q21MaximumDimension
        guard value % 32 != 0 || !(32 ... maximum).contains(value) else { return nil }
        return min(maximum, max(32, Int((Double(value) / 32).rounded()) * 32))
    }
}

extension MediaModelSelector {
    /// Whether this pins the Qwen-Image 2.1 family, by family or model id.
    var selectsQwen21: Bool {
        [family, id].compactMap { $0 }.contains {
            ImageModelRequestPolicy.isQwen21Family($0.lowercased())
                || ImageModelRequestPolicy.isQwen21Family(ImageModelRequestPolicy.catalogCanonical($0))
        }
    }
}

extension WorkflowNode {
    /// The node's definition and the input it ran with, hashed: equal when
    /// running it again would do the same thing.
    func specHash(input: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let node = (try? encoder.encode(self)) ?? Data()
        let digest = SHA256.hash(data: node + Data(input.compactJSONString.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// What a bypassed node binds as: a media step's sources as `images`,
    /// any other step's rendered input.
    func bypassOutput(input: JSONValue, bindings: BindingContext) -> JSONValue {
        guard case .media(let spec) = kind else {
            return input.isEmptyObject ? .object([:]) : input
        }
        let images = MediaSourceList.paths(spec.sources, overrides: input, in: bindings).map { path in
            JSONValue.object(["path": .string(path), "url": .string(URL(fileURLWithPath: path).absoluteString)])
        }
        return .object([
            "images": .array(images),
            "videos": .array([]),
            "model": .string(""),
            "backend": .string("bypassed"),
            "count": .number(Double(images.count)),
            "bypassed": .bool(true),
        ])
    }

    /// Whether bypassing leaves later steps anything to work with.
    var bypassPassesData: Bool {
        if case .media(let spec) = kind { return spec.action.usesSources && !spec.sources.isEmpty }
        switch input {
        case .template(let t): return !t.trimmingCharacters(in: .whitespaces).isEmpty
        case .object, .values: return !input.fieldNames.isEmpty
        }
    }
}

/// Source paths from a step's `sources` templates (or an input override):
/// each may render to a path, a list of paths, `{path}` objects, or a
/// media step's `images` list.
enum MediaSourceList {
    static func paths(_ templates: [String], overrides: JSONValue, in ctx: BindingContext) -> [String] {
        if let override = overrides.objectValue?["sources"] { return paths(of: override) }
        return templates.flatMap { paths(of: BindingRenderer.renderValue($0, in: ctx)) }
    }

    static func paths(of value: JSONValue) -> [String] {
        switch value {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let list): return list.flatMap(paths(of:))
        case .object(let o):
            if let path = o["path"] { return paths(of: path) }
            if let images = o["images"] { return paths(of: images) }
            return []
        default: return []
        }
    }
}
