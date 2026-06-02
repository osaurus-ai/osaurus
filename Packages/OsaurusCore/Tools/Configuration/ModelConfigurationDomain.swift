//
//  ModelConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tools for local MLX models:
//   - osaurus_model_download
//   - osaurus_model_cancel_download
//   - osaurus_model_delete
//
//  Downloads are async by design — the tool returns immediately with
//  `status: "started"` and the model is expected to poll
//  `osaurus_status` / `osaurus_list({scope: 'models'})` to track
//  progress.
//

import Foundation

enum ModelConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "models",
        displayName: "Models",
        summary: "Local MLX language models. Download from Hugging Face, cancel, or delete.",
        menuHint: "download / cancel / delete local MLX models (mlx-community/* and other MLX-compatible repos)",
        searchKeywords: [
            "model", "models", "llm", "download", "huggingface", "mlx",
            "download model", "install model", "get a model",
            "cancel download", "stop download",
            "delete model", "remove model", "uninstall model",
        ],
        exampleQueries: [
            "download Llama 3",
            "get a small model that fits 8GB",
            "cancel the model download",
            "delete the old Llama model",
        ],
        tools: [
            OsaurusModelDownloadTool(),
            OsaurusModelCancelDownloadTool(),
            OsaurusModelDeleteTool(),
        ],
        writeToolNames: [
            "osaurus_model_download",
            "osaurus_model_cancel_download",
            "osaurus_model_delete",
        ]
    )
}

// MARK: - osaurus_model_download

public final class OsaurusModelDownloadTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_model_download"
    public let description =
        "Start downloading an MLX-compatible model from Hugging Face. Pass `repo_id` "
        + "(e.g. `mlx-community/Qwen2.5-7B-Instruct-4bit`). Returns immediately; "
        + "poll osaurus_status / osaurus_list(scope='models') to track progress."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "repo_id": .object([
                "type": .string("string"),
                "description": .string("Hugging Face repo id, e.g. `mlx-community/Llama-3.1-8B-Instruct-4bit`."),
            ])
        ]),
        "required": .array([.string("repo_id")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let req = requireString(args, "repo_id", expected: "Hugging Face repo id", tool: name)
        guard case .value(let repoId) = req else { return req.failureEnvelope ?? "" }

        let resolved = await ModelManager.shared.resolveModelIfMLXCompatible(byRepoId: repoId)
        guard let model = resolved else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(repoId)` is not MLX-compatible. Pass an `mlx-community/*` repo id, "
                    + "an `OsaurusAI/*` curated id, or any HF repo whose name signals an MLX build.",
                field: "repo_id",
                tool: name
            )
        }

        await MainActor.run { ModelManager.shared.downloadModel(model) }

        return ToolEnvelope.success(
            tool: name,
            result: [
                "model_id": model.id,
                "status": "started",
                "poll_with": "osaurus_status",
            ]
        )
    }
}

// MARK: - osaurus_model_cancel_download

public final class OsaurusModelCancelDownloadTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_model_cancel_download"
    public let description =
        "Cancel an in-flight model download. Pass the `id` returned by osaurus_model_download or osaurus_list."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["id": .object(["type": .string("string")])]),
        "required": .array([.string("id")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let req = requireString(args, "id", expected: "Model id", tool: name)
        guard case .value(let modelId) = req else { return req.failureEnvelope ?? "" }

        await MainActor.run { ModelManager.shared.cancelDownload(modelId) }

        return ToolEnvelope.success(
            tool: name,
            result: ["model_id": modelId, "status": "cancel_requested"]
        )
    }
}

// MARK: - osaurus_model_delete

public final class OsaurusModelDeleteTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_model_delete"
    public let description =
        "Delete a downloaded MLX model from disk. Refuses if the model is currently downloading; "
        + "cancel first via osaurus_model_cancel_download."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["id": .object(["type": .string("string")])]),
        "required": .array([.string("id")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let req = requireString(args, "id", expected: "Model id", tool: name)
        guard case .value(let modelId) = req else { return req.failureEnvelope ?? "" }

        // Resolve + validate on the main actor, then perform the (async)
        // delete outside the synchronous `MainActor.run` closure so the
        // unload/lease-drain can complete before we report success.
        enum Resolution {
            case failure(String)
            case delete(MLXModel)
        }
        let resolution: Resolution = await MainActor.run {
            let mgr = ModelManager.shared
            guard
                let model = mgr.availableModels.first(where: { $0.id == modelId })
                    ?? mgr.suggestedModels.first(where: { $0.id == modelId })
            else {
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "No model found with id `\(modelId)`.",
                        field: "id",
                        tool: name
                    )
                )
            }
            let state = mgr.effectiveDownloadState(for: model)
            if case .downloading = state {
                return .failure(
                    ToolEnvelope.failure(
                        kind: .executionError,
                        message:
                            "Model `\(modelId)` is currently downloading. "
                            + "Call osaurus_model_cancel_download first, then retry.",
                        tool: name,
                        retryable: true
                    )
                )
            }
            return .delete(model)
        }
        switch resolution {
        case .failure(let envelope):
            return envelope
        case .delete(let model):
            await ModelManager.shared.deleteModel(model)
            return ToolEnvelope.success(
                tool: name,
                result: ["model_id": modelId, "status": "deleted"]
            )
        }
    }
}
