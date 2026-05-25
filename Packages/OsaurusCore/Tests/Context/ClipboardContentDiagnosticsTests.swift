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
}
