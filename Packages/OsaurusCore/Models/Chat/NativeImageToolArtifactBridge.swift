//
//  NativeImageToolArtifactBridge.swift
//  osaurus
//
//  Bridges native image tool results into the existing chat artifact renderer.
//

import Foundation

enum GeneratedMediaToolArtifactBridge {
    static let toolNames: Set<String> = ["image", "video"]

    static func isGeneratedMediaTool(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    /// Keep completed files visible when a later image fails. This does not
    /// manufacture a successful tool result or put artifact bytes in the prompt.
    static func preservePartialImages(_ images: [GeneratedImage], sessionID: String) {
        for image in images {
            let outcome = SharedArtifact.processTrustedLocalFileResult(
                fileURL: image.url, filename: image.url.lastPathComponent,
                mimeType: SharedArtifact.mimeType(from: image.url.lastPathComponent),
                description: "Completed image from an interrupted batch",
                contextId: sessionID, contextType: .chat)
            switch outcome {
            case .success(let processed):
                SpawnArtifactCollector.deposit(processed.artifact, sessionId: sessionID)
            case .failure(let reason):
                NSLog("[NativeImageToolArtifactBridge] partial image preservation failed: %@",
                    String(describing: reason))
            }
        }
    }

    static func processFirstMediaArtifact(
        toolName: String,
        toolResult: String,
        contextId: String,
        contextType: ArtifactContextType = .chat
    ) -> Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure>? {
        guard isGeneratedMediaTool(toolName),
            let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let media = firstMediaPayload(in: payload),
            mediaPath(in: media) != nil
        else {
            return nil
        }

        return process(media, payload: payload, contextId: contextId, contextType: contextType)
    }

    static func processMediaArtifacts(
        toolName: String, toolResult: String, contextId: String,
        contextType: ArtifactContextType = .chat
    ) -> [Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure>] {
        guard isGeneratedMediaTool(toolName),
            let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any] else { return [] }
        let items: [[String: Any]]
        if let media = payload["media"] as? [String: Any] { items = [media] }
        else { items = payload["images"] as? [[String: Any]] ?? [] }
        return items.compactMap { media in
            guard mediaPath(in: media) != nil else { return nil }
            return process(media, payload: payload, contextId: contextId, contextType: contextType)
        }
    }

    private static func process(
        _ media: [String: Any], payload: [String: Any], contextId: String,
        contextType: ArtifactContextType
    ) -> Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure> {
        // Callers validate the local path before entering the shared promotion.
        let path = mediaPath(in: media)!
        // One `image` tool serves both modes; the payload's `mode` distinguishes
        // them for the filename + description.
        let isEdit = (payload["mode"] as? String) == "edit"
        let sourceURL = URL(fileURLWithPath: path)
        let filename = generatedMediaFilename(
            sourceURL: sourceURL,
            mediaType: payload["media_type"] as? String,
            isEdit: isEdit,
            jobID: payload["job_id"] as? String
        )
        return SharedArtifact.processTrustedLocalFileResult(
            fileURL: sourceURL,
            filename: filename,
            mimeType: SharedArtifact.mimeType(from: filename),
            description: artifactDescription(
                mediaType: payload["media_type"] as? String,
                isEdit: isEdit,
                model: payload["model"] as? String
            ),
            contextId: contextId,
            contextType: contextType
        )
    }

    private static func firstMediaPayload(in payload: [String: Any]) -> [String: Any]? {
        if let media = payload["media"] as? [String: Any] { return media }
        guard let images = payload["images"] as? [[String: Any]] else { return nil }
        return images.first
    }

    private static func mediaPath(in media: [String: Any]) -> String? {
        if let path = media["path"] as? String,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return path
        }
        if let urlString = media["url"] as? String,
            let url = URL(string: urlString),
            url.isFileURL
        {
            return url.path
        }
        return nil
    }

    private static func generatedMediaFilename(
        sourceURL: URL,
        mediaType: String?,
        isEdit: Bool,
        jobID: String?
    ) -> String {
        let lastPathComponent = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty { return lastPathComponent }
        let suffix = mediaType == "video" ? "video" : (isEdit ? "image-edit" : "image-generate")
        let idPart = jobID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = idPart?.isEmpty == false ? idPart! : UUID().uuidString
        let ext = mediaType == "video" ? "mp4" : "png"
        return "generated-\(suffix)-\(base).\(ext)"
    }

    private static func artifactDescription(
        mediaType: String?,
        isEdit: Bool,
        model: String?
    ) -> String {
        let action =
            mediaType == "video"
            ? "Video generation result"
            : (isEdit ? "Image edit result" : "Image generation result")
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return action
        }
        return "\(action) from \(model)"
    }
}

/// Source-compatible wrappers for existing callers/tests.
enum NativeImageToolArtifactBridge {
    static func isNativeImageTool(_ name: String) -> Bool {
        name == "image"
    }

    static func processFirstImageArtifact(
        toolName: String,
        toolResult: String,
        contextId: String,
        contextType: ArtifactContextType = .chat
    ) -> Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure>? {
        guard isNativeImageTool(toolName) else { return nil }
        return GeneratedMediaToolArtifactBridge.processFirstMediaArtifact(
            toolName: toolName,
            toolResult: toolResult,
            contextId: contextId,
            contextType: contextType
        )
    }
}
