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
