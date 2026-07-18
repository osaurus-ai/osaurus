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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-runner-timeout-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("ignore-term.sh")
        let readyURL = root.appendingPathComponent("ready")
        try """
        #!/bin/sh
        trap '' TERM
        printf 'ready\n' > "$1"
        while :; do :; done
        """
        .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let task = Task.detached {
            try SkillArchiveProcessRunner.run(
                executablePath: scriptURL.path,
                arguments: [readyURL.path],
                timeoutSeconds: 1,
                configuration: SkillArchiveProcessConfiguration(cleanupGraceSeconds: 0.1)
            )
        }

        let fixtureBecameReady = await Self.waitForFile(at: readyURL)
        let result = try await task.value

        #expect(fixtureBecameReady)
        #expect(result.timedOut)
        #expect(result.terminationStatus == SIGKILL)
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
