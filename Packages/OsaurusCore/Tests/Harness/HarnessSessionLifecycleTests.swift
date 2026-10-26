//
//  HarnessSessionLifecycleTests.swift
//  osaurusTests
//
//  Drives a real `HarnessSession` against a fake Pi RPC script: one process
//  per chat, close-on-stdin, crash and relaunch, Stop, dialogs, folder
//  changes, and the token's lifetime.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Harness session lifecycle", .serialized)
struct HarnessSessionLifecycleTests {

    private struct Fixture {
        let directory: URL
        let runtime: HarnessRuntime
        let exitMarker: URL

        init(
            environment: [String: String] = [:],
            arguments: [String] = ["--mode", "rpc"],
            script contents: String = HarnessFixtures.fakePiScript
        ) throws {
            directory = try HarnessFixtures.temporaryDirectory("harness-session")
            let script = try HarnessFixtures.writeExecutable(
                contents,
                named: "fake-pi",
                in: directory
            )
            exitMarker = directory.appendingPathComponent("exit-marker")
            var env = environment
            env["FAKE_EXIT_MARKER"] = exitMarker.path
            runtime = HarnessRuntime(
                name: "Fake Pi",
                kind: .piRPC,
                executable: script.path,
                arguments: arguments,
                environment: env
            )
        }

        func context(chatId: UUID, agentId: UUID = UUID(), folder: URL? = nil) -> HarnessLaunchContext {
            HarnessFixtures.context(runtime: runtime, chatId: chatId, agentId: agentId, workingDirectory: folder ?? directory)
        }
    }

    private static func isStats(_ event: HarnessEvent) -> Bool {
        if case .stats = event { return true }
        return false
    }

    private func send(
        _ text: String,
        on session: HarnessSession,
        context: HarnessLaunchContext
    ) async throws -> [HarnessEvent] {
        try await HarnessFixtures.collect(session.send(HarnessUserMessage(text: text), context: context))
    }

    @Test func oneProcessServesEveryTurnOfAChat() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        let context = fixture.context(chatId: chatId)

        let first = try await send("hello", on: session, context: context)
        let pid = try #require(await session.processId)
        let second = try await send("again", on: session, context: context)

        #expect(first.visibleText == "turn1 pid=\(pid)")
        #expect(second.visibleText == "turn2 pid=\(pid)")
        // `turnCompleted` ends the stream rather than being yielded.
        #expect(first.contains(.turnCompleted) == false)
        #expect(first.last.map(Self.isStats) == true)
        #expect(second.last.map(Self.isStats) == true)
        #expect(await session.processId == pid)
        await session.close(grace: 2)
    }

    @Test func separateChatsGetSeparateProcesses() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = HarnessSessionManager()
        let chatA = UUID()
        let chatB = UUID()

        let a = await manager.session(for: chatA)
        let b = await manager.session(for: chatB)
        #expect(await manager.session(for: chatA) === a)
        _ = try await send("hi", on: a, context: fixture.context(chatId: chatA))
        _ = try await send("hi", on: b, context: fixture.context(chatId: chatB))

        let pidA = try #require(await a.processId)
        let pidB = try #require(await b.processId)
        #expect(pidA != pidB)
        #expect(await manager.liveSessionCount() == 2)

        await manager.closeAll()
        #expect(await manager.liveSessionCount() == 0)
        #expect(!HarnessFixtures.isAlive(pidA))
        #expect(!HarnessFixtures.isAlive(pidB))
    }

    @Test func closingStdinIsTheShutdownSignal() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        _ = try await send("hello", on: session, context: fixture.context(chatId: chatId))
        let pid = try #require(await session.processId)

        await session.close(grace: 3)

        // The script only writes the marker on reading EOF, so its presence
        // proves the exit came from stdin closing rather than a signal.
        let marker = try String(contentsOf: fixture.exitMarker, encoding: .utf8)
        #expect(marker == "eof")
        #expect(!HarnessFixtures.isAlive(pid))
        #expect(await !session.hasLiveProcess)
    }

    @Test func aHarnessThatIgnoresEOFIsKilledAfterTheGrace() async throws {
        let fixture = try Fixture(environment: ["FAKE_IGNORE_EOF": "1"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        _ = try await send("hello", on: session, context: fixture.context(chatId: chatId))
        let pid = try #require(await session.processId)

        let started = Date()
        await session.close(grace: 0.5)
        // The child would sleep for 600s; shutdown is bounded by grace + SIGTERM wait.
        #expect(Date().timeIntervalSince(started) < 30, "the grace must bound shutdown, not the child")

        #expect(!HarnessFixtures.isAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: fixture.exitMarker.path))
    }

    @Test func aCrashFailsTheTurnAndTheNextMessageRelaunches() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        let context = fixture.context(chatId: chatId)

        _ = try await send("hello", on: session, context: context)
        let firstPid = try #require(await session.processId)

        do {
            _ = try await send("crash now", on: session, context: context)
            Issue.record("a crashed harness must fail the turn")
        } catch let error as HarnessError {
            guard case .exited(_, let code, let stderr) = error else {
                Issue.record("expected .exited, got \(error)")
                return
            }
            #expect(code == 3)
            #expect(stderr.contains("fake harness crashed"))
        }
        #expect(await !session.hasLiveProcess)

        let recovered = try await send("hello", on: session, context: context)
        let secondPid = try #require(await session.processId)
        #expect(secondPid != firstPid)
        // A fresh process: Pi without a chat-keyed session starts over.
        #expect(recovered.visibleText == "turn1 pid=\(secondPid)")
        await session.close(grace: 2)
    }

    @Test func aCrashAfterStdoutClosesRetainsItsStderr() async throws {
        let script = HarnessFixtures.fakePiScript.replacingOccurrences(
            of: "printf 'fake harness crashed\\n' >&2",
            with: "exec 1>&-\nprintf 'fake harness crashed\\n' >&2"
        )
        #expect(script != HarnessFixtures.fakePiScript)
        let fixture = try Fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        do {
            _ = try await send("crash now", on: session, context: fixture.context(chatId: chatId))
            Issue.record("a crashed harness must fail the turn")
        } catch let error as HarnessError {
            guard case .exited(_, let code, let stderr) = error else {
                Issue.record("expected .exited, got \(error)")
                return
            }
            #expect(code == 3)
            #expect(stderr.contains("fake harness crashed"))
        }
        #expect(await !session.hasLiveProcess)
        await session.close(grace: 2)
    }

    /// Drive the actual coordinator in both callback orders, without scheduler
    /// timing, sleeps, or a test-only reader hook. Yield exposes whether the
    /// real stream has already finished synchronously.
    @Test(arguments: [true, false])
    func exitWaitsForBothPipeReaders(stdoutFirst: Bool) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        defer { withExtendedLifetime(stream) {} }
        let drain = HarnessDrainGate(continuation: continuation)
        let first: HarnessDrainGate.Pipe = stdoutFirst ? .stdout : .stderr
        let last: HarnessDrainGate.Pipe = stdoutFirst ? .stderr : .stdout
        drain.markEOF(first)
        drain.markExited()
        if case .enqueued = continuation.yield(Data()) {
            // The remaining pipe can still carry the crash diagnostic.
        } else {
            Issue.record("process exit and one pipe EOF must not finish the stream")
        }
        drain.markEOF(last)
        if case .terminated = continuation.yield(Data()) {
        } else {
            Issue.record("both pipe EOFs and exit must finish the stream")
        }
    }

    @Test func drainedPipesStillWaitForExitAndDuplicateCallbacksAreHarmless() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        defer { withExtendedLifetime(stream) {} }
        let drain = HarnessDrainGate(continuation: continuation)
        drain.markEOF(.stderr)
        drain.markEOF(.stdout)
        if case .enqueued = continuation.yield(Data()) {
        } else {
            Issue.record("pipe EOF alone must not finish before the exit code is recorded")
        }
        drain.markExited()
        drain.markEOF(.stdout)
        drain.markEOF(.stderr)
        drain.markExited()
        if case .terminated = continuation.yield(Data()) {
        } else {
            Issue.record("duplicate EOF and exit callbacks must leave the stream finished")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func exitedProcessStillBoundsPipesHeldOpenByDescendants() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let drain = HarnessDrainGate(continuation: continuation)
        // Neither reader reaches EOF, as when a descendant inherited both
        // writers. Await the existing production deadline, without a sleep.
        drain.markExited()
        for await _ in stream {}
        if case .terminated = continuation.yield(Data()) {
        } else {
            Issue.record("the existing post-exit deadline must still finish held-open pipes")
        }
    }

    @Test func stopAbortsTheTurnWithoutKillingTheProcess() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        let context = fixture.context(chatId: chatId)

        let stream = try await session.send(HarnessUserMessage(text: "hang please"), context: context)
        var events: [HarnessEvent] = []
        for try await event in stream {
            events.append(event)
            if case .text = event { await session.interrupt() }
        }
        let pid = try #require(await session.processId)

        #expect(events.visibleText == "working")
        if case .stats(_, _, let stopReason) = events.last {
            #expect(stopReason == "aborted")
        } else {
            Issue.record("expected the aborted turn's stats last, got \(events)")
        }
        #expect(await !session.isBusy)

        let next = try await send("next", on: session, context: context)
        #expect(next.visibleText == "turn2 pid=\(pid)")
        await session.close(grace: 2)
    }

    @Test func aDialogRoundTripsThroughTheSession() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)

        let stream = try await session.send(
            HarnessUserMessage(text: "ask me"),
            context: fixture.context(chatId: chatId)
        )
        var events: [HarnessEvent] = []
        for try await event in stream {
            events.append(event)
            if case .dialog(let request) = event {
                #expect(request.id == "d1")
                #expect(request.title == "Proceed?")
                #expect(request.kind == .confirm(message: "Really?"))
                await session.respondToDialog(id: request.id, response: .confirmed(true))
            }
        }
        #expect(events.visibleText == "confirmed=yes")
        #expect(events.last.map(Self.isStats) == true)
        await session.close(grace: 2)
    }

    @Test func stopWhileADialogIsOpenCancelsTheDialog() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)

        let stream = try await session.send(
            HarnessUserMessage(text: "ask me"),
            context: fixture.context(chatId: chatId)
        )
        var events: [HarnessEvent] = []
        for try await event in stream {
            events.append(event)
            if case .dialog = event { await session.interrupt() }
        }
        // The cancel reply is written before the abort, so the fake answers
        // "no" and settles; the abort that follows is a no-op.
        #expect(events.visibleText == "confirmed=no")
        await session.close(grace: 2)
    }

    @Test func theLaunchContractReachesTheProcess() async throws {
        let fixture = try Fixture(arguments: ["--mode", "rpc", "--session", "{chat_id}", "--agent", "{agent_id}"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        let agentId = UUID()
        let context = fixture.context(chatId: chatId, agentId: agentId)

        let text = try await send("env", on: session, context: context).visibleText
        let chat = chatId.uuidString.lowercased()
        let agent = agentId.uuidString.lowercased()

        #expect(text.contains("chat=\(chat) "))
        #expect(text.contains("agent=\(agent) "))
        #expect(text.contains("cwd=\(fixture.directory.path) "))
        #expect(text.contains("wd=\(fixture.directory.path) "))
        #expect(text.contains("args=--mode rpc --session \(chat) --agent \(agent)"))

        let token = try #require(
            text.components(separatedBy: "token=").last?.components(separatedBy: " ").first
        )
        #expect(token.hasPrefix("osh_"))
        #expect(text.contains("grant=\(token) "))
        let grant = try #require(HarnessGrantStore.shared.resolve(token))
        #expect(grant.agentId == agentId)

        await session.close(grace: 2)
        #expect(HarnessGrantStore.shared.resolve(token) == nil, "the token must die with its process")
    }

    @Test func aFolderChangeRelaunchesInTheNewFolder() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let other = try HarnessFixtures.temporaryDirectory("harness-folder")
        defer { try? FileManager.default.removeItem(at: other) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)

        let before = try await send("env", on: session, context: fixture.context(chatId: chatId))
        let firstPid = try #require(await session.processId)
        let movedContext = fixture.context(chatId: chatId, folder: other)
        #expect(await session.needsRelaunch(for: movedContext))

        let after = try await send("env", on: session, context: movedContext)
        let secondPid = try #require(await session.processId)

        #expect(before.visibleText.contains("cwd=\(fixture.directory.path) "))
        #expect(after.visibleText.contains("cwd=\(other.path) "))
        #expect(firstPid != secondPid)
        #expect(!HarnessFixtures.isAlive(firstPid))
        #expect(await session.launchedWorkingDirectory == other.standardizedFileURL.path)
        await session.close(grace: 2)
    }

    @Test func markStaleRelaunchesEvenWithTheSameContext() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        let context = fixture.context(chatId: chatId)

        _ = try await send("hello", on: session, context: context)
        let firstPid = try #require(await session.processId)
        #expect(await !session.needsRelaunch(for: context))

        await session.markStale()
        #expect(await session.needsRelaunch(for: context))
        _ = try await send("hello", on: session, context: context)
        let secondPid = try #require(await session.processId)
        #expect(secondPid != firstPid)
        await session.close(grace: 2)
    }

    @Test func aSecondSendWhileBusyIsRefused() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)
        let context = fixture.context(chatId: chatId)

        let stream = try await session.send(HarnessUserMessage(text: "hang"), context: context)
        await #expect(throws: HarnessError.self) {
            _ = try await session.send(HarnessUserMessage(text: "again"), context: context)
        }
        await session.interrupt()
        _ = try await HarnessFixtures.collect(stream)
        await session.close(grace: 2)
    }

    @Test func missingExecutableAndFolderFailBeforeLaunch() async throws {
        let directory = try HarnessFixtures.temporaryDirectory("harness-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chatId = UUID()
        let session = HarnessSession(chatId: chatId)

        let missing = HarnessRuntime(name: "Ghost", kind: .piRPC, executable: "osaurus-no-such-harness-binary")
        await #expect(throws: HarnessError.self) {
            _ = try await session.send(
                HarnessUserMessage(text: "hi"),
                context: HarnessFixtures.context(runtime: missing, chatId: chatId, workingDirectory: directory)
            )
        }

        let script = try HarnessFixtures.writeExecutable(HarnessFixtures.fakePiScript, named: "fake-pi", in: directory)
        let runtime = HarnessRuntime(name: "Fake", kind: .piRPC, executable: script.path)
        let gone = directory.appendingPathComponent("deleted-folder", isDirectory: true)
        do {
            _ = try await session.send(
                HarnessUserMessage(text: "hi"),
                context: HarnessFixtures.context(runtime: runtime, chatId: chatId, workingDirectory: gone)
            )
            Issue.record("a missing folder must fail the launch")
        } catch let error as HarnessError {
            #expect(error == .workingFolderUnavailable(path: gone.path))
        }
        #expect(await !session.hasLiveProcess)
    }
}
