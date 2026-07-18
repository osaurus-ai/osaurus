//
//  SkillArchiveProcessRunnerTests.swift
//  OsaurusCoreTests
//
//  Exercises subprocess completion, bounded output, and cleanup failure paths
//  independently from ZIP archive contents.
//

import Darwin
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillArchiveProcessRunnerTests {
    @Test func normalCompletionCollectsOutput() throws {
        let result = try SkillArchiveProcessRunner.run(
            executablePath: "/usr/bin/printf",
            arguments: ["normal output"],
            timeoutSeconds: 2
        )

        #expect(result.terminationStatus == 0)
        #expect(result.output == "normal output")
        #expect(!result.outputTruncated)
        #expect(!result.timedOut)
    }

    @Test func dispatchStreamReadsThroughDuplicateAfterClosingOriginalHandle() throws {
        let pipe = Pipe()
        let originalDescriptor = pipe.fileHandleForReading.fileDescriptor
        let capture = SkillArchiveStreamCapture()
        let stream = try SkillArchiveDispatchOutputStream(
            fileHandle: pipe.fileHandleForReading,
            chunkBytes: 64
        )

        #expect(fcntl(originalDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)

        stream.start(
            onChunk: { capture.append($0) },
            onCompletion: { capture.finish(error: $0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("duplicated descriptor".utf8))
        try pipe.fileHandleForWriting.close()

        #expect(capture.waitForCompletion(timeoutSeconds: 1))
        #expect(capture.output == "duplicated descriptor")
        #expect(capture.error == nil)
    }

    @Test func repeatedRunsKeepDescriptorLifecycleStable() throws {
        for _ in 0..<100 {
            let result = try SkillArchiveProcessRunner.run(
                executablePath: "/usr/bin/printf",
                arguments: ["x"],
                timeoutSeconds: 2
            )
            #expect(result.output == "x")
            #expect(result.terminationStatus == 0)
        }
    }

    @Test func outputLimitKeepsDrainingUntilProcessExits() throws {
        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-runner-output-\(UUID().uuidString)"
        )
        try Data(repeating: 0x78, count: 128 * 1024).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let result = try SkillArchiveProcessRunner.run(
            executablePath: "/bin/cat",
            arguments: [fixtureURL.path],
            timeoutSeconds: 2,
            configuration: SkillArchiveProcessConfiguration(
                outputLimitBytes: 64,
                chunkBytes: 4 * 1024,
                cleanupGraceSeconds: 0.5
            )
        )

        #expect(result.terminationStatus == 0)
        #expect(result.output == String(repeating: "x", count: 64) + "\n[output truncated]")
        #expect(result.outputTruncated)
        #expect(!result.timedOut)
    }

    @Test func timeoutForceKillsAndReapsTermIgnoringProcess() async throws {
        let fixture = try Self.makeTermIgnoringFixture(prefix: "timeout")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let task = Task.detached {
            try SkillArchiveProcessRunner.run(
                executablePath: fixture.script.path,
                arguments: [fixture.pidFile.path],
                timeoutSeconds: 1,
                configuration: SkillArchiveProcessConfiguration(cleanupGraceSeconds: 0.1)
            )
        }

        let fixtureBecameReady = await Self.waitForFile(at: fixture.pidFile)
        let result = try await task.value

        #expect(fixtureBecameReady)
        #expect(result.timedOut)
        #expect(result.terminationStatus == SIGKILL)
        #expect(startedAt.duration(to: clock.now) < .seconds(3))
    }

    @Test func cancellationForceKillsTermIgnoringProcessWithinBound() async throws {
        let fixture = try Self.makeTermIgnoringFixture(prefix: "cancellation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let task = Task.detached {
            try SkillArchiveProcessRunner.run(
                executablePath: fixture.script.path,
                arguments: [fixture.pidFile.path],
                timeoutSeconds: 30,
                configuration: SkillArchiveProcessConfiguration(cleanupGraceSeconds: 0.1)
            )
        }

        guard let processID = await Self.waitForProcessID(at: fixture.pidFile) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("TERM-hostile fixture did not publish its process ID")
            return
        }
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            #expect(cancelledAt.duration(to: clock.now) < .seconds(2))
            #expect(await Self.waitForProcessExit(processID))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func outputReadErrorIsPropagatedInsteadOfBecomingEOF() throws {
        let stream = FailingSkillArchiveOutputStream()

        do {
            _ = try SkillArchiveProcessRunner.run(
                executablePath: "/usr/bin/true",
                arguments: [],
                timeoutSeconds: 2,
                configuration: SkillArchiveProcessConfiguration(
                    cleanupGraceSeconds: 0.1,
                    outputStream: stream
                )
            )
            Issue.record("Expected the injected output read error")
        } catch let error as InjectedSkillArchiveReadError {
            #expect(error == .failed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func incompleteDrainCancelsAndJoinsReaderBeforeThrowing() throws {
        let stream = StalledSkillArchiveOutputStream()

        do {
            _ = try SkillArchiveProcessRunner.run(
                executablePath: "/usr/bin/true",
                arguments: [],
                timeoutSeconds: 2,
                configuration: SkillArchiveProcessConfiguration(
                    cleanupGraceSeconds: 0.05,
                    outputStream: stream
                )
            )
            Issue.record("Expected an incomplete output drain error")
        } catch let error as SkillArchiveProcessRunnerError {
            #expect(error == .outputDrainIncomplete)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(stream.cancelRequested)
        #expect(stream.completionDelivered)
    }

    @Test func neverCompletingDrainCancellationFailsWithinBound() throws {
        let stream = NeverCompletingSkillArchiveOutputStream()
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try SkillArchiveProcessRunner.run(
                executablePath: "/usr/bin/true",
                arguments: [],
                timeoutSeconds: 2,
                configuration: SkillArchiveProcessConfiguration(
                    cleanupGraceSeconds: 0.05,
                    outputStream: stream
                )
            )
            Issue.record("Expected an incomplete output drain error")
        } catch let error as SkillArchiveProcessRunnerError {
            #expect(error == .outputDrainIncomplete)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(stream.cancelRequested)
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }

    @Test func cancellationReapsProcessAndJoinsReaderBeforeThrowing() async {
        let stream = StalledSkillArchiveOutputStream()
        let task = Task.detached {
            try SkillArchiveProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeoutSeconds: 30,
                configuration: SkillArchiveProcessConfiguration(
                    cleanupGraceSeconds: 0.05,
                    outputStream: stream
                )
            )
        }

        let readerStarted = stream.waitUntilStarted(timeoutSeconds: 2)
        task.cancel()

        #expect(readerStarted)
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            #expect(stream.cancelRequested)
            #expect(stream.completionDelivered)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func waitForFile(at url: URL) async -> Bool {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private static func waitForProcessExit(_ processID: pid_t) async -> Bool {
        for _ in 0..<100 {
            if Darwin.kill(processID, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private static func waitForProcessID(at url: URL) async -> pid_t? {
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
                let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processID
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private static func makeTermIgnoringFixture(
        prefix: String
    ) throws -> (root: URL, script: URL, pidFile: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-runner-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let script = root.appendingPathComponent("ignore-term.sh")
        let pidFile = root.appendingPathComponent("pid")
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\n' "$$" > "$1"
        while :; do :; done
        """
        .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        return (root, script, pidFile)
    }
}

private final class SkillArchiveStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var data = Data()
    private var completionError: NSError?

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish(error: (any Error)?) {
        lock.lock()
        completionError = error as NSError?
        lock.unlock()
        completed.signal()
    }

    func waitForCompletion(timeoutSeconds: TimeInterval) -> Bool {
        completed.wait(timeout: .now() + timeoutSeconds) == .success
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var error: NSError? {
        lock.lock()
        defer { lock.unlock() }
        return completionError
    }
}

private enum InjectedSkillArchiveReadError: Error, Equatable {
    case failed
}

private final class FailingSkillArchiveOutputStream: SkillArchiveProcessOutputStreaming, @unchecked Sendable {
    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        onChunk(Data("partial output".utf8))
        onCompletion(InjectedSkillArchiveReadError.failed)
    }

    func cancel() {}
}

private final class NeverCompletingSkillArchiveOutputStream: SkillArchiveProcessOutputStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var didRequestCancel = false

    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable ((any Error)?) -> Void
    ) {}

    func cancel() {
        lock.lock()
        didRequestCancel = true
        lock.unlock()
    }

    var cancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRequestCancel
    }
}

/// Models DispatchIO's asynchronous cleanup callback: cancellation schedules
/// completion, and the runner must wait for that completion before returning.
private final class StalledSkillArchiveOutputStream: SkillArchiveProcessOutputStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private var completion: (@Sendable ((any Error)?) -> Void)?
    private var didRequestCancel = false
    private var didDeliverCompletion = false

    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        lock.lock()
        completion = onCompletion
        lock.unlock()
        started.signal()
    }

    func cancel() {
        lock.lock()
        guard !didRequestCancel else {
            lock.unlock()
            return
        }
        didRequestCancel = true
        let handler = completion
        completion = nil
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            didDeliverCompletion = true
            lock.unlock()
            handler?(nil)
        }
    }

    func waitUntilStarted(timeoutSeconds: TimeInterval) -> Bool {
        started.wait(timeout: .now() + timeoutSeconds) == .success
    }

    var cancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRequestCancel
    }

    var completionDelivered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didDeliverCompletion
    }
}
