//
//  VideoSubagentKind.swift
//  osaurus
//

import Foundation

final class VideoSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.video

    private let params: VideoJobParams
    private let argumentsJSON: String
    private var selectedModel: MediaModelInfo?
    private var approvedQuote: MediaVideoQuote?

    init(params: VideoJobParams, argumentsJSON: String) {
        self.params = params
        self.argumentsJSON = argumentsJSON
    }

    var feedTitle: String {
        let value = params.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "video: \(value.count > 72 ? String(value.prefix(72)) + "…" : value)"
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        guard
            SubagentToolVisibility.videoAvailable(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: settings?.videoEnabled ?? false
            )
        else {
            throw SubagentError.denied("Video generation is not enabled for this agent.")
        }

        let candidates = await MainActor.run {
            ModelPickerItemCache.shared.items.videoGenerationDelegateCandidates
                .compactMap(\.mediaModel)
                .filter { $0.kind == (params.isImageToVideo ? .imageToVideo : .textToVideo) }
        }
        let configured = SubagentToolVisibility.effectiveVideoTarget(
            imageToVideo: params.isImageToVideo,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        let model: MediaModelInfo?
        if let requested = params.model {
            let matches = candidates.filter {
                $0.id == requested || $0.target.modelID == requested
            }
            model = matches.count == 1 ? matches[0] : nil
        } else if let configured {
            model = candidates.first { $0.target == configured }
        } else {
            model = candidates.first
        }
        guard let model else {
            throw SubagentError.unavailable(
                params.isImageToVideo
                    ? "No configured image-to-video model is available."
                    : "No configured text-to-video model is available."
            )
        }
        try Self.validate(params: params, model: model)
        selectedModel = model
        return ResolvedModel(name: model.displayName, id: model.id, isLocal: false)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        guard let model = selectedModel else {
            return .denied("The selected video model is no longer available.")
        }
        let request = makeRequest(model: model, source: nil)
        let quote: MediaVideoQuote
        do {
            quote = try await MediaGenerationCoordinator.shared.quoteVideo(request)
            approvedQuote = quote
        } catch {
            return .denied("Could not quote this video: \(error.localizedDescription)")
        }

        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        let policy = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        switch policy {
        case .deny:
            return .denied("Video generation is denied by this agent's permission settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts { return .allow }
            let enriched = SubagentApprovalArguments.enrichedJSON(
                from: argumentsJSON,
                values: [
                    "resolved_model": model.displayName,
                    "quote_usd": quote.usd,
                    "billing_notice": "This queues a billable remote video job.",
                ]
            )
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "video",
                description: VideoTool.toolDescription,
                argumentsJSON: enriched
            )
            return approved ? .allow : .userDenied("User denied the quoted video generation.")
        }
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        guard let model = selectedModel, let quote = approvedQuote else {
            throw SubagentError.executionFailed(
                message: "The video quote or model expired before execution.",
                retryable: true
            )
        }
        let source: (Data, String)? = try params.sourcePath.map(Self.loadSourceImage)
        let request = makeRequest(model: model, source: source)
        feed.emitPhase("quoted", detail: String(format: "$%.4f", quote.usd))
        do {
            let media = try await MediaGenerationCoordinator.shared.generateVideo(
                request,
                approvedQuote: quote
            ) { event in
                switch event {
                case .queued(let id):
                    feed.emitPhase("queued", detail: id)
                case .running(_, let eta):
                    feed.emitProgress(
                        "generating video",
                        fraction: nil,
                        step: 0,
                        detail: eta.map { String(format: "~%.0fs left", $0) }
                    )
                case .completed:
                    break
                case .failed(let message):
                    feed.emitPhase("failed", detail: message)
                case .cancelled:
                    feed.emitPhase("cancelled")
                }
            }
            let payload: [String: Any] = [
                "kind": "generated_media_job",
                "media_type": "video",
                "job_id": media.url.deletingPathExtension().lastPathComponent,
                "model": media.modelID,
                "status": "completed",
                "quote_usd": quote.usd,
                "already_displayed": true,
                "display_note":
                    "The video is already shown to the user; do NOT call share_artifact for it.",
                "media": [
                    "path": media.url.path,
                    "url": media.url.absoluteString,
                    "mime_type": media.mimeType,
                ],
            ]
            return SubagentResult(payload: payload, summary: "Generated a video with \(resolved.name).")
        } catch let error as MediaGenerationError {
            let retryable: Bool
            switch error {
            case .transport, .queuedJobContinues:
                retryable = true
            default:
                retryable = false
            }
            throw SubagentError.executionFailed(
                message: error.localizedDescription,
                retryable: retryable
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubagentError.executionFailed(
                message: error.localizedDescription,
                retryable: false
            )
        }
    }

    private func makeRequest(
        model: MediaModelInfo,
        source: (Data, String)?
    ) -> MediaVideoGenerationRequest {
        MediaVideoGenerationRequest(
            target: model.target,
            prompt: params.prompt,
            negativePrompt: params.negativePrompt,
            sourceImage: source?.0,
            sourceImageMIMEType: source?.1,
            duration: params.duration,
            aspectRatio: params.aspectRatio,
            resolution: params.resolution,
            audio: params.audio
        )
    }

    private static func validate(params: VideoJobParams, model: MediaModelInfo) throws {
        let c = model.constraints
        if !c.durations.isEmpty, !c.durations.contains(params.duration) {
            throw SubagentError.invalidArgs(
                message: "Unsupported duration for \(model.displayName).",
                field: "duration",
                expected: c.durations.joined(separator: ", ")
            )
        }
        if let resolution = params.resolution,
            !c.resolutions.isEmpty,
            !c.resolutions.contains(resolution)
        {
            throw SubagentError.invalidArgs(
                message: "Unsupported resolution for \(model.displayName).",
                field: "resolution",
                expected: c.resolutions.joined(separator: ", ")
            )
        }
        if let ratio = params.aspectRatio,
            !c.aspectRatios.isEmpty,
            !c.aspectRatios.contains(ratio)
        {
            throw SubagentError.invalidArgs(
                message: "Unsupported aspect ratio for \(model.displayName).",
                field: "aspect_ratio",
                expected: c.aspectRatios.joined(separator: ", ")
            )
        }
        if params.audio != nil, !c.audioConfigurable {
            throw SubagentError.invalidArgs(
                message: "Audio cannot be configured for \(model.displayName).",
                field: "audio",
                expected: "omit this field"
            )
        }
        if let limit = c.promptCharacterLimit, params.prompt.count > limit {
            throw SubagentError.invalidArgs(
                message: "The video prompt is too long.",
                field: "prompt",
                expected: "at most \(limit) characters"
            )
        }
    }

    private static func loadSourceImage(_ path: String) throws -> (Data, String) {
        let url = URL.osaurusImageFileURL(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let approvedRoot = OsaurusPaths.root()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard url.path.hasPrefix(approvedRoot + "/") else {
            throw SubagentError.invalidArgs(
                message:
                    "Remote video source images must come from an Osaurus attachment or generated artifact.",
                field: "source_path",
                expected: "a file path inside the current Osaurus artifact store"
            )
        }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "webp": mime = "image/webp"
        default:
            throw SubagentError.invalidArgs(
                message: "Unsupported source image.",
                field: "source_path",
                expected: "an existing PNG, JPEG, or WebP file"
            )
        }
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            (values.fileSize ?? 0) <= 25 * 1_024 * 1_024
        else {
            throw SubagentError.invalidArgs(
                message: "Source image is missing or larger than 25 MB.",
                field: "source_path",
                expected: "an existing image no larger than 25 MB"
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard
            HTTPHandler.decodeImageInputWithMIME(
                "data:\(mime);base64,\(data.base64EncodedString())"
            ) != nil
        else {
            throw SubagentError.invalidArgs(
                message: "The source image bytes do not match its file type.",
                field: "source_path",
                expected: "a valid PNG, JPEG, or WebP image"
            )
        }
        return (data, mime)
    }
}
