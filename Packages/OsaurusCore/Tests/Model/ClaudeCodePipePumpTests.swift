import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code pipe delivery ownership")
struct ClaudeCodePipePumpTests {
    @Test func finalDrainIncludesInFlightCallbackAndIsIdempotent() async throws {
        let pipe = Pipe()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let state = PipeDeliveryFixture()
        let pump = ClaudeCodePipePump(handle: pipe.fileHandleForReading) { bytes in
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { return }
            state.append(bytes)
        }
        pump.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("terminal frame".utf8))
        try pipe.fileHandleForWriting.close()
        let didEnter = await background { entered.wait(timeout: .now() + 10) == .success }
        #expect(didEnter)
        guard didEnter else { pump.stop(); return }
        let drain = Task { await background { pump.finish() } }
        release.signal()
        await drain.value
        #expect(state.value == Data("terminal frame".utf8))
        pump.finish()
        #expect(state.value == Data("terminal frame".utf8))
    }

    @Test func exitDrainReadsBytesBeforeCallbackStarts() throws {
        let pipe = Pipe()
        let state = PipeDeliveryFixture()
        let pump = ClaudeCodePipePump(handle: pipe.fileHandleForReading) { state.append($0) }
        try pipe.fileHandleForWriting.write(contentsOf: Data("trailing bytes".utf8))
        try pipe.fileHandleForWriting.close()
        pump.finish()
        #expect(state.value == Data("trailing bytes".utf8))
    }

    @Test func stoppedPumpDoesNotDeliverQueuedOutput() throws {
        let pipe = Pipe()
        let state = PipeDeliveryFixture()
        let pump = ClaudeCodePipePump(handle: pipe.fileHandleForReading) { state.append($0) }
        pump.stop()
        try pipe.fileHandleForWriting.write(contentsOf: Data("discarded".utf8))
        try pipe.fileHandleForWriting.close()
        pump.finish()
        #expect(state.value.isEmpty)
    }

    private func background<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: operation()) }
        }
    }
}

private final class PipeDeliveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(value)
    }
    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
