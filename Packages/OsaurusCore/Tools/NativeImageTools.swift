//
//  NativeImageTools.swift
//  osaurus
//
//  Built-in tool surface for agent-launched native image jobs. One `image`
//  tool serves BOTH generation and editing: when `source_paths` is provided the
//  job edits those images, otherwise it generates a fresh one. The thin tool
//  parses + validates arguments and hands a configured `ImageSubagentKind` to
//  the shared `SubagentSession` host (recursion guard, live feed, compact
//  result, telemetry); the kind owns model resolution, permission, and the job.
//

import Foundation

public final class ImageTool: OsaurusTool, @unchecked Sendable {
    public let name = "image"

    /// Shared description, also shown in the permission prompt by the kind.
    public static let toolDescription =
        "Create or edit an image with the user's local native image model. To CREATE a new image, "
        + "call with just a `prompt` (use when the user asks to create, render, draw, make, or "
        + "generate an image). To EDIT an existing image, ALSO pass `source_paths` with one to four "
        + "local image paths from prior results or attachments (use when the user asks to transform, "
        + "recolor, modify, or add to an existing image) — `source_paths` is what switches the tool "
        + "into edit mode. The resulting image is automatically shown to the user in the chat; do "
        + "NOT call share_artifact on it."

    public var description: String { Self.toolDescription }

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "prompt": .object([
                "type": .string("string"),
                "description": .string(
                    "What to create, or — when `source_paths` is set — how to transform the source image(s)."
                ),
            ]),
            "source_paths": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Optional one to four local source image paths from prior results or attachments. "
                        + "Providing this switches the tool into EDIT mode; omit it to generate a new image."
                ),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional local image model id. Omit to use the configured default."),
            ]),
            "negative_prompt": .object([
                "type": .string("string"),
                "description": .string("Optional negative prompt."),
            ]),
            "width": .object(["type": .string("integer"), "description": .string("Optional width in pixels.")]),
            "height": .object(["type": .string("integer"), "description": .string("Optional height in pixels.")]),
            "steps": .object(["type": .string("integer"), "description": .string("Optional denoise step count.")]),
            "guidance": .object(["type": .string("number"), "description": .string("Optional guidance scale.")]),
            "strength": .object([
                "type": .string("number"),
                "description": .string("Optional edit strength, 0...1 (edit mode only)."),
            ]),
            "seed": .object(["type": .string("integer"), "description": .string("Optional deterministic seed.")]),
            "num_images": .object([
                "type": .string("integer"),
                "description": .string("Optional number of images (generation only), clamped to 1...4."),
            ]),
        ]),
        "required": .array([.string("prompt")]),
    ])

    public init() {}

    public var bypassRegistryTimeout: Bool { true }

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let promptReq = requireString(args, "prompt", expected: "non-empty image prompt", tool: name)
        guard case .value(let prompt) = promptReq else { return promptReq.failureEnvelope ?? "" }

        let params = Self.buildParams(args: args, prompt: prompt)
        return await SubagentSession.run(
            ImageSubagentKind(params: params, argumentsJSON: argumentsJSON),
            tool: name
        )
    }

    /// Build the parsed/validated `image` job params from a decoded argument
    /// dictionary. Extracted from `execute` so the `source_paths` → edit routing
    /// and clamping are covered model-free. `source_paths` presence (after
    /// trimming + dropping empties) is the single switch into edit mode.
    static func buildParams(args: [String: Any], prompt: String) -> ImageJobParams {
        let sourcePaths =
            ArgumentCoercion.stringArray(args["source_paths"])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        return ImageJobParams(
            prompt: prompt,
            sourcePaths: sourcePaths,
            model: optionalString(args["model"]),
            negativePrompt: optionalString(args["negative_prompt"]),
            width: ArgumentCoercion.int(args["width"]).map(clampedDimension),
            height: ArgumentCoercion.int(args["height"]).map(clampedDimension),
            steps: ArgumentCoercion.int(args["steps"]).map { min(50, max(1, $0)) },
            guidance: optionalFloat(args["guidance"]).map { min(20, max(0, $0)) },
            strength: optionalFloat(args["strength"]),
            seed: optionalUInt64(args["seed"]),
            numImages: ArgumentCoercion.int(args["num_images"])
        )
    }

    // MARK: - Argument coercion

    private static func optionalString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalUInt64(_ raw: Any?) -> UInt64? {
        if let int = ArgumentCoercion.int(raw), int >= 0 {
            return UInt64(int)
        }
        if let string = raw as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func optionalFloat(_ raw: Any?) -> Float? {
        if let float = raw as? Float { return float }
        if let double = raw as? Double { return Float(double) }
        if let number = raw as? NSNumber { return number.floatValue }
        if let string = raw as? String {
            return Float(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func clampedDimension(_ value: Int) -> Int {
        let bounded = min(1024, max(256, value))
        let rounded = (bounded / 16) * 16
        return max(256, rounded)
    }
}
