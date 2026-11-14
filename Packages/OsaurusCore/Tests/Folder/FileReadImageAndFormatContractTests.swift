//
//  FileReadImageAndFormatContractTests.swift
//  osaurusTests
//
//  Pins the unified `file_read` format contract: images attach for vision
//  models and OCR for text-only models, unsupported document variants are
//  named with their working alternatives (never "text only"), successful
//  reads carry format/source metadata, and the surrounding plumbing
//  (`ToolResultMediaBridge`, provider encoders, warm-up parity, FileDiff
//  grounding) treats image envelopes as pictures rather than file text.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileReadImageAndFormatContractTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-read-contract-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func payload(_ envelope: String) throws -> [String: Any] {
        try #require(ToolEnvelope.successPayload(envelope) as? [String: Any], Comment(rawValue: envelope))
    }

    private func failure(_ envelope: String) throws -> [String: Any] {
        let data = try #require(envelope.data(using: .utf8))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["ok"] as? Bool == false, Comment(rawValue: envelope))
        return dict
    }

    private func execute(_ tool: FileReadTool, _ args: String) async -> String {
        do {
            return try await tool.execute(argumentsJSON: args)
        } catch {
            return ToolEnvelope.fromError(error, tool: tool.name)
        }
    }

    // MARK: - Images

    /// Holds `StoragePathsTestLock` because the staged image lives in
    /// `AttachmentBlobStore` under the Osaurus storage root, which other
    /// suites relocate (`OsaurusPaths.overrideRoot`) while they run.
    @Test func imageAttachesForVisionModels() async throws {
        try await StoragePathsTestLock.shared.run {
            try await imageAttachesForVisionModelsBody()
        }
    }

    private func imageAttachesForVisionModelsBody() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("chart.png")
        try Self.writePNG(text: "OSAURUS OCR TEST", to: image)

        let tool = FileReadTool(rootPath: root)
        let envelope = await ChatExecutionContext.$toolResultImagesEnabled.withValue(true) {
            await execute(tool, #"{"path":"chart.png"}"#)
        }

        #expect(ToolEnvelope.isSuccess(envelope), Comment(rawValue: envelope))
        let result = try payload(envelope)
        #expect(result["kind"] as? String == "image")
        #expect(result["source"] as? String == "image")
        #expect(result["format"] as? String == "png")
        #expect((result["width"] as? Int ?? 0) > 0)
        let ref = try #require(result["image_ref"] as? [String: Any])
        let hash = try #require(ref["hash"] as? String)
        #expect(AttachmentBlobStore.exists(hash))
        defer { AttachmentBlobStore.delete(hash) }
        let text = try #require(result["text"] as? String)
        #expect(text.contains("attached"))
        #expect(!text.contains("|"), "image envelopes carry no line gutter")

        // The bridge resolves the ref into a real attachment for tool turns.
        let attachments = ToolResultMediaBridge.attachments(toolName: "file_read", result: envelope)
        #expect(attachments.count == 1)
        #expect(attachments.first?.isImage == true)
        #expect(ToolResultMediaBridge.isImageEnvelope(envelope))
        // Non image-producing tools never pick up an image ref.
        #expect(ToolResultMediaBridge.attachments(toolName: "shell_run", result: envelope).isEmpty)

        // Multimodal tool message for vision models; plain text otherwise.
        let vision = ToolResultMediaBridge.toolMessage(
            content: envelope,
            toolCallId: "call-1",
            attachments: attachments,
            supportsImages: true
        )
        #expect(vision.imageUrls.count == 1)
        #expect(vision.imageUrls.first?.hasPrefix("data:image/png;base64,") == true)
        #expect(vision.tool_call_id == "call-1")
        let textOnly = ToolResultMediaBridge.toolMessage(
            content: envelope,
            toolCallId: "call-1",
            attachments: attachments,
            supportsImages: false
        )
        #expect(textOnly.imageUrls.isEmpty)
        #expect(textOnly.content == envelope)
    }

    @Test func imageBecomesOCRTextForTextOnlyModels() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("sign.png")
        try Self.writePNG(text: "OSAURUS OCR TEST", to: image)

        let tool = FileReadTool(rootPath: root)
        // Default context: no vision surface bound.
        let envelope = await execute(tool, #"{"path":"sign.png"}"#)

        #expect(ToolEnvelope.isSuccess(envelope), Comment(rawValue: envelope))
        let result = try payload(envelope)
        #expect(result["kind"] as? String != "image")
        #expect(result["source"] as? String == "ocr_text")
        #expect(result["format"] as? String == "png")
        #expect(result["image_ref"] == nil)
        let text = try #require(result["text"] as? String)
        #expect(text.uppercased().contains("OSAURUS"), "OCR text missing: \(text)")
        // Same `N|` gutter as any other read.
        #expect(text.range(of: #"^\s*1\|"#, options: .regularExpression) != nil, Comment(rawValue: text))
        let note = try #require(result["note"] as? String)
        #expect(note.contains("OCR"))
    }

    @Test func blankImageWithoutTextIsRefusedHonestlyForTextOnlyModels() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("blank.png")
        try Self.writePNG(text: nil, to: image)

        let tool = FileReadTool(rootPath: root)
        let envelope = await execute(tool, #"{"path":"blank.png"}"#)

        #expect(ToolEnvelope.isError(envelope), Comment(rawValue: envelope))
        let message = try #require(EnvelopeAssertions.failureMessage(envelope))
        #expect(!message.contains("only supports text"), Comment(rawValue: message))
        #expect(message.lowercased().contains("image"))
    }

    // MARK: - Unsupported document variants

    @Test func legacyXLSIsNamedWithWorkingAlternatives() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // OLE compound-document magic so nothing mistakes it for text.
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(
            to: root.appendingPathComponent("legacy.xls")
        )

        let tool = FileReadTool(rootPath: root)
        let envelope = await execute(tool, #"{"path":"legacy.xls"}"#)

        #expect(ToolEnvelope.isError(envelope), Comment(rawValue: envelope))
        let error = try failure(envelope)
        let message = try #require(error["message"] as? String)
        #expect(!message.contains("only supports text"), Comment(rawValue: message))
        #expect(message.contains(".xlsx"), Comment(rawValue: message))
        #expect(message.contains("xls"), Comment(rawValue: message))
        // `metadata` merges into the top level of the failure envelope.
        #expect(error["extension"] as? String == "xls")
        #expect(error["document_family"] as? String != nil)
        let readable = try #require(error["readable_formats"] as? String)
        #expect(readable.contains("PDF") && readable.contains(".docx") && readable.contains(".xlsx"))
    }

    @Test func iWorkAndODFAreNamedNotParsed() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = FileReadTool(rootPath: root)
        for name in ["deck.key", "doc.pages", "sheet.numbers", "text.odt"] {
            try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: root.appendingPathComponent(name))
            let envelope = await execute(tool, #"{"path":"\#(name)"}"#)
            #expect(ToolEnvelope.isError(envelope), Comment(rawValue: envelope))
            let message = try #require(EnvelopeAssertions.failureMessage(envelope))
            #expect(!message.contains("only supports text"), Comment(rawValue: message))
            #expect(!message.contains("could not be parsed"), "\(name): \(message)")
            #expect(EnvelopeAssertions.failureRetryable(envelope) == false)
        }
    }

    // MARK: - Success metadata

    @Test func pdfReadCarriesFormatSourceAndPageCount() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: ["Executive summary", "Appendix"], to: root.appendingPathComponent("r.pdf"))

        let envelope = await execute(FileReadTool(rootPath: root), #"{"path":"r.pdf"}"#)
        #expect(ToolEnvelope.isSuccess(envelope), Comment(rawValue: envelope))
        let result = try payload(envelope)
        #expect(result["format"] as? String == "pdf")
        #expect(result["source"] as? String == "extracted_text")
        #expect(result["pages"] as? Int == 2)
    }

    @Test func rawTextReadCarriesRawSource() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "let x = 1\n".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let envelope = await execute(FileReadTool(rootPath: root), #"{"path":"a.swift"}"#)
        let result = try payload(envelope)
        #expect(result["format"] as? String == "text" || result["format"] as? String == "swift")
        #expect(result["source"] as? String == "raw_text")
    }

    @Test func xlsxPreviewIsAWorkbookEnvelope() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workbook = try FileWriteDocumentRouting.buildWorkbook(from: "name,qty\nwidget,3\n")
        try XLSXEmitter.packageBytes(for: workbook).write(to: root.appendingPathComponent("b.xlsx"))

        let envelope = await execute(FileReadTool(rootPath: root), #"{"path":"b.xlsx"}"#)
        #expect(ToolEnvelope.isSuccess(envelope), Comment(rawValue: envelope))
        let result = try payload(envelope)
        #expect(result["kind"] as? String == "workbook")
        #expect(result["format"] as? String == "xlsx")
        #expect(result["source"] as? String == "workbook_preview")
        #expect((result["text"] as? String ?? "").contains("widget"))
    }

    // MARK: - Media bridge: history window and provider hoisting

    @Test func collapsingKeepsOnlyMostRecentImages() {
        let png = "data:image/png;base64,iVBORw0KGgo="
        func imageTool(_ id: String) -> ChatMessage {
            ChatMessage(role: "tool", content: "env-\(id)", tool_calls: nil, tool_call_id: id)
                .replacingContentParts([.text("env-\(id)"), .imageUrl(url: png, detail: nil)])
        }
        let messages = [
            ChatMessage(role: "user", content: "look"),
            imageTool("a"), imageTool("b"), imageTool("c"),
            ChatMessage(role: "assistant", content: "ok"),
        ]
        let collapsed = ToolResultMediaBridge.collapsingOlderImages(messages)
        #expect(collapsed.count == messages.count)
        #expect(collapsed[1].imageUrls.isEmpty)
        #expect(collapsed[1].content?.contains(ToolResultMediaBridge.collapsedImageNote) == true)
        #expect(collapsed[1].tool_call_id == "a")
        #expect(collapsed[2].imageUrls.count == 1)
        #expect(collapsed[3].imageUrls.count == 1)
        // Under the cap, history is returned untouched (byte-identical for cache).
        let small = [messages[0], imageTool("x"), imageTool("y")]
        let untouched = ToolResultMediaBridge.collapsingOlderImages(small)
        #expect(untouched.map(\.content) == small.map(\.content))
        #expect(untouched.map { $0.imageUrls.count } == [0, 1, 1])
    }

    @Test func hoistingMovesToolImagesIntoOneFollowUpUserMessage() {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let toolA = ChatMessage(role: "tool", content: "env-a", tool_calls: nil, tool_call_id: "a")
            .replacingContentParts([.text("env-a"), .imageUrl(url: png, detail: nil)])
        let toolB = ChatMessage(role: "tool", content: "env-b", tool_calls: nil, tool_call_id: "b")
        let messages = [
            ChatMessage(role: "user", content: "read both"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(id: "a", type: "function", function: ToolCallFunction(name: "file_read", arguments: "{}")),
                    ToolCall(id: "b", type: "function", function: ToolCallFunction(name: "file_read", arguments: "{}")),
                ],
                tool_call_id: nil
            ),
            toolA, toolB,
            ChatMessage(role: "assistant", content: "done"),
        ]
        let hoisted = ToolResultMediaBridge.hoistingToolImagesToUserMessages(messages)
        #expect(hoisted.count == messages.count + 1)
        #expect(hoisted[2].role == "tool" && hoisted[2].imageUrls.isEmpty && hoisted[2].tool_call_id == "a")
        #expect(hoisted[3].role == "tool" && hoisted[3].tool_call_id == "b")
        // The image lands after the LAST tool message of the run, never between two.
        #expect(hoisted[4].role == "user")
        #expect(hoisted[4].imageUrls.count == 1)
        #expect(hoisted[4].content?.contains("belong to the preceding tool result") == true)
        #expect(hoisted[5].role == "assistant")
        // No images → untouched.
        let plain = [messages[0], toolB]
        let same = ToolResultMediaBridge.hoistingToolImagesToUserMessages(plain)
        #expect(same.count == 2 && same.map(\.role) == ["user", "tool"])
    }

    @Test func anthropicToolResultCarriesImageBlocks() throws {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let toolMessage = ChatMessage(role: "tool", content: "env", tool_calls: nil, tool_call_id: "call-1")
            .replacingContentParts([.text("env"), .imageUrl(url: png, detail: nil)])
        let request = RemoteChatRequest(
            model: "claude-fable-5",
            messages: [
                ChatMessage(role: "user", content: "look"),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "call-1",
                            type: "function",
                            function: ToolCallFunction(name: "file_read", arguments: "{}")
                        )
                    ],
                    tool_call_id: nil
                ),
                toolMessage,
            ],
            temperature: nil,
            max_completion_tokens: 512,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )
        let anthropic = request.toAnthropicRequest()
        let resultMessage = try #require(anthropic.messages.last)
        guard case .blocks(let blocks) = resultMessage.content else {
            Issue.record("expected block content for the tool_result user message")
            return
        }
        var sawImage = false
        var sawText = false
        for block in blocks {
            guard case .toolResult(let result) = block else { continue }
            #expect(result.tool_use_id == "call-1")
            guard case .blocks(let inner)? = result.content else {
                Issue.record("expected [text, image] blocks inside tool_result")
                continue
            }
            for part in inner {
                if case .image = part { sawImage = true }
                if case .text(let text) = part, text.text == "env" { sawText = true }
            }
        }
        #expect(sawImage && sawText)
    }

    @Test @MainActor func warmupToolTurnMatchesBridgeMessage() async throws {
        try await StoragePathsTestLock.shared.run {
            try await warmupToolTurnMatchesBridgeMessageBody()
        }
    }

    @MainActor private func warmupToolTurnMatchesBridgeMessageBody() throws {
        let png = Self.pngData(text: nil)
        let hash = try AttachmentBlobStore.write(png)
        defer { AttachmentBlobStore.delete(hash) }
        let turn = ChatTurn(
            role: .tool,
            content: #"{"ok":true,"result":{"kind":"image"}}"#,
            attachments: [Attachment(kind: .imageRef(hash: hash, byteCount: png.count))]
        )
        turn.toolCallId = "call-9"

        let session = ChatSession()
        let warm = try #require(session.warmupTurnToMessage(turn, isLastTurn: true))
        let expected = ToolResultMediaBridge.toolMessage(
            content: turn.content,
            toolCallId: "call-9",
            attachments: turn.attachments,
            supportsImages: session.selectedModelSupportsImages
        )
        #expect(warm.content == expected.content)
        #expect(warm.imageUrls == expected.imageUrls)
        #expect(warm.tool_call_id == "call-9")
        #expect(warm.role == "tool")
    }

    // MARK: - FileDiff grounding skips non-text envelopes

    @Test func fileDiffGroundingSkipsImageWorkbookAndOCREnvelopes() {
        func toolTurn(id: String, result: String) -> ChatTurn {
            let turn = ChatTurn(role: .assistant, content: "")
            turn.toolCalls = [
                ToolCall(
                    id: id,
                    type: "function",
                    function: ToolCallFunction(name: "file_read", arguments: #"{"path":"x"}"#)
                )
            ]
            turn.toolResults = [id: result]
            return turn
        }
        let image = ToolEnvelope.success(
            tool: "file_read",
            result: [
                "kind": "image", "path": "pic.png", "text": "Image pic.png is attached", "image_ref": ["hash": "h"],
            ]
        )
        let workbook = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "workbook", "path": "b.xlsx", "text": "Workbook: b.xlsx"]
        )
        let ocr = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": "s.png", "source": "ocr_text", "text": "1|HELLO", "line_format": "N|"]
        )
        let raw = ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": "a.txt", "source": "raw_text", "text": "1|hello", "line_format": "N|"]
        )

        let known = ContentBlock.knownFileContents(in: [
            toolTurn(id: "1", result: image),
            toolTurn(id: "2", result: workbook),
            toolTurn(id: "3", result: ocr),
            toolTurn(id: "4", result: raw),
        ])
        #expect(known.map(\.path) == ["a.txt"])
        #expect(known.first?.content == "hello")
    }
}

// MARK: - Fixtures

extension FileReadImageAndFormatContractTests {
    /// 600x200 white PNG with large black text (or blank when `text` is nil).
    static func pngData(text: String?) -> Data {
        let size = NSSize(width: 600, height: 200)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 48),
                .foregroundColor: NSColor.black,
            ]
            NSAttributedString(string: text, attributes: attributes).draw(at: NSPoint(x: 30, y: 70))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func writePNG(text: String?, to url: URL) throws {
        try pngData(text: text).write(to: url)
    }

    static func writePDF(pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 220)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        for pageText in pages {
            ctx.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            NSAttributedString(string: pageText, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                .draw(at: NSPoint(x: 24, y: 160))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    enum FixtureError: Error { case contextCreationFailed }
}
