import Foundation
import os

/// User cancellation may stop a queued GPU acquisition, but never cancel the
/// task consuming an already-started engine stream. AsyncStream otherwise ends
/// iteration before its unstructured producer has drained.
final class ImageJobCancellation: Sendable {
    private let requested = OSAllocatedUnfairLock(initialState: false)
    private let gateWait: Task<Void, Error>

    init(enter: @escaping @Sendable () async throws -> Void) {
        gateWait = Task { try await enter() }
    }

    var isRequested: Bool { requested.withLock { $0 } }

    func enter() async throws {
        try await gateWait.value
    }

    func cancel() {
        requested.withLock { $0 = true }
        gateWait.cancel()
    }
}
