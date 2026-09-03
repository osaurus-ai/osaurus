//
//  ClaudeCodeLiveTests.swift
//  osaurusTests
//
//  End-to-end coverage that spawns the REAL `claude` CLI. Gated behind
//  `OSAURUS_RUN_CLAUDE_CODE_LIVE_TESTS=1` because it needs a signed-in
//  Claude Code install and spends the developer's own subscription quota,
//  so CI never runs it. Mirrors the gating of the sandbox integration
//  suites (`OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS`).
//
//  Run with:
//    OSAURUS_RUN_CLAUDE_CODE_LIVE_TESTS=1 \
//    OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
//    swift test --package-path Packages/OsaurusCore --filter ClaudeCodeLive
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(
    "Claude Code live CLI",
    .enabled(if: ProcessInfo.processInfo.environment["OSAURUS_RUN_CLAUDE_CODE_LIVE_TESTS"] == "1"),
    // Every test here spawns a real child and spends real quota. Running them
    // in parallel also makes the process-count assertions meaningless, since
    // one test's child is visible to another's `ps`.
    .serialized
)
struct ClaudeCodeLiveTests {

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-claude-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func binaryIsDiscoverable() throws {
        let path = try #require(
            ClaudeCodeConfiguration.resolveExecutable(),
            "claude not on PATH: \(ClaudeCodeConfiguration.searchedPath())"
        )
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    /// The whole path: spawn → NDJSON → decode → sentinel-encoded deltas.
    @Test func textOnlyTurnStreamsVisibleText() async throws {
        let service = ClaudeCodeService()
        let cwd = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

        let stream = try await service.streamDeltas(
            messages: [
                ChatMessage(role: "system", content: "Reply with exactly one word."),
                ChatMessage(role: "user", content: "Reply with the single word: osaurus"),
            ],
            parameters: GenerationParameters(
                temperature: nil,
                maxTokens: 256,
                claudeCode: ClaudeCodeRunOptions(mode: .textOnly, workingDirectory: cwd)
            ),
            requestedModel: ClaudeCodeModel.haiku.pickerId,
            stopSequences: []
        )

        var visible = ""
        var sawStats = false
        for try await delta in stream {
            if StreamingStatsHint.decode(delta) != nil {
                sawStats = true
            } else if !StreamingToolHint.isSentinel(delta) {
                visible += delta
            }
        }

        #expect(visible.lowercased().contains("osaurus"))
        // A turn that produced no usage frame means the terminal `result`
        // frame was never decoded.
        #expect(sawStats)
        // Sentinels must never leak into visible prose.
        #expect(!visible.contains("\u{FFFE}"))
    }

    /// Count live `claude --print` children belonging to this user.
    ///
    /// The registry alone is not sufficient evidence: it unregisters in a
    /// `defer` whether or not the child actually died, so a leak would look
    /// clean there. This asks the OS.
    private func liveClaudeChildCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains("claude") && $0.contains("--print") }
            .count
    }

    /// Stop must kill the child, not merely cancel the awaiting Task. A
    /// cancelled Task that leaves `claude` running would keep burning the
    /// user's subscription quota invisibly.
    @Test func cancellationTerminatesTheChildProcess() async throws {
        let service = ClaudeCodeService()
        let cwd = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: cwd) }

        let before = liveClaudeChildCount()

        let task = Task {
            let stream = try await service.streamDeltas(
                messages: [
                    ChatMessage(
                        role: "user",
                        content:
                            "Write a very long essay about the history of the Swift programming language. At least 3000 words."
                    )
                ],
                parameters: GenerationParameters(
                    temperature: nil,
                    maxTokens: 8192,
                    claudeCode: ClaudeCodeRunOptions(mode: .textOnly, workingDirectory: cwd)
                ),
                requestedModel: ClaudeCodeModel.haiku.pickerId,
                stopSequences: []
            )
            for try await _ in stream {}
        }

        // Poll for the child instead of assuming a fixed spawn delay — a short
        // turn could otherwise finish before a hardcoded sleep elapsed and make
        // this look like a spawn failure.
        var spawned = false
        for _ in 0 ..< 40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if liveClaudeChildCount() > before {
                spawned = true
                break
            }
        }
        #expect(spawned, "the run never spawned a visible child process")

        task.cancel()
        _ = try? await task.value

        // SIGTERM lands in ~1s; allow for the runner's 2s SIGKILL escalation.
        var drained = false
        for _ in 0 ..< 24 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if liveClaudeChildCount() <= before, await ClaudeCodeProcessRegistry.shared.liveCount() == 0 {
                drained = true
                break
            }
        }
        #expect(drained, "a cancelled run orphaned a claude process")
    }

    /// A bad binary path must produce a typed error, never a silent empty
    /// stream that looks like the model had nothing to say.
    @Test func missingBinaryFailsLoudly() async throws {
        let events = ClaudeCodeProcessRunner.stream(
            executable: "/nonexistent/claude",
            arguments: ["--print"],
            prompt: "hi",
            workingDirectory: FileManager.default.temporaryDirectory
        )

        await #expect(throws: ClaudeCodeError.self) {
            for try await _ in events {}
        }
    }
}
