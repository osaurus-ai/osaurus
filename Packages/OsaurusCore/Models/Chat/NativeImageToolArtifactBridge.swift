//
//  NativeImageToolArtifactBridge.swift
//  osaurus
//
//  Bridges native image tool results into the existing chat artifact renderer.
//

import Foundation

enum NativeImageToolArtifactBridge {
    static let toolNames: Set<String> = ["image"]

    static func isNativeImageTool(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    static func processFirstImageArtifact(
        toolName: String,
        toolResult: String,
        contextId: String,
        contextType: ArtifactContextType = .chat
    ) -> Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure>? {
        guard isNativeImageTool(toolName),
            let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let image = firstImagePayload(in: payload),
            let path = imagePath(in: image)
        else {
            return nil
        }

        // One `image` tool serves both modes; the payload's `mode` distinguishes
        // them for the filename + description.
        let isEdit = (payload["mode"] as? String) == "edit"
        let sourceURL = URL(fileURLWithPath: path)
        let filename = nativeImageFilename(
            sourceURL: sourceURL,
            isEdit: isEdit,
            jobID: payload["job_id"] as? String
        )
        return SharedArtifact.processTrustedLocalFileResult(
            fileURL: sourceURL,
            filename: filename,
            mimeType: SharedArtifact.mimeType(from: filename),
            description: artifactDescription(isEdit: isEdit, model: payload["model"] as? String),
            contextId: contextId,
            contextType: contextType
        )
    }

    private static func firstImagePayload(in payload: [String: Any]) -> [String: Any]? {
        guard let images = payload["images"] as? [[String: Any]] else { return nil }
        return images.first
    }

    private static func imagePath(in image: [String: Any]) -> String? {
        if let path = image["path"] as? String,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return path
        }
        if let urlString = image["url"] as? String,
            let url = URL(string: urlString),
            url.isFileURL
        {
            return url.path
        }
        return nil
    }

    private static func nativeImageFilename(sourceURL: URL, isEdit: Bool, jobID: String?) -> String {
        let lastPathComponent = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty { return lastPathComponent }
        let suffix = isEdit ? "edit" : "generate"
        let idPart = jobID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = idPart?.isEmpty == false ? idPart! : UUID().uuidString
        return "native-image-\(suffix)-\(base).png"
    }

    private static func artifactDescription(isEdit: Bool, model: String?) -> String {
        let action = isEdit ? "Native image edit result" : "Native image generation result"
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return action
        }
        return "\(action) from \(model)"
    }
}
