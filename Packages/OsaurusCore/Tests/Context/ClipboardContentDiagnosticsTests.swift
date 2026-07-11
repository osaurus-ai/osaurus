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

    @Test func selectionGrabReportRedactsCapturedTextPayload() {
        let secret = "client acquisition plan sk-live-secret"
        let report = ClipboardService.SelectionGrabReport(
            outcome: .capturedText(characterCount: secret.count),
            sourceApp: "Pages"
        )

        #expect(report.needsUserAttention == false)
        #expect(report.userFacingMessage.contains("\(secret.count) characters"))
        #expect(report.redactedDiagnosticDescription.contains("characters: \(secret.count)"))
        #expect(report.redactedDiagnosticDescription.contains("Pages"))
        #expect(report.redactedDiagnosticDescription.contains("sk-live") == false)
        #expect(report.redactedDiagnosticDescription.contains("acquisition") == false)
    }

    @Test func selectionGrabFailureReportsAreActionableAndPayloadFree() {
        let denied = ClipboardService.SelectionGrabReport(
            outcome: .accessibilityDenied,
            sourceApp: "Safari"
        )
        let unchanged = ClipboardService.SelectionGrabReport(
            outcome: .pasteboardUnchanged,
            sourceApp: nil
        )

        #expect(denied.needsUserAttention)
        #expect(denied.userFacingMessage.contains("Accessibility"))
        #expect(denied.redactedDiagnosticDescription == "selection_grab(outcome: accessibility_denied, source: Safari)")

        #expect(!unchanged.needsUserAttention)
        #expect(unchanged.userFacingMessage.contains("No selection"))
        #expect(unchanged.redactedDiagnosticDescription == "selection_grab(outcome: pasteboard_unchanged, source: unknown)")
    }

    @Test func selectionGrabNonTextReportUsesRedactedContentSummary() {
        let report = ClipboardService.SelectionGrabReport(
            outcome: .capturedNonText(kind: .file),
            sourceApp: "Finder"
        )

        #expect(report.needsUserAttention == false)
        #expect(report.userFacingMessage == "Captured a file, but only text selections can be inserted automatically.")
        #expect(report.redactedDiagnosticDescription.contains("kind: file"))
        #expect(report.redactedDiagnosticDescription.contains("Finder"))
    }

    @Test func hotkeySelectionGrabAwaitsBeforeOverlayTakesFocus() throws {
        let source = try sourceFile("AppDelegate.swift")

        let applyHotkeyStart = try #require(source.range(of: "func applyChatHotkey()"))
        let helperStart = try #require(source.range(of: "private func captureSelectionForHotkey"))
        let applySection = String(source[applyHotkeyStart.lowerBound ..< helperStart.lowerBound])

        #expect(applySection.contains("captureSelectionForHotkey(withMaxWaitNanos"))
        #expect(!applySection.contains("grabSelectionReport()"))

        let helperSection = String(source[helperStart.lowerBound ..< source.endIndex])
        #expect(helperSection.contains("withCheckedContinuation"))
        #expect(helperSection.contains("resumeSelectionFlowOnce(timeout:"))
        #expect(helperSection.contains("Task.sleep"))
    }

    @Test func selectionFailureChipTakesPriorityOverUnreadClipboardChip() throws {
        let source = try sourceFile("Views/Chat/FloatingInputCard.swift")
        let sectionStart = try #require(
            source.range(of: "// Clipboard / paste chip — last in the left cluster.")
        )
        let sectionEnd = try #require(
            source.range(of: "\n                Spacer()", range: sectionStart.upperBound ..< source.endIndex)
        )
        let section = String(source[sectionStart.lowerBound ..< sectionEnd.lowerBound])

        let failureCheck = try #require(
            section.range(of: "clipboardService.lastSelectionGrabReport?.needsUserAttention == true")
        )
        let clipboardCheck = try #require(section.range(of: "clipboardService.hasNewContent"))

        #expect(failureCheck.lowerBound < clipboardCheck.lowerBound)
        #expect(section.contains("selectionGrabStatusChip"))
        #expect(section.contains("clipboardToggleChip"))
    }

    @Test func clipboardRefreshAndDismissClearStaleSelectionReports() throws {
        let source = try sourceFile("Services/Context/ClipboardService.swift")

        let refreshStart = try #require(source.range(of: "private func performPasteboardRefresh"))
        let refreshEnd = try #require(
            source.range(of: "\n    nonisolated private static func detectContent", range: refreshStart.upperBound ..< source.endIndex)
        )
        let refreshBody = String(source[refreshStart.lowerBound ..< refreshEnd.lowerBound])

        let markStart = try #require(source.range(of: "public func markAsRead()"))
        let markEnd = try #require(
            source.range(of: "\n    /// Clear the latest selection-grab diagnostic", range: markStart.upperBound ..< source.endIndex)
        )
        let markBody = String(source[markStart.lowerBound ..< markEnd.lowerBound])

        #expect(refreshBody.contains("lastSelectionGrabReport = nil"))
        #expect(markBody.contains("lastSelectionGrabReport = nil"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
