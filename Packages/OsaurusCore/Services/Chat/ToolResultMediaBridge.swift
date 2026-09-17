//
//  ToolResultMediaBridge.swift
//  osaurus
//
//  Turns a tool-result envelope that references staged image bytes
//  (`kind: "image"`, `image_ref: {hash, byte_count}` — produced by
//  `file_read`) into chat attachments, and builds the multimodal tool
//  message the model sees. One implementation shared by the chat loop
//  (send + warm-up) and the spawned-agent runner so every surface
//  serialises tool images identically.
//

import Foundation

enum ToolResultMediaBridge {
    /// Tools whose success envelopes may carry an `image_ref`.
    static let imageProducingTools: Set<String> = ["file_read", "sandbox_read_file"]

    /// How many tool-result images stay live in outbound history. Older
    /// ones collapse to their text envelope — the same posture as
    /// `ComputerUseLoop.dropPriorImages`, so a long read-heavy session
    /// does not re-prefill every screenshot on every iteration.
    static let maxLiveImages = 2

    /// Marker text appended when an image has been collapsed out of the
    /// live window, so the model knows the picture existed.
    static let collapsedImageNote =
        "[image attachment from this tool result is no longer in context; call file_read again if you need to see it]"

    /// Resolve `image_ref` entries in a tool-result envelope into
    /// attachments. Returns `[]` for anything that is not an image envelope
    /// or whose blob is missing (the text envelope still stands on its own).
    static func attachments(toolName: String, result: String) -> [Attachment] {
        guard imageProducingTools.contains(toolName) else { return [] }
        return attachments(result: result)
    }

    static func attachments(result: String) -> [Attachment] {
        guard let payload = ToolEnvelope.successPayload(result) as? [String: Any],
            payload["kind"] as? String == "image",
            let ref = payload["image_ref"] as? [String: Any],
            let hash = ref["hash"] as? String,
            !hash.isEmpty
        else { return [] }
        guard AttachmentBlobStore.exists(hash) else { return [] }
        let byteCount = (ref["byte_count"] as? Int) ?? 0
        return [Attachment(kind: .imageRef(hash: hash, byteCount: byteCount))]
    }

    /// Whether this envelope is an image result (used by UI grounding
    /// code that must not treat the descriptive `text` as file content).
    static func isImageEnvelope(_ result: String) -> Bool {
        guard let payload = ToolEnvelope.successPayload(result) as? [String: Any] else { return false }
        return payload["kind"] as? String == "image" && payload["image_ref"] != nil
    }

    /// Build the model-facing tool message. Images ride as
    /// `contentParts: [.text(envelope), .imageUrl(data:)]` when the model
    /// accepts them; otherwise the plain text envelope is returned.
    static func toolMessage(
        content: String,
        toolCallId: String?,
        attachments: [Attachment],
        supportsImages: Bool
    ) -> ChatMessage {
        let images = supportsImages ? attachments.loadImages() : []
        guard !images.isEmpty else {
            return ChatMessage(role: "tool", content: content, tool_calls: nil, tool_call_id: toolCallId)
        }
        var parts: [MessageContentPart] = [.text(content)]
        for data in images {
            parts.append(.imageUrl(url: dataURL(for: data), detail: nil))
        }
        return ChatMessage(role: "tool", content: content, tool_calls: nil, tool_call_id: toolCallId)
            .replacingContentParts(parts)
    }

    /// Keep at most `maxLiveImages` tool messages with image parts (the
    /// most recent ones); collapse the rest to their text with a note.
    /// Pure so warm-up and send produce byte-identical history.
    static func collapsingOlderImages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var imageToolIndices: [Int] = []
        for (index, message) in messages.enumerated() {
            guard message.role == "tool", let parts = message.contentParts,
                parts.contains(where: {
                    if case .imageUrl = $0 { return true }; return false
                })
            else { continue }
            imageToolIndices.append(index)
        }
        guard imageToolIndices.count > maxLiveImages else { return messages }
        let toCollapse = Set(imageToolIndices.dropLast(maxLiveImages))
        var out = messages
        for index in toCollapse {
            let message = messages[index]
            let text = (message.content ?? "") + "\n" + collapsedImageNote
            out[index] = ChatMessage(
                role: "tool",
                content: text,
                tool_calls: nil,
                tool_call_id: message.tool_call_id
            )
        }
        return out
    }

    /// Text that introduces hoisted tool images on wires whose tool role is
    /// text-only (OpenAI Chat Completions / Responses, Gemini
    /// functionResponse). Anthropic keeps images inside `tool_result`.
    static let hoistedImageIntro =
        "[Osaurus] The image(s) below belong to the preceding tool result(s); treat them as that tool's output."

    /// OpenAI-compatible wires reject image parts on the `tool` role. Move
    /// them into ONE user message inserted after the last tool message of
    /// the run (a user message between two tool results would break the
    /// "tool messages must directly follow tool_calls" invariant). Tool
    /// messages keep their text. Messages without tool images are
    /// returned unchanged so cache-stable histories stay byte-identical.
    static func hoistingToolImagesToUserMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        func imageParts(_ message: ChatMessage) -> [MessageContentPart] {
            guard message.role == "tool", let parts = message.contentParts else { return [] }
            return parts.filter {
                if case .imageUrl = $0 { return true }; return false
            }
        }
        guard messages.contains(where: { !imageParts($0).isEmpty }) else { return messages }

        var out: [ChatMessage] = []
        var pending: [MessageContentPart] = []
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(
                ChatMessage(
                    role: "user",
                    content: hoistedImageIntro,
                    contentParts: [.text(hoistedImageIntro)] + pending
                )
            )
            pending = []
        }
        for (index, message) in messages.enumerated() {
            if message.role == "tool" {
                let images = imageParts(message)
                if images.isEmpty {
                    out.append(message)
                } else {
                    out.append(
                        ChatMessage(
                            role: "tool",
                            content: message.content ?? "",
                            tool_calls: nil,
                            tool_call_id: message.tool_call_id
                        )
                    )
                    pending.append(contentsOf: images)
                }
                let nextIsTool = index + 1 < messages.count && messages[index + 1].role == "tool"
                if !nextIsTool { flush() }
            } else {
                flush()
                out.append(message)
            }
        }
        flush()
        return out
    }

    /// Estimated token cost of the image parts in a tool message, for the
    /// loop's context budget.
    static func estimatedImageTokens(in attachments: [Attachment]) -> Int {
        attachments.reduce(0) { $0 + ($1.isImage ? $1.estimatedTokens : 0) }
    }

    // MARK: - Helpers

    private static func dataURL(for data: Data) -> String {
        "data:\(mime(for: data));base64,\(data.base64EncodedString())"
    }

    /// Sniff the container from magic bytes so the data URL is labelled
    /// truthfully (strict providers 400 on a JPEG marked `image/png`).
    private static func mime(for data: Data) -> String {
        guard data.count >= 12 else { return "image/png" }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "image/png" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "image/gif" }
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
            bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50
        {
            return "image/webp"
        }
        return "image/png"
    }
}
