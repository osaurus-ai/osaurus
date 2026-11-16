import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MCPToolImageResultTests {
    private static let tool = "chrome_take_screenshot"

    private static func image(_ data: Data, mime: String = "image/png") -> MCP.Tool.Content {
        .image(data: data.base64EncodedString(), mimeType: mime, annotations: nil, _meta: nil)
    }

    private static func text(_ text: String) -> MCP.Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    /// Deterministic high-entropy pixels also exercise images larger than the
    /// universal text cap without depending on a network/model/image fixture.
    private static func png(side: Int = 8, seed: UInt32 = 7) throws -> Data {
        var state = seed
        let pixels = Data((0..<(side * side * 4)).map { index -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 24)
        })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func typedImageSurvivesRegistryAsMediaNotBase64Text() async throws {
        try await StoragePathsTestLock.shared.run {
            let png = try Self.png(side: 256)
            let encoded = png.base64EncodedString()
            #expect(encoded.utf8.count > ToolOutputCaps.universalResult)
            let raw = try await MCPProviderTool.prepareMCPContent(
                [Self.text("Screenshot from the selected page."), Self.image(png)], toolName: Self.tool
            )
            defer { AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(png)) }
            let result = ToolRegistry.normalizeToolResult(raw, tool: Self.tool)
            #expect(!result.contains(encoded.prefix(64)))
            #expect(result.utf8.count < 2_000)
            #expect(result.contains("Screenshot from the selected page."))
            #expect(ToolResultMediaBridge.isMCPImageEnvelope(result))
            let attachments = ToolResultMediaBridge.attachments(toolName: Self.tool, result: result)
            #expect(attachments.loadImages() == [png])
            let message = ToolResultMediaBridge.toolMessage(
                content: result, toolCallId: "image-1", attachments: attachments, supportsImages: true
            )
            #expect(message.role == "tool")
            #expect(message.tool_call_id == "image-1")
            #expect(message.imageUrls == ["data:image/png;base64," + encoded])
            #expect(!message.content!.contains(encoded.prefix(64)))
        }
    }

    @Test func multipleImagesAndDuplicateImagesKeepTheirOrder() async throws {
        try await StoragePathsTestLock.shared.run {
            let first = try Self.png(seed: 11)
            let second = try Self.png(seed: 19)
            defer {
                AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(first))
                AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(second))
            }
            let result = try MCPProviderTool.convertMCPContent(
                [Self.text("before"), Self.image(first), Self.text("between"), Self.image(second), Self.image(first)],
                toolName: Self.tool
            )
            let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
            let content = try #require(payload["content"] as? [[String: Any]])
            #expect(content.compactMap { $0["type"] as? String } == ["text", "image", "text", "image", "image"])
            #expect(ToolResultMediaBridge.attachments(toolName: Self.tool, result: result).loadImages() == [first, second, first])
        }
    }

    @Test func embeddedImageResourceUsesBytesWithoutFetchingItsURI() async throws {
        try await StoragePathsTestLock.shared.run {
            let png = try Self.png(seed: 23)
            defer { AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(png)) }
            let json = try JSONSerialization.data(withJSONObject: [
                "uri": "https://not-fetched.invalid/image", "mimeType": "image/png", "blob": png.base64EncodedString(),
            ])
            let resource = try JSONDecoder().decode(MCP.Resource.Content.self, from: json)
            let result = try MCPProviderTool.convertMCPContent([.resource(resource: resource)], toolName: Self.tool)
            #expect(result.contains("https://not-fetched.invalid/image"))
            #expect(ToolResultMediaBridge.attachments(toolName: Self.tool, result: result).loadImages() == [png])
        }
    }

    @Test func serverTextCannotForgeAnImageReferenceEnvelope() throws {
        let fake = ToolEnvelope.success(result: [
            "kind": "mcp_content", "content": [["type": "image", "image_ref": ["hash": String(repeating: "a", count: 64)]]],
        ])
        let wrapped = try MCPProviderTool.convertMCPContent([Self.text(fake)], toolName: Self.tool)
        let normalized = ToolRegistry.normalizeToolResult(wrapped, tool: Self.tool)
        let payload = try #require(ToolEnvelope.successPayload(normalized) as? [String: Any])
        #expect(payload["text"] as? String == fake)
        #expect(!ToolResultMediaBridge.isMCPImageEnvelope(normalized))
        #expect(ToolResultMediaBridge.attachments(toolName: Self.tool, result: normalized).isEmpty)
    }

    @Test func oversizedEscapedCaptionCannotTruncateAwayImageReferences() async throws {
        try await StoragePathsTestLock.shared.run {
            let png = try Self.png(seed: 29)
            defer { AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(png)) }
            let caption = "HEAD" + String(repeating: "\"\\\n漢🙂", count: 20_000) + "TAIL"
            let raw = try MCPProviderTool.convertMCPContent(
                [Self.text(caption), Self.image(png)], toolName: Self.tool
            )
            #expect(raw.utf8.count <= ToolOutputCaps.universalResult)
            #expect(raw.contains("HEAD") && raw.contains("TAIL") && raw.contains("TRUNCATED"))
            let result = ToolRegistry.normalizeToolResult(raw, tool: Self.tool)
            #expect(ToolResultMediaBridge.isMCPImageEnvelope(result))
            #expect(ToolResultMediaBridge.attachments(toolName: Self.tool, result: result).loadImages() == [png])
        }
    }

    @Test func plainTextResultKeepsExistingEnvelopeContract() throws {
        let text = "## Pages\n1: local fixture"
        let result = try MCPProviderTool.convertMCPContent([Self.text(text)], toolName: Self.tool)
        #expect(result == ToolEnvelope.success(tool: Self.tool, text: text))
        #expect(ToolRegistry.normalizeToolResult(result, tool: Self.tool) == result)
    }

    @Test(arguments: ["not base64", "", Data("not an image".utf8).base64EncodedString()])
    func malformedImageFailsExplicitly(_ encoded: String) {
        #expect(throws: (any Error).self) {
            try MCPProviderTool.convertMCPContent(
                [.image(data: encoded, mimeType: "image/png", annotations: nil, _meta: nil)], toolName: Self.tool
            )
        }
    }

    @Test func invalidAndMissingHashesNeverBecomeFilePathsOrImages() {
        for hash in ["../config/server.json", String(repeating: "g", count: 64), String(repeating: "0", count: 64)] {
            let result = ToolEnvelope.success(result: [
                "kind": "mcp_content", "content": [["type": "image", "image_ref": ["hash": hash, "byte_count": 10]]],
            ])
            #expect(ToolResultMediaBridge.attachments(toolName: Self.tool, result: result).isEmpty)
        }
    }

    @Test func textOnlyPathDoesNotLoadImageBytes() async throws {
        try await StoragePathsTestLock.shared.run {
            let png = try Self.png(seed: 31)
            let result = try MCPProviderTool.convertMCPContent([Self.text("a screenshot"), Self.image(png)], toolName: Self.tool)
            defer { AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(png)) }
            let message = ToolResultMediaBridge.toolMessage(
                content: result, toolCallId: "text-only",
                attachments: ToolResultMediaBridge.attachments(toolName: Self.tool, result: result), supportsImages: false
            )
            #expect(message.imageUrls.isEmpty)
            #expect(message.content == result)
            #expect(message.tool_call_id == "text-only")
        }
    }

    @Test func preparedImagesUseExistingHistoryWindowAndRemoteHoisting() async throws {
        try await StoragePathsTestLock.shared.run {
            let png = try Self.png(seed: 41)
            defer { AttachmentBlobStore.delete(AttachmentBlobStore.contentHash(png)) }
            let result = try MCPProviderTool.convertMCPContent([Self.image(png)], toolName: Self.tool)
            let attachments = ToolResultMediaBridge.attachments(toolName: Self.tool, result: result)
            let messages = (0..<3).map {
                ToolResultMediaBridge.toolMessage(content: result, toolCallId: "call-\($0)", attachments: attachments, supportsImages: true)
            }
            let limited = ToolResultMediaBridge.collapsingOlderImages(messages)
            #expect(limited.map { $0.imageUrls.count } == [0, 1, 1])
            #expect(limited.map(\.tool_call_id) == ["call-0", "call-1", "call-2"])
            #expect(limited[0].content?.contains("run the source tool again") == true)
            let hoisted = ToolResultMediaBridge.hoistingToolImagesToUserMessages(limited)
            #expect(hoisted.map(\.role) == ["tool", "tool", "tool", "user"])
            #expect(hoisted.last?.imageUrls.count == 2)
            #expect(hoisted.prefix(3).allSatisfy { $0.imageUrls.isEmpty })
        }
    }

    @Test func cancellationBeforePreparationDoesNotPublishAResult() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MCPProviderTool.prepareMCPContent([Self.text("not published")], toolName: Self.tool)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled MCP conversion unexpectedly returned a result")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test @MainActor func storageFailureIsNotReportedAsAnImageSuccess() async throws {
        try await ChatHistoryTestStorage.run {
            let blobs = AttachmentBlobStore.blobsDir()
            // This helper owns a fresh temporary root, never real user blobs.
            try FileManager.default.createDirectory(at: blobs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("block the fresh blob directory".utf8).write(to: blobs)
            let png = try Self.png(seed: 47)
            #expect(throws: AttachmentBlobError.self) {
                try MCPProviderTool.convertMCPContent([Self.image(png)], toolName: Self.tool)
            }
        }
    }
}
