//
//  ModelConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for local MLX models. One tool,
//  `osaurus_model`, fans out across three actions:
//   - download  (async; returns `status: "started"`, poll osaurus_status)
//   - cancel    (cancel an in-flight download)
//   - delete    (remove a downloaded model from disk)
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
            OsaurusModelTool()
        ],
        writeToolNames: [
            "osaurus_model"
        ]
    )
}

// MARK: - osaurus_model

public final class OsaurusModelTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_model"
    public let description =
        "Manage local MLX models. `action`: download (needs `repo_id`, e.g. "
        + "`mlx-community/Qwen2.5-7B-Instruct-4bit`; returns immediately — poll osaurus_status), "
        + "cancel (needs the model `id` or `repo_id`), delete (needs the model `id` or "
        + "`repo_id`; cancel an in-flight download first)."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("download"), .string("cancel"), .string("delete")]),
                "description": .string("Operation to perform."),
            ]),
            "repo_id": .object([
                "type": .string("string"),
                "description": .string(
                    "Hugging Face repo id. Required for download; also accepted to "
                        + "identify the model for cancel / delete."
                ),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string(
                    "Model id (the repo path used to download). Identifies the model "
                        + "for cancel / delete; `repo_id` is accepted as an equivalent."
                ),
            ]),
        ]),
        "required": .array([.string("action")]),
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
        let actionReq = requireAction(args, allowed: ["download", "cancel", "delete"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "download": return await handleDownload(args)
        case "cancel": return await handleCancel(args)
        case "delete": return await handleDelete(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    private func handleDownload(_ args: [String: Any]) async -> String {
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

    /// Resolve the model identifier for cancel / delete from either `id` or
    /// `repo_id`. A download started via `repo_id` is keyed by `model.id`,
    /// which IS that repo path, so a user (or model) naturally refers to the
    /// same `repo_id` when cancelling or deleting. Requiring the exact `id`
    /// field while `download` takes `repo_id` is an inconsistent contract that
    /// traps a model into a `repo_id` cancel the tool would otherwise reject;
    /// accepting either field removes that trap without changing what gets
    /// cancelled/deleted. Prefers `id`, falls back to `repo_id`.
    private func modelIdentifier(from args: [String: Any]) -> String? {
        for key in ["id", "repo_id"] {
            if let raw = args[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func handleCancel(_ args: [String: Any]) async -> String {
        guard let modelId = modelIdentifier(from: args) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Provide the model `id` (or its `repo_id`) to cancel.",
                field: "id",
                tool: name
            )
        }

        await MainActor.run { ModelManager.shared.cancelDownload(modelId) }

        return ToolEnvelope.success(
            tool: name,
            result: ["model_id": modelId, "status": "cancel_requested"]
        )
    }

    private func handleDelete(_ args: [String: Any]) async -> String {
        guard let modelId = modelIdentifier(from: args) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Provide the model `id` (or its `repo_id`) to delete.",
                field: "id",
                tool: name
            )
        }

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
                            + "Call osaurus_model({action: 'cancel', id: '\(modelId)'}) first, then retry.",
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
