import Foundation
import Testing

@testable import OsaurusCore

@Suite("Clipboard content diagnostics")
struct ClipboardContentDiagnosticsTests {

    @Test func textDiagnosticsRedactClipboardPayload() {
        let secret = "sk-live-secret-value in the copied quarterly plan"
        let summary = ClipboardService.ClipboardContent.text(secret).redactedDiagnosticDescription

        #expect(summary == "text(characters: \(secret.count))")
        #expect(summary.contains("sk-live") == false)
        #expect(summary.contains("quarterly") == false)
    }

    @Test func imageDiagnosticsRedactBinaryPayload() {
        let data = Data("not really png but still sensitive bytes".utf8)
        let summary = ClipboardService.ClipboardContent.image(data).redactedDiagnosticDescription

        #expect(summary == "image(bytes: \(data.count))")
        #expect(summary.contains("sensitive") == false)
    }

    @Test func fileDiagnosticsRedactAbsolutePathAndFilename() {
        let url = URL(fileURLWithPath: "/Users/example/Desktop/Acquisition Targets.xlsx")
        let summary = ClipboardService.ClipboardContent.file(url).redactedDiagnosticDescription

        #expect(summary == "file(extension: xlsx)")
        #expect(summary.contains("/Users/example") == false)
        #expect(summary.contains("Acquisition") == false)
    }

    @Test func clipboardDetectionAvoidsPasteboardObjectConversionEnumeration() throws {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(
            "Services/Context/ClipboardService.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("pb.readObjects(forClasses:") == false)
        #expect(source.contains("string(forType: type)"))
        #expect(source.contains("Sentry APPLE-MACOS-2N"))
    }

    @Test func pasteMonitorAvoidsPasteboardTypeAndObjectConversionEnumeration() throws {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(
            "Views/Chat/FloatingInputCard.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let methodStart = try #require(source.range(of: "private func handlePasteIfImage() -> Bool"))
        let methodEnd = try #require(
            source.range(
                of: "\n    }\n}\n\n// MARK: - NSImage PNG Conversion",
                range: methodStart.upperBound ..< source.endIndex
            )
        )
        let methodBody = String(source[methodStart.lowerBound ..< methodEnd.lowerBound])

        #expect(!methodBody.contains("pasteboard.types"))
        #expect(!methodBody.contains("readObjects(forClasses:"))
        #expect(methodBody.contains("string(forType: type)"))
        #expect(methodBody.contains("Sentry APPLE-MACOS-43"))
    }
}
