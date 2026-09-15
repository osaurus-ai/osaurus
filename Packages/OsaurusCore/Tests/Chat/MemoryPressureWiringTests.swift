import XCTest

@testable import OsaurusCore

final class MemoryPressureWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testComposerHasNoSwapWarningOrAcknowledgmentGate() throws {
        let card = try source("Views/Chat/FloatingInputCard.swift")
        for removed in [
            "SwapPressureMonitor", "MemoryWarningState", "MemoryPressureAdvisory",
            "Use Anyway", "memory-warning.", "projectedLoadFeasibility", "memorySendCheckInFlight",
        ] {
            XCTAssertFalse(card.contains(removed), removed)
        }
        XCTAssertTrue(card.contains("commitSend(localText)"))
        XCTAssertTrue(card.contains("SendNowButton(action: dispatchQueuedNow)"))
        XCTAssertTrue(card.contains("configContextErrorBanner"))
        XCTAssertTrue(card.contains("refreshMTPLayoutAdvisory()"))
    }

    func testRemainingBundleAdvisoryStaysLocal() {
        XCTAssertTrue(FloatingInputCard.localBundleAdvisoriesApply(isSelectedModelLocal: true, isRemoteAgentRun: false))
        XCTAssertFalse(
            FloatingInputCard.localBundleAdvisoriesApply(isSelectedModelLocal: false, isRemoteAgentRun: false)
        )
        XCTAssertFalse(FloatingInputCard.localBundleAdvisoriesApply(isSelectedModelLocal: true, isRemoteAgentRun: true))
    }

    func testDiagnosticsAreIndependentOfAnOpenComposer() throws {
        let monitor = try source("Services/SystemMonitorService.swift")
        XCTAssertTrue(monitor.contains("let memoryObservation = SwapPressureMonitor.shared.currentState()"))
        XCTAssertTrue(monitor.contains("FeatureTelemetry.observeModelMemory(memoryObservation)"))
        let telemetry = try source("Services/FeatureTelemetry.swift")
        XCTAssertTrue(telemetry.contains("modelMemoryLimiter.shouldRecord(state)"))
        XCTAssertTrue(telemetry.contains("service.track(\"model_memory_sample\""))
    }

    func testFocusIsReadOnlyAndSavingRefreshesIdlePolicy() throws {
        let runtime = try source("Services/ModelRuntime.swift")
        let start = try XCTUnwrap(runtime.range(of: "func chatActivationResidencySnapshot("))
        let end = try XCTUnwrap(
            runtime.range(of: "func withModelDeletionLease", range: start.upperBound ..< runtime.endIndex)
        )
        let focus = String(runtime[start.lowerBound ..< end.lowerBound])
        XCTAssertFalse(focus.contains("removeValue"))
        XCTAssertFalse(focus.contains(".cancel("))
        let server = try source("Networking/ServerController.swift")
        XCTAssertTrue(server.contains("previousIdlePolicy != configuration.modelIdleResidencyPolicy"))
        XCTAssertTrue(server.contains("ModelRuntime.shared.refreshIdleResidencyPolicy()"))
        XCTAssertTrue(runtime.contains("await ModelLease.shared.count(for: modelName) == 0"))
    }
}
