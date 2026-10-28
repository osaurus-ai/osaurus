//
//  HarnessLiveTests.swift
//  osaurusTests
//
//  End-to-end runs against the REAL harness CLIs. Gated because they need a
//  signed-in Claude Code / a configured Pi and spend the developer's quota.
//
//  Run with:
//    OSAURUS_RUN_HARNESS_LIVE_TESTS=1 \
//    OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
//    OSAURUS_TEST_ROOT=/tmp/osaurus-test \
//    swift test --package-path Packages/OsaurusCore --filter HarnessLive
//
//  Optional: OSAURUS_LIVE_CLAUDE (default `claude`), OSAURUS_LIVE_PI (default
//  `pi`), OSAURUS_LIVE_PI_ARGS (extra space-separated args, e.g. a
//  `--provider`/`--model` pair).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(
    "Harness live CLIs",
    .enabled(if: ProcessInfo.processInfo.environment["OSAURUS_RUN_HARNESS_LIVE_TESTS"] == "1"),
    .serialized
)
struct HarnessLiveTests {

    private static let env = ProcessInfo.processInfo.environment

    private func run(
        _ text: String,
        on session: HarnessSession,
        context: HarnessLaunchContext
    ) async throws -> [HarnessEvent] {
        try await HarnessFixtures.collect(session.send(HarnessUserMessage(text: text), context: context))
    }

    private func tokensPerSecond(_ events: [HarnessEvent]) -> Double? {
        for case .stats(_, let tps, _) in events { return tps }
        return nil
    }

    // MARK: - Claude Code

    private var claudeRuntime: HarnessRuntime {
        HarnessRuntime(
            id: HarnessRuntime.builtInClaudeCodeId,
            name: "Claude Code",
            kind: .claudeCode,
            executable: Self.env["OSAURUS_LIVE_CLAUDE"] ?? "claude"
        )
    }

    @Test func claudeKeepsOneProcessPerChatAndResumesAfterRelaunch() async throws {
        let directory = try HarnessFixtures.temporaryDirectory("live-claude")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chatId = UUID()
        let context = HarnessFixtures.context(
            runtime: claudeRuntime,
            chatId: chatId,
            workingDirectory: directory,
            systemPrompt: "Answer as briefly as possible.",
            claudeCode: ClaudeCodeAgentConfig(mode: .textOnly, model: "haiku")
        )

        let session = HarnessSession(chatId: chatId)
        let first = try await run(
            "Remember the codeword PELICAN-42. Reply with only: OK",
            on: session,
            context: context
        )
        let pid = try #require(await session.processId)
        let second = try await run("What is the codeword? Reply with only the codeword.", on: session, context: context)

        #expect(first.visibleText.contains("OK"), "got: \(first.visibleText)")
        #expect(second.visibleText.contains("PELICAN-42"), "got: \(second.visibleText)")
        #expect(await session.processId == pid, "both turns must share one process")
        let tps = try #require(tokensPerSecond(second))
        print("[HarnessLive] claude turn2 tokens/s = \(tps)")
        #expect(tps > 0)

        await session.close(grace: 5)
        #expect(!HarnessFixtures.isAlive(pid))

        let relaunched = HarnessSession(chatId: chatId)
        let third = try await run(
            "Repeat the codeword one more time. Reply with only the codeword.",
            on: relaunched,
            context: context
        )
        #expect(third.visibleText.contains("PELICAN-42"), "resume lost the conversation: \(third.visibleText)")
        let relaunchedPid = try #require(await relaunched.processId)
        #expect(relaunchedPid != pid)
        await relaunched.close(grace: 5)
    }

    @Test func claudeStopEndsTheTurnAndTheChatContinues() async throws {
        let directory = try HarnessFixtures.temporaryDirectory("live-claude-stop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = HarnessFixtures.context(
            runtime: claudeRuntime,
            workingDirectory: directory,
            claudeCode: ClaudeCodeAgentConfig(mode: .textOnly, model: "haiku")
        )
        let session = HarnessSession(chatId: context.chatId)

        let started = Date()
        let stream = try await session.send(
            HarnessUserMessage(text: "Write the numbers from 1 to 400, one per line, with a short word after each."),
            context: context
        )
        var interrupted = false
        for try await event in stream {
            if case .text = event, !interrupted {
                interrupted = true
                await session.interrupt()
            }
        }
        #expect(interrupted)
        #expect(Date().timeIntervalSince(started) < HarnessSession.interruptGrace + 30)
        #expect(await !session.isBusy)

        let next = try await run("Reply with only the word: ready", on: session, context: context)
        #expect(next.visibleText.lowercased().contains("ready"), "got: \(next.visibleText)")
        await session.close(grace: 5)
    }

    // MARK: - Pi

    private var piRuntime: HarnessRuntime {
        let extra = (Self.env["OSAURUS_LIVE_PI_ARGS"] ?? "").split(separator: " ").map(String.init)
        return HarnessRuntime(
            name: "Pi",
            kind: .piRPC,
            executable: Self.env["OSAURUS_LIVE_PI"] ?? "pi",
            arguments: ["--mode", "rpc"] + extra
        )
    }

    @Test func piRPCProbeAndTurns() async throws {
        let probe = await HarnessRuntimeProbe.run(piRuntime)
        print("[HarnessLive] pi probe: \(probe.status) — \(probe.message)")
        #expect(probe.status != .failed, "\(probe.message)")

        let directory = try HarnessFixtures.temporaryDirectory("live-pi")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = HarnessFixtures.context(runtime: piRuntime, workingDirectory: directory)
        let session = HarnessSession(chatId: context.chatId)

        if probe.status == .needsSetup {
            // No model configured: the turn must fail typed, not hang or
            // pretend to answer.
            do {
                _ = try await run("Reply with only: ready", on: session, context: context)
                Issue.record("a Pi with no model must not complete a turn")
            } catch let error as HarnessError {
                print("[HarnessLive] pi without a model: \(error.localizedDescription)")
                guard case .notAuthenticated = error else {
                    Issue.record("expected notAuthenticated, got \(error)")
                    return
                }
            }
            #expect(await session.hasLiveProcess, "a rejected prompt must not kill the process")
        } else {
            let first = try await run("Remember the codeword HERON-7. Reply with only: OK", on: session, context: context)
            let pid = try #require(await session.processId)
            let second = try await run("What is the codeword? Reply with only the codeword.", on: session, context: context)
            #expect(first.visibleText.contains("OK"), "got: \(first.visibleText)")
            #expect(second.visibleText.contains("HERON-7"), "got: \(second.visibleText)")
            #expect(await session.processId == pid)
            print("[HarnessLive] pi turn2 tokens/s = \(tokensPerSecond(second) ?? -1)")
        }

        let pid = try #require(await session.processId)
        await session.close(grace: 5)
        #expect(!HarnessFixtures.isAlive(pid), "closing stdin must end the Pi process")
    }
}
