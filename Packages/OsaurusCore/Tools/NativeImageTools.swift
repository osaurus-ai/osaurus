//
//  NativeImageTools.swift
//  osaurus
//
//  Built-in tool surface for agent-launched native image jobs.
//

import Foundation

public final class NativeImageGenerateTool: OsaurusTool, @unchecked Sendable {
    public let name = "image_generate"
    public let description =
        "Generate an image using the user's local native image model. Use this when the user asks "
        + "to create, render, draw, or generate an image. The result returns saved image paths and "
        + "the native job progress log. Do not use for editing an existing image."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "prompt": .object([
                "type": .string("string"),
                "description": .string("Detailed prompt describing the image to generate."),
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
            "seed": .object(["type": .string("integer"), "description": .string("Optional deterministic seed.")]),
            "num_images": .object([
                "type": .string("integer"),
                "description": .string("Optional number of images, clamped to 1...4."),
            ]),
        ]),
        "required": .array([.string("prompt")]),
    ])

    public init() {}

    public var bypassRegistryTimeout: Bool { true }

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let promptReq = requireString(
            args,
            "prompt",
            expected: "non-empty image prompt",
            tool: name
        )
        guard case .value(let prompt) = promptReq else { return promptReq.failureEnvelope ?? "" }

        let config = AgentDelegationConfigurationStore.snapshot()
        if let denied = await permissionDenialIfNeeded(config: config, argumentsJSON: argumentsJSON) {
            return denied
        }

        let request = NativeImageGenerateJobRequest(
            prompt: prompt,
            model: optionalStringValue(args["model"]),
            negativePrompt: optionalStringValue(args["negative_prompt"]),
            width: optionalIntValue(args["width"]).map(Self.clampedDimension),
            height: optionalIntValue(args["height"]).map(Self.clampedDimension),
            steps: optionalIntValue(args["steps"]).map { min(50, max(1, $0)) },
            guidance: optionalFloatValue(args["guidance"]).map { min(20, max(0, $0)) },
            seed: optionalUInt64Value(args["seed"]),
            numImages: optionalIntValue(args["num_images"]) ?? 1,
            outputFormat: .png
        )

        do {
            let stream = await NativeImageJobCoordinator.shared.generate(request)
            var finalResult: NativeImageJobResult?
            for try await result in stream {
                finalResult = result
            }
            guard let finalResult else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "image generation finished without a result",
                    tool: name,
                    retryable: false
                )
            }
            return ToolEnvelope.success(tool: name, result: finalResult.toolPayload)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: String(describing: error),
                tool: name,
                retryable: false
            )
        }
    }

    private func permissionDenialIfNeeded(
        config: AgentDelegationConfiguration,
        argumentsJSON: String
    ) async -> String? {
        switch config.permissionDefaults.imageGenerate {
        case .deny:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Image generation is denied by Agent Delegation settings.",
                tool: name,
                retryable: false
            )
        case .alwaysAllow:
            return nil
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts {
                return nil
            }
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: name,
                description: description,
                argumentsJSON: argumentsJSON
            )
            if approved { return nil }
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "User denied image generation.",
                tool: name,
                retryable: false
            )
        }
    }

    private func optionalStringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalIntValue(_ raw: Any?) -> Int? {
        ArgumentCoercion.int(raw)
    }

    private func optionalUInt64Value(_ raw: Any?) -> UInt64? {
        if let int = ArgumentCoercion.int(raw), int >= 0 {
            return UInt64(int)
        }
        if let string = raw as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func optionalFloatValue(_ raw: Any?) -> Float? {
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

public final class NativeImageEditTool: OsaurusTool, @unchecked Sendable {
    public let name = "image_edit"
    public let description =
        "Edit one or more existing local images using the user's local native image edit model. "
        + "Use this only when the user asks to transform an existing image and you have explicit "
        + "local source image paths from prior artifacts or attachments."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "prompt": .object([
                "type": .string("string"),
                "description": .string("Edit instruction describing how to transform the source image."),
            ]),
            "source_paths": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("One to four local source image paths from artifacts or attachments."),
            ]),
            "model": .object([
                "type": .string("string"),
                "description": .string("Optional local image edit model id. Omit to use the configured default."),
            ]),
            "negative_prompt": .object(["type": .string("string"), "description": .string("Optional negative prompt.")]),
            "width": .object(["type": .string("integer"), "description": .string("Optional width in pixels.")]),
            "height": .object(["type": .string("integer"), "description": .string("Optional height in pixels.")]),
            "steps": .object(["type": .string("integer"), "description": .string("Optional denoise step count.")]),
            "guidance": .object(["type": .string("number"), "description": .string("Optional guidance scale.")]),
            "strength": .object(["type": .string("number"), "description": .string("Optional edit strength, 0...1.")]),
            "seed": .object(["type": .string("integer"), "description": .string("Optional deterministic seed.")]),
        ]),
        "required": .array([.string("prompt"), .string("source_paths")]),
    ])

    public init() {}

    public var bypassRegistryTimeout: Bool { true }

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let promptReq = requireString(args, "prompt", expected: "non-empty image edit instruction", tool: name)
        guard case .value(let prompt) = promptReq else { return promptReq.failureEnvelope ?? "" }

        let pathsReq = requireStringArray(
            args,
            "source_paths",
            expected: "one to four local source image paths",
            tool: name
        )
        guard case .value(let sourcePaths) = pathsReq else { return pathsReq.failureEnvelope ?? "" }

        let config = AgentDelegationConfigurationStore.snapshot()
        if let denied = await permissionDenialIfNeeded(config: config, argumentsJSON: argumentsJSON) {
            return denied
        }

        let sources: [Data]
        do {
            sources = try Self.loadSourceImages(paths: sourcePaths)
        } catch {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: String(describing: error),
                field: "source_paths",
                expected: "existing local image files under 80 MB each",
                tool: name,
                retryable: false
            )
        }

        let request = NativeImageEditJobRequest(
            prompt: prompt,
            model: optionalStringValue(args["model"]),
            sourceImages: sources,
            negativePrompt: optionalStringValue(args["negative_prompt"]),
            width: optionalIntValue(args["width"]).map(Self.clampedDimension),
            height: optionalIntValue(args["height"]).map(Self.clampedDimension),
            steps: optionalIntValue(args["steps"]).map { min(50, max(1, $0)) },
            guidance: optionalFloatValue(args["guidance"]).map { min(20, max(0, $0)) },
            strength: optionalFloatValue(args["strength"]) ?? 0.75,
            seed: optionalUInt64Value(args["seed"]),
            outputFormat: .png
        )

        do {
            let stream = await NativeImageJobCoordinator.shared.edit(request)
            var finalResult: NativeImageJobResult?
            for try await result in stream {
                finalResult = result
            }
            guard let finalResult else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "image edit finished without a result",
                    tool: name,
                    retryable: false
                )
            }
            return ToolEnvelope.success(tool: name, result: finalResult.toolPayload)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: String(describing: error),
                tool: name,
                retryable: false
            )
        }
    }

    private func permissionDenialIfNeeded(
        config: AgentDelegationConfiguration,
        argumentsJSON: String
    ) async -> String? {
        switch config.permissionDefaults.imageEdit {
        case .deny:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Image edit is denied by Agent Delegation settings.",
                tool: name,
                retryable: false
            )
        case .alwaysAllow:
            return nil
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts {
                return nil
            }
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: name,
                description: description,
                argumentsJSON: argumentsJSON
            )
            if approved { return nil }
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "User denied image edit.",
                tool: name,
                retryable: false
            )
        }
    }

    private static func loadSourceImages(paths: [String]) throws -> [Data] {
        let trimmed = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty, trimmed.count <= 4 else {
            throw NativeImageToolInputError.invalidSourceCount
        }
        return try trimmed.map { path in
            let url = URL.osaurusFileURL(path)
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp", "heic"].contains(ext) else {
                throw NativeImageToolInputError.unsupportedExtension(path)
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw NativeImageToolInputError.notAFile(path)
            }
            if let size = values.fileSize, size > 80 * 1024 * 1024 {
                throw NativeImageToolInputError.fileTooLarge(path)
            }
            return try Data(contentsOf: url)
        }
    }

    private func optionalStringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalIntValue(_ raw: Any?) -> Int? {
        ArgumentCoercion.int(raw)
    }

    private func optionalUInt64Value(_ raw: Any?) -> UInt64? {
        if let int = ArgumentCoercion.int(raw), int >= 0 {
            return UInt64(int)
        }
        if let string = raw as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func optionalFloatValue(_ raw: Any?) -> Float? {
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

private enum NativeImageToolInputError: Error, CustomStringConvertible {
    case invalidSourceCount
    case unsupportedExtension(String)
    case notAFile(String)
    case fileTooLarge(String)

    var description: String {
        switch self {
        case .invalidSourceCount:
            return "source_paths must contain one to four image paths"
        case .unsupportedExtension(let path):
            return "unsupported source image extension: \(path)"
        case .notAFile(let path):
            return "source image path is not a regular file: \(path)"
        case .fileTooLarge(let path):
            return "source image exceeds 80 MB limit: \(path)"
        }
    }
}

private extension URL {
    static func osaurusFileURL(_ path: String) -> URL {
        if let url = URL(string: path), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: path)
    }
}
