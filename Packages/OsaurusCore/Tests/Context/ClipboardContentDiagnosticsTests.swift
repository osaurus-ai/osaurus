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

        #expect(unchanged.needsUserAttention)
        #expect(unchanged.userFacingMessage.contains("Selection unavailable"))
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

    @Test @MainActor func selectionArrivingBeforeOverlayDeadlineIsCaptured() async {
        let environment = ScriptedSelectionEnvironment(
            copyScripts: [[.init(afterPolls: 2, content: .text("early selection"))]]
        )
        let result = await makeTransaction(environment).capture(sourceApp: "Pages")

        #expect(result.text == "early selection")
        #expect(result.report.outcome == .capturedText(characterCount: 15))
        #expect(environment.pollCount == 2)
    }

    @Test @MainActor func selectionArrivingBetweenOverlayDeadlineAndCaptureTimeoutIsCaptured() async {
        let environment = ScriptedSelectionEnvironment(
            copyScripts: [[.init(afterPolls: 4, content: .text("slow selection"))]]
        )
        let result = await makeTransaction(environment).capture(sourceApp: "Safari")

        #expect(result.text == "slow selection")
        #expect(result.report.outcome == .capturedText(characterCount: 14))
        #expect(environment.pollCount == 4)
    }

    @Test @MainActor func lateTimedOutResponseIsDrainedBeforeNextTransaction() async {
        let environment = ScriptedSelectionEnvironment(
            copyScripts: [
                [.init(afterPolls: 11, content: .text("late response from A"))],
                [.init(afterPolls: 2, content: .text("selection from B"))],
            ]
        )
        let transaction = makeTransaction(environment)

        let first = await transaction.capture(sourceApp: "Notes")
        let second = await transaction.capture(sourceApp: "Mail")

        #expect(first.report.outcome == .pasteboardUnchanged)
        #expect(first.report.needsUserAttention)
        #expect(second.text == "selection from B")
        #expect(second.report.sourceApp == "Mail")
        #expect(environment.copyCount == 2)
        #expect(environment.drainedContents.contains("late response from A"))
    }

    @Test @MainActor func rapidHotkeysCoalesceIntoOneOverlayToggle() async {
        let gate = SelectionCaptureGate()
        var toggleCount = 0
        let controller = SelectionHotkeyIntentController(
            openDelayNanos: 1,
            sleep: { _ in await Task.yield() }
        )

        let accepted = controller.invoke(
            captureSelection: { await gate.wait() },
            toggleOverlay: { toggleCount += 1 }
        )
        let coalesced = controller.invoke(
            captureSelection: { Issue.record("coalesced capture must not start") },
            toggleOverlay: { toggleCount += 1 }
        )

        for _ in 0 ..< 10 where toggleCount == 0 { await Task.yield() }
        #expect(accepted)
        #expect(!coalesced)
        #expect(toggleCount == 1)
        gate.release()
        for _ in 0 ..< 10 where controller.isProcessing { await Task.yield() }
        #expect(toggleCount == 1)
        #expect(!controller.isProcessing)
    }

    @Test @MainActor func identicalClipboardContentStillCountsAsFreshSelection() async {
        let environment = ScriptedSelectionEnvironment(
            initialContent: .text("same selection"),
            copyScripts: [[.init(afterPolls: 1, content: .text("same selection"))]]
        )
        let result = await makeTransaction(environment).capture(sourceApp: "Xcode")

        #expect(result.text == "same selection")
        #expect(result.report.outcome == .capturedText(characterCount: 14))
    }

    @Test @MainActor func deniedAccessibilityIsReportedWithoutPolling() async {
        let environment = ScriptedSelectionEnvironment(copyAllowed: false)
        let result = await makeTransaction(environment).capture(sourceApp: "Preview")

        #expect(result.report.outcome == .accessibilityDenied)
        #expect(result.report.needsUserAttention)
        #expect(environment.pollCount == 0)
    }

    @Test @MainActor func changedPasteboardWithoutReadableContentIsReported() async {
        let environment = ScriptedSelectionEnvironment(
            copyScripts: [[.init(afterPolls: 1, content: nil)]]
        )
        let result = await makeTransaction(environment).capture(sourceApp: "Finder")

        #expect(result.report.outcome == .noReadableContent)
        #expect(result.text == nil)
    }

    @Test @MainActor func dismissAndReadClearStaleSelectionReport() async {
        let environment = ScriptedSelectionEnvironment(
            copyScripts: [
                [.init(afterPolls: 1, content: nil)],
                [.init(afterPolls: 1, content: nil)],
            ]
        )
        let service = ClipboardService(selectionCapture: makeTransaction(environment))

        _ = await service.grabSelectionReport()
        #expect(service.lastSelectionGrabReport != nil)
        service.dismissSelectionGrabReport()
        #expect(service.lastSelectionGrabReport == nil)

        _ = await service.grabSelectionReport()
        #expect(service.lastSelectionGrabReport != nil)
        service.markAsRead()
        #expect(service.lastSelectionGrabReport == nil)
    }

    @MainActor
    private func makeTransaction(
        _ environment: ScriptedSelectionEnvironment
    ) -> SelectionCaptureTransaction {
        SelectionCaptureTransaction(
            dependencies: .init(
                snapshot: { environment.snapshot() },
                postCopy: { environment.postCopy() },
                sleep: { _ in environment.advancePoll() }
            ),
            timing: .init(
                pollIntervalNanos: 50_000_000,
                captureTimeoutNanos: 500_000_000,
                drainQuietNanos: 500_000_000,
                drainLimitNanos: 1_000_000_000
            )
        )
    }
}

@MainActor
private final class SelectionCaptureGate {
    private var released = false

    func wait() async {
        while !released { await Task.yield() }
    }

    func release() {
        released = true
    }
}

@MainActor
private final class ScriptedSelectionEnvironment {
    struct Event {
        let afterPolls: Int
        let content: ClipboardService.ClipboardContent?
    }

    private struct ScheduledEvent {
        let poll: Int
        let content: ClipboardService.ClipboardContent?
    }

    private(set) var pollCount = 0
    private(set) var copyCount = 0
    private(set) var drainedContents: [String] = []
    private var changeCount = 1
    private var content: ClipboardService.ClipboardContent?
    private var copyScripts: [[Event]]
    private var scheduled: [ScheduledEvent] = []
    private let copyAllowed: Bool

    init(
        initialContent: ClipboardService.ClipboardContent? = nil,
        copyAllowed: Bool = true,
        copyScripts: [[Event]] = []
    ) {
        content = initialContent
        self.copyAllowed = copyAllowed
        self.copyScripts = copyScripts
    }

    func snapshot() -> SelectionCaptureTransaction.Snapshot {
        .init(changeCount: changeCount, content: content)
    }

    func postCopy() -> Bool {
        guard copyAllowed else { return false }
        copyCount += 1
        if !copyScripts.isEmpty {
            scheduled += copyScripts.removeFirst().map {
                ScheduledEvent(poll: pollCount + $0.afterPolls, content: $0.content)
            }
        }
        return true
    }

    func advancePoll() {
        pollCount += 1
        let ready = scheduled.filter { $0.poll == pollCount }
        scheduled.removeAll { $0.poll == pollCount }
        for event in ready {
            changeCount += 1
            content = event.content
            if case .text(let text) = event.content, copyCount == 1, pollCount > 10 {
                drainedContents.append(text)
            }
        }
    }
}
