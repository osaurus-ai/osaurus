//
//  VideoTool.swift
//  osaurus
//

import Foundation

struct VideoJobParams: Sendable {
    var prompt: String
    var sourcePath: String?
    var model: String?
    var negativePrompt: String?
    var duration: String
    var resolution: String?
    var aspectRatio: String?
    var audio: Bool?
    var width: Int? = nil
    var height: Int? = nil
    var frameCount: Int? = nil
    var fps: Int? = nil
    var steps: Int? = nil
    var guidance: Float? = nil
    var seed: UInt64? = nil

    var isImageToVideo: Bool { sourcePath != nil }
}

public final class VideoTool: OsaurusTool, @unchecked Sendable {
    public let name = "video"
    public static let toolDescription =
        "Generate a video locally or with a configured remote provider, from text or one source image. A current price quote is included "
        + "in the approval request before the job is queued. The completed video is shown automatically."

    public var description: String { Self.toolDescription }
    public var bypassRegistryTimeout: Bool { true }

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "prompt": .object([
                "type": .string("string"),
                "description": .string("What the video should show."),
            ]),
            "source_path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional local PNG/JPEG/WebP source image. Providing it selects image-to-video."
                ),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional configured media model id."),
            ]),
            "negative_prompt": .object([
                "type": .string("string"),
                "description": .string("Optional negative prompt."),
            ]),
            "duration": .object([
                "type": .string("string"),
                "description": .string("Cloud: a catalog-supported duration. Local: exact frame_count/fps in seconds, e.g. `3.0625s` for 49 frames at 16 fps."),
            ]),
            "resolution": .object([
                "type": .string("string"),
                "description": .string("Optional catalog-supported resolution such as `720p`."),
            ]),
            "aspect_ratio": .object([
                "type": .string("string"),
                "description": .string("Optional catalog-supported aspect ratio such as `16:9`."),
            ]),
            "audio": .object([
                "type": .string("boolean"),
                "description": .string("Optional audio generation setting when the model supports it."),
            ]),
            "width": .object(["type": .string("integer"), "description": .string("Local video width, a multiple of 16.")]),
            "height": .object(["type": .string("integer"), "description": .string("Local video height, a multiple of 16.")]),
            "frame_count": .object(["type": .string("integer"), "description": .string("Local video frames, 4n+1; duration must equal frame_count/fps.")]),
            "fps": .object(["type": .string("integer"), "description": .string("Local video frame rate. Default 16.")]),
            "steps": .object(["type": .string("integer"), "description": .string("Local denoise steps. Default 50.")]),
            "guidance": .object(["type": .string("number"), "description": .string("Local classifier-free guidance. Default 5.")]),
            "seed": .object(["type": .string("integer"), "minimum": .number(0), "description": .string("Optional local video seed.")]),
        ]),
        "required": .array([.string("prompt"), .string("duration")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let promptReq = requireString(args, "prompt", expected: "non-empty video prompt", tool: name)
        guard case .value(let prompt) = promptReq else { return promptReq.failureEnvelope ?? "" }
        let durationReq = requireString(
            args,
            "duration",
            expected: "catalog-supported cloud duration, or exact local frame_count/fps",
            tool: name
        )
        guard case .value(let duration) = durationReq else {
            return durationReq.failureEnvelope ?? ""
        }
        let local: LocalOptions
        do { local = try JSONDecoder().decode(LocalOptions.self, from: Data(argumentsJSON.utf8)) }
        catch { throw MediaGenerationError.invalidRequest("Local video controls must use their declared numeric types.") }
        let params = VideoJobParams(
            prompt: prompt,
            sourcePath: Self.optionalString(args["source_path"]),
            model: Self.optionalString(args["model"]),
            negativePrompt: Self.optionalString(args["negative_prompt"]),
            duration: duration,
            resolution: Self.optionalString(args["resolution"]),
            aspectRatio: Self.optionalString(args["aspect_ratio"]),
            audio: args["audio"] as? Bool,
            width: local.width, height: local.height, frameCount: local.frame_count,
            fps: local.fps, steps: local.steps, guidance: local.guidance, seed: local.seed
        )
        return await SubagentSession.run(
            VideoSubagentKind(params: params, argumentsJSON: argumentsJSON),
            tool: name
        )
    }

    private struct LocalOptions: Decodable {
        var width: Int?
        var height: Int?
        var frame_count: Int?
        var fps: Int?
        var steps: Int?
        var guidance: Float?
        var seed: UInt64?
    }

    private static func optionalString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
