//
//  RemoteImagePayloadPolicy.swift
//  osaurus
//
//  Client-side sizing for images bound to REMOTE providers.
//
//  Chat attachments enter the message set as full-resolution `data:` URIs
//  labeled `image/png` regardless of their actual bytes. Local VL models
//  are fine with that — their processors downscale internally and vmlx
//  sniffs the container. Remote APIs are not: a Retina screenshot base64s
//  into tens of megabytes (relay/provider 413), and a JPEG mislabeled
//  `image/png` is a provider 400 waiting to happen.
//
//  This policy runs once, in `RemoteProviderService.applyPrivacyOutbound`
//  — the single funnel every remote request passes through — and never on
//  the local path:
//    - images longer than `maxLongSidePixels` on their long side, or larger
//      than `maxEncodedBytes`, are downscaled and re-encoded as JPEG; the
//      re-encode is adopted ONLY when it is actually smaller,
//    - images left byte-identical get their data-URI mime corrected to the
//      container's real type.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RemoteImagePayloadPolicy {
    /// Longest-side budget for a remote-bound image. 2048 px keeps text in
    /// screenshots legible for every current vision API while cutting a 5K
    /// Retina capture's payload by an order of magnitude.
    static let maxLongSidePixels = 2048
    /// Encoded-bytes budget per image. Anthropic caps a single image at 5 MB
    /// and Gemini rejects oversized inline data with a 400/413; 4 MB clears
    /// both with headroom for the base64 expansion.
    static let maxEncodedBytes = 4 * 1024 * 1024
    /// JPEG quality for the re-encode. High enough that screenshots and
    /// photos stay visually faithful for a vision model.
    static let jpegQuality = 0.85

    /// Rewrite every oversized or mislabeled `data:` image part in the
    /// outbound messages. Messages without image parts are returned as-is.
    static func prepared(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            guard let parts = message.contentParts,
                parts.contains(where: { if case .imageUrl = $0 { return true }; return false })
            else { return message }

            var changed = false
            let newParts: [MessageContentPart] = parts.map { part in
                guard case .imageUrl(let url, let detail) = part else { return part }
                let rewritten = preparedDataURL(url)
                if rewritten != url {
                    changed = true
                    return .imageUrl(url: rewritten, detail: detail)
                }
                return part
            }
            guard changed else { return message }
            return message.replacingContentParts(newParts)
        }
    }

    /// Rewrite a single `data:` image URI per the policy. Plain http(s) URLs
    /// and anything unparsable are returned unchanged — a bad part should
    /// degrade to the provider's own error, never crash the send.
    static func preparedDataURL(_ url: String) -> String {
        guard url.hasPrefix("data:image/"),
            let commaIndex = url.firstIndex(of: ",")
        else { return url }
        let base64 = String(url[url.index(after: commaIndex)...])
        guard let bytes = Data(base64Encoded: base64), !bytes.isEmpty else { return url }

        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return url }
        let actualMime = mime(of: source) ?? "image/png"
        let longSide = longestSide(of: source)

        let oversized = (longSide ?? 0) > maxLongSidePixels || bytes.count > maxEncodedBytes
        if oversized, let jpeg = downsizedJPEG(from: source), jpeg.count < bytes.count {
            return "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }

        // Small enough to ship untouched — but fix a mislabeled container so
        // strict providers don't 400 on a JPEG marked image/png.
        let header = url[url.index(url.startIndex, offsetBy: "data:".count)..<commaIndex]
        let labeled = header.split(separator: ";").first.map(String.init) ?? "image/png"
        if labeled != actualMime {
            return "data:\(actualMime);base64," + base64
        }
        return url
    }

    /// Downscale arbitrary encoded image bytes to the wire budget as JPEG.
    /// Used by the composer's attach path for files over its inline cap —
    /// attach a usable rendition instead of silently dropping the file.
    static func downsizedJPEGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsizedJPEG(from: source)
    }

    // MARK: - ImageIO helpers

    private static func mime(of source: CGImageSource) -> String? {
        guard let uti = CGImageSourceGetType(source) as String?,
            let type = UTType(uti)
        else { return nil }
        return type.preferredMIMEType
    }

    private static func longestSide(of source: CGImageSource) -> Int? {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(w, h)
    }

    private static func downsizedJPEG(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSidePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

extension ChatMessage {
    /// Same message with different content parts. ChatMessage's stored fields
    /// are `let` and its designated inits each drop some field, so the policy
    /// rebuilds through this full-fields copy.
    fileprivate func replacingContentParts(_ parts: [MessageContentPart]?) -> ChatMessage {
        ChatMessage(
            role: role,
            content: content,
            contentParts: parts,
            localAudioSamples: localAudioSamples,
            tool_calls: tool_calls,
            tool_call_id: tool_call_id,
            reasoning_content: reasoning_content,
            reasoning_item_id: reasoning_item_id,
            reasoning_encrypted: reasoning_encrypted
        )
    }
}

