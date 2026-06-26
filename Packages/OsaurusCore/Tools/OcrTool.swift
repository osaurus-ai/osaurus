//
//  OcrTool.swift
//  osaurus
//
//  `ocr(images, model?, prompt?)` — extract text from one or more local images
//  using a configured local OCR VLM (DeepSeek-OCR / Unlimited-OCR). Resolves the
//  per-agent OCR model, runs a bounded multimodal completion on it (with the
//  single-residency handoff when the OCR model displaces a resident chat model),
//  and returns only the extracted text. Default OFF; each agent opts in from its
//  Sub-agents tab. The shared host (`SubagentSession`) owns the recursion guard,
//  live feed, permission verdict, residency handoff, and result normalization.
//

import Foundation

public final class OcrTool: OsaurusTool, @unchecked Sendable {
    public let name = "ocr"

    public static let toolDescription =
        "Extract text from one or more local images using your local OCR model. Pass one to four image "
        + "file paths in `images`; the recognized text is returned as a structured result. Use when the "
        + "user asks to read, transcribe, extract, or recognize text in images."

    public var description: String { Self.toolDescription }

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "images": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("One to four local image file paths to extract text from."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional OCR model id. Omit to use the configured default."),
            ]),
            "prompt": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional grounding/extraction instruction. Omit to use the default grounding prompt."
                ),
            ]),
        ]),
        "required": .array([.string("images")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let imagesReq = requireStringArray(
            args,
            "images",
            expected: "one to four image file paths",
            tool: name
        )
        guard case .value(let rawPaths) = imagesReq else { return imagesReq.failureEnvelope ?? "" }
        let imagePaths =
            rawPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let params = OcrJobParams(
            imagePaths: imagePaths,
            model: Self.optionalString(args["model"]),
            prompt: Self.optionalString(args["prompt"])
        )

        // The shared host owns the recursion guard, live feed, permission
        // verdict, residency handoff, compact-result normalization, and
        // telemetry; the kind owns model resolution + the bounded OCR loop.
        return await SubagentSession.run(
            OcrSubagentKind(params: params, argumentsJSON: argumentsJSON),
            tool: name
        )
    }

    private static func optionalString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
