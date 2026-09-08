import Containerization
import Foundation
import Testing

@testable import OsaurusCore

/// Real pipes and confined disposable commands. Unlike the host-availability
/// profile suite, an executor timeout here is a failure, not a skipped assertion.
@Suite(.serialized)
struct SeatbeltExecutorProcessTests {
    @Test func endOfFileDetachesReadabilityHandler() async throws {
        let pipe = Pipe()
        let output = Output()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            SeatbeltExecutor.consumeAvailableData(from: handle, append: output.append)
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        try pipe.fileHandleForWriting.write(contentsOf: Data("before-eof".utf8))
        try pipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while pipe.fileHandleForReading.readabilityHandler != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
        #expect(output.text == "before-eof")
    }

    @Test func normalAndNonzeroExitKeepBothStreams() async throws {
        for code in [0, 7] {
            let result = try await execute("printf stdout; printf stderr >&2; exit \(code)")
            #expect(result.exitCode == Int32(code))
            #expect(result.stdout == "stdout")
            #expect(result.stderr == "stderr")
        }
    }

    @Test func drainsOutputLargerThanPipeCapacityAndTeeAgrees() async throws {
        let tee = Output()
        let result = try await execute(
            "/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' x",
            stdout: tee
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == String(repeating: "x", count: 262144))
        #expect(tee.text == result.stdout)
    }

    @Test func closedStreamsDoNotPreventLaterExitStatus() async throws {
        let result = try await execute("exec 1>&- 2>&-; /bin/sleep 0.2; exit 9")
        #expect(result.exitCode == 9)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test func inheritedPipeDoesNotExtendParentLifetime() async throws {
        let start = Date()
        let result = try await execute("(/bin/sleep 2) & printf parent; exit 0")
        #expect(result.exitCode == 0)
        #expect(result.stdout == "parent")
        #expect(Date().timeIntervalSince(start) < 1.5)
        // Let the deliberately short-lived descendant exit before the next test.
        try await Task.sleep(for: .seconds(2))
    }

    @Test func inactivityTimeoutIsNotAFalseSuccessfulExit() async throws {
        let start = Date()
        await #expect(throws: SandboxError.self) {
            do {
                _ = try await execute("exec /bin/sleep 5", timeout: 0.15)
            } catch SandboxError.timeout {
                throw SandboxError.timeout
            } catch {
                Issue.record("Expected timeout, got \(error)")
                throw error
            }
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func pythonShimReturnsRealOutputAndExitStatus() async throws {
        let result = try await execute("/usr/bin/python3 -c \"print('executor-python-ok')\"")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout == "executor-python-ok\n")
    }

    private func execute(
        _ command: String,
        timeout: TimeInterval = 5,
        stdout: (any Writer)? = nil
    ) async throws -> ContainerExecResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-executor-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: root.path,
            tempDir: SeatbeltSandbox.scratchDir,
            network: .denied,
            developerDirectory: SeatbeltSandbox.activeDeveloperDirectory
        )
        return try await SeatbeltExecutor.run(
            .init(
                command: command,
                env: [:],
                cwd: root.path,
                timeout: timeout,
                profile: profile,
                stdoutTee: stdout,
                stderrTee: nil,
                onProcessStarted: nil
            )
        )
    }

    private final class Output: Writer, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        func write(_ chunk: Data) throws { append(chunk) }
        func close() throws {}
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
