//
//  ChatResidencyHandoffRestoreTests.swift
//  osaurus
//
//  Restore-path robustness for the chat↔(image/spawn) handoff. The post-job
//  reload now verifies the model is actually resident, retries once, throws a
//  typed `restoreFailed` on a persistent miss, and the best-effort wrapper
//  swallows that failure so an already-produced image is never lost. These
//  exercise the real `ModelRuntime.preload` failure path (an unresolvable
//  model name fast-throws "Installed model not found" before any GPU work), so
//  no model load or Metal device is required.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatResidencyHandoffRestoreTests {

    /// A name `ModelManager.findInstalledModel` can never resolve, so `preload`
    /// fast-throws before touching the GPU — driving the restore failure +
    /// single-retry path deterministically.
    private static let unresolvable =
        "__osaurus_nonexistent_restore_test_model_4f9a__"

    @Test("empty lease restore is a no-op and touches nothing")
    func emptyLeaseIsNoOp() async throws {
        let restored = try await ChatResidencyHandoff.restore(.empty)
        #expect(restored.isEmpty)
    }

    @Test("typed handoff failures preserve actionable localized descriptions")
    func handoffFailuresPreserveLocalizedDescriptions() {
        let insufficient = ChatResidencyHandoff.HandoffError.insufficientMemory(
            neededGB: 59.3,
            availableGB: 54.1
        )
        #expect(
            insufficient.localizedDescription
                == "RAM-safety preflight refused the job: the spawn model needs ~59.3 GB but only ~54.1 GB would be available after freeing the chat model. Use a smaller spawn model, free memory, or disable the RAM-safety preflight in Agent Delegation settings."
        )

        let busy = ChatResidencyHandoff.HandoffError.chatBusy
        #expect(
            busy.localizedDescription
                == "local chat generation did not become idle before the subagent memory handoff"
        )
    }

    @Test("restore throws restoreFailed when a model can't be made resident")
    func restoreThrowsRestoreFailedOnPersistentMiss() async {
        let lease = ChatResidencyLease(unloadedModelNames: [Self.unresolvable])
        var captured: ChatResidencyHandoff.HandoffError?
        do {
            _ = try await ChatResidencyHandoff.restore(lease)
            Issue.record("restore should have thrown for an unresolvable model")
        } catch let error as ChatResidencyHandoff.HandoffError {
            captured = error
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        guard case .restoreFailed(let models)? = captured else {
            Issue.record("expected .restoreFailed, got \(String(describing: captured))")
            return
        }
        #expect(models == [Self.unresolvable])
    }

    @Test("restore surfaces a retry attempt and a restore_failed phase before throwing")
    func restoreEmitsRetryAndFailurePhases() async {
        let lease = ChatResidencyLease(unloadedModelNames: [Self.unresolvable])
        let phases = PhaseLog()
        _ = try? await ChatResidencyHandoff.restore(lease) { phase, _ in
            phases.add(phase)
        }
        let recorded = phases.value
        // The single retry is attempted, and a terminal failure phase is
        // surfaced so the chat shows a recoverable error instead of a silent,
        // model-less window.
        #expect(recorded.contains("restoring_chat_models_retry"))
        #expect(recorded.contains("restore_failed"))
    }

    @Test("restoreBestEffort swallows a persistent failure so the image is never lost")
    func bestEffortSwallowsPersistentFailure() async {
        let lease = ChatResidencyLease(unloadedModelNames: [Self.unresolvable])
        let restored = await ChatResidencyHandoff.restoreBestEffort(lease)
        #expect(restored.isEmpty)
    }

    @Test("restore delegates load arbitration atomically to ModelRuntime")
    func restoreUsesAtomicHandoffIntent() throws {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent()  // AgentDelegation/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Services/AgentDelegation/ChatResidencyHandoff.swift"
            ),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private static func reloadAndVerify("))
        let end = try #require(
            source.range(of: "\n    }\n}", range: start.upperBound ..< source.endIndex)
        )
        let body = String(source[start.lowerBound ..< end.upperBound])

        #expect(body.contains("intent: .handoffRestore"))
        #expect(
            !body.contains("await ModelRuntime.shared.hasLoadInFlight"),
            "restore may not use the diagnostics-only check-then-preload race"
        )
    }
}

/// Thread-safe ordered capture for the restore `onPhase` callback.
private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []
    func add(_ phase: String) {
        lock.lock()
        phases.append(phase)
        lock.unlock()
    }
    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}
