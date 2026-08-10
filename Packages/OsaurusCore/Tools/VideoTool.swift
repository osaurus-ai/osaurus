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

    var isImageToVideo: Bool { sourcePath != nil }
}

public final class VideoTool: OsaurusTool, @unchecked Sendable {
    public let name = "video"
    public static let toolDescription =
        "Generate a billable video from text or one source image. A current price quote is included "
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
                "description": .string("Catalog-supported duration such as `5s` or `10s`."),
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
            expected: "catalog-supported duration",
            tool: name
        )
        guard case .value(let duration) = durationReq else {
            return durationReq.failureEnvelope ?? ""
        }
        let params = VideoJobParams(
            prompt: prompt,
            sourcePath: Self.optionalString(args["source_path"]),
            model: Self.optionalString(args["model"]),
            negativePrompt: Self.optionalString(args["negative_prompt"]),
            duration: duration,
            resolution: Self.optionalString(args["resolution"]),
            aspectRatio: Self.optionalString(args["aspect_ratio"]),
            audio: args["audio"] as? Bool
        )
        return await SubagentSession.run(
            VideoSubagentKind(params: params, argumentsJSON: argumentsJSON),
            tool: name
        )
    }

    private static func optionalString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
