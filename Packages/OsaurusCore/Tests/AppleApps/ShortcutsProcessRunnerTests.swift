//
//  ShortcutsProcessRunnerTests.swift
//  OsaurusCoreTests — AppleApps
//
//  The `shortcuts` CLI wrapper's process contract, exercised with `/bin/sh`
//  so no shortcut is needed: a chatty child no longer deadlocks on a full
//  pipe, output is capped, the timeout kills the child, cancelling the task
//  terminates it, and a failed launch reports `unavailable` (the old path
//  released a never-resumed DispatchSource and trapped).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Apple tools: Shortcuts process runner", .serialized)
struct ShortcutsProcessRunnerTests {
    private func sh(_ script: String, timeout: TimeInterval = 20, cap: Int = ShortcutsProcessRunner.outputCap) async throws -> ShortcutsProcessOutput {
        try await ShortcutsProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], timeout: timeout, outputCap: cap)
    }

    @Test("a child that prints far more than the pipe buffer finishes instead of hanging")
    func largeOutputDoesNotDeadlock() async throws {
        let started = Date()
        // ~5 MiB on stdout and ~1 MiB on stderr, well past the 64 KiB pipe buffer.
        let result = try await sh("head -c 5242880 /dev/zero | tr '\\0' 'x'; head -c 1048576 /dev/zero | tr '\\0' 'e' 1>&2; exit 0")
        #expect(result.exitCode == 0)
        #expect(result.truncated)
        #expect(result.stdout.utf8.count == ShortcutsProcessRunner.outputCap)
        // A real deadlock surfaces as the 20 s runner timeout above; this only
        // guards against a silent multi-minute stall on a loaded CI box.
        #expect(Date().timeIntervalSince(started) < 60)
    }

    @Test("small output is returned whole, from both streams, with the exit code")
    func smallOutput() async throws {
        let result = try await sh("printf 'hello'; printf 'warn' 1>&2; exit 3")
        #expect(result.exitCode == 3)
        #expect(result.stdout == "hello")
        #expect(result.stderr == "warn")
        #expect(!result.truncated)
    }

    @Test("the timeout terminates the child and surfaces a typed timeout")
    func timeoutTerminates() async throws {
        let started = Date()
        do {
            _ = try await sh("sleep 30", timeout: 0.5)
            Issue.record("expected a timeout")
        } catch let error as AppleToolError {
            guard case .timeout = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
        // The child is asked to sleep 30 s; anything well under that proves the kill.
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("cancelling the task terminates the child promptly")
    func cancellationTerminates() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-shortcuts-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ShortcutsProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30; touch '\(marker.path)'"], timeout: 60)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError, "got \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 15)
        // The child died before its `touch` — it did not keep running.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a launch failure is a retryable `unavailable`, not a crash")
    func launchFailure() async throws {
        do {
            _ = try await ShortcutsProcessRunner.run(
                executable: "/nonexistent/definitely-missing-binary", arguments: [], timeout: 5)
            Issue.record("expected a launch failure")
        } catch let error as AppleToolError {
            guard case .unavailable(_, let retryable) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(retryable)
        }
    }

    @Test("`shortcuts list --show-identifiers` lines parse into name + identifier; resolution accepts either")
    func listParsingAndResolve() {
        let a = ShortcutsCLIService.parseListLine("Morning Brief (0F0F0F0F-0000-4000-8000-000000000001)")
        #expect(a == ShortcutInfo(name: "Morning Brief", identifier: "0F0F0F0F-0000-4000-8000-000000000001", folder: nil))
        let b = ShortcutsCLIService.parseListLine("Log (Water) (0F0F0F0F-0000-4000-8000-000000000002)")
        #expect(b?.name == "Log (Water)")
        #expect(ShortcutsCLIService.parseListLine("  ") == nil)
        #expect(ShortcutsCLIService.parseListLine("Plain Name") == ShortcutInfo(name: "Plain Name", identifier: nil, folder: nil))

        let all = [a!, b!]
        #expect(ShortcutsCLIService.resolve("morning brief", in: all)?.identifier == a?.identifier)
        #expect(ShortcutsCLIService.resolve("0F0F0F0F-0000-4000-8000-000000000002", in: all)?.name == "Log (Water)")
        #expect(ShortcutsCLIService.resolve("Nope", in: all) == nil)
    }

    @Test("the CLI's not-found stderr (curly apostrophe, either casing) is recognised; other failures are not")
    func notFoundStderr() {
        #expect(ShortcutsCLIService.isNotFoundStderr("Error: Couldn\u{2019}t find shortcut \u{2018}Nope\u{2019}"))
        #expect(ShortcutsCLIService.isNotFoundStderr("couldn't find the shortcut named Nope"))
        #expect(ShortcutsCLIService.isNotFoundStderr("No shortcut named 'Nope' exists"))
        #expect(!ShortcutsCLIService.isNotFoundStderr("The operation couldn\u{2019}t be completed. Shortcut failed."))
        #expect(!ShortcutsCLIService.isNotFoundStderr(""))
    }
}
