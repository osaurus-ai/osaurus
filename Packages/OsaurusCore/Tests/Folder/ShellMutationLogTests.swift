//
//  ShellMutationLogTests.swift
//
//  Pins the conservative `shell_run` undo planner: simple `mv`/`cp`/
//  `rm`/`mkdir` forms are captured into loggable operations; anything
//  the parser can't represent faithfully (compound commands, globs,
//  quoting, directories, escapes from the root) is `.unloggable` so the
//  tool result warns instead of leaving a silent undo gap; non-mutation
//  commands are `.none`.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ShellMutationLogTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func nonMutationCommandsAreNone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in ["swift test", "git status", "ls -la", "echo mv a b"] {
            guard case .none = ShellMutationLog.plan(command: command, rootPath: root) else {
                Issue.record("expected .none for `\(command)`")
                return
            }
        }
    }

    @Test func simpleMoveIsCaptured() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        guard case .mutations(let ops) = ShellMutationLog.plan(command: "mv a.txt b.txt", rootPath: root)
        else {
            Issue.record("expected .mutations")
            return
        }
        #expect(ops.count == 1)
        #expect(ops[0].type == .move)
        #expect(ops[0].path == "a.txt")
        #expect(ops[0].destinationPath == "b.txt")
    }

    @Test func moveIntoExistingDirectoryResolvesLandingPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )

        guard case .mutations(let ops) = ShellMutationLog.plan(command: "mv a.txt sub", rootPath: root)
        else {
            Issue.record("expected .mutations")
            return
        }
        #expect(ops[0].destinationPath == "sub/a.txt")
    }

    @Test func removeCapturesPreviousContent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "important data".write(
            to: root.appendingPathComponent("keep.txt"),
            atomically: true,
            encoding: .utf8
        )

        guard case .mutations(let ops) = ShellMutationLog.plan(command: "rm keep.txt", rootPath: root)
        else {
            Issue.record("expected .mutations")
            return
        }
        #expect(ops[0].type == .delete)
        #expect(ops[0].previousContent == "important data")
    }

    @Test func recursiveRemoveIsUnloggable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .unloggable = ShellMutationLog.plan(command: "rm -rf build", rootPath: root) else {
            Issue.record("expected .unloggable for rm -rf")
            return
        }
    }

    @Test func compoundGlobAndQuotedFormsAreUnloggable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in [
            "rm a.txt && rm b.txt",
            "rm *.txt",
            "mv 'a file.txt' b.txt",
            "mkdir x; mkdir y",
            "rm a.txt > /dev/null",
        ] {
            guard case .unloggable = ShellMutationLog.plan(command: command, rootPath: root) else {
                Issue.record("expected .unloggable for `\(command)`")
                return
            }
        }
    }

    @Test func pathEscapingRootIsUnloggable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .unloggable = ShellMutationLog.plan(command: "rm ../outside.txt", rootPath: root)
        else {
            Issue.record("expected .unloggable for escape path")
            return
        }
    }

    @Test func mkdirIsCaptured() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .mutations(let ops) = ShellMutationLog.plan(command: "mkdir -p a/b", rootPath: root)
        else {
            Issue.record("expected .mutations")
            return
        }
        #expect(ops[0].type == .dirCreate)
        #expect(ops[0].path == "a/b")
    }
}

// MARK: - Exec invalidates fresh reads

struct AgentTaskStateExecInvalidationTests {

    private func fileEnvelope(path: String) -> String {
        ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "path": path, "content": "data"] as [String: Any]
        )
    }

    @Test func shellRunWipesAllFreshReads() {
        let state = AgentTaskState()
        let env = fileEnvelope(path: "a.txt")
        state.record(name: "file_read", argsJSON: #"{"path":"a.txt"}"#, result: env)
        #expect(state.heldResult(name: "file_read", argsJSON: #"{"path":"a.txt"}"#) == env)

        // Any shell_run — even a failing one — may have mutated paths the
        // parser can't see, so the replay cache must be wiped.
        state.record(
            name: "shell_run",
            argsJSON: #"{"command":"rm a.txt"}"#,
            result: ToolEnvelope.success(tool: "shell_run", text: "ok")
        )
        #expect(state.heldResult(name: "file_read", argsJSON: #"{"path":"a.txt"}"#) == nil)
    }

    @Test func sandboxReadIsReplayEligibleAndExecInvalidates() {
        let state = AgentTaskState()
        #expect(AgentTaskState.isReplayEligible(name: "sandbox_read_file"))
        #expect(AgentTaskState.isReplayEligible(name: "sandbox_search_files"))

        let env = ToolEnvelope.success(
            tool: "sandbox_read_file",
            result: ["kind": "file", "path": "notes.md", "content": "hello"] as [String: Any]
        )
        state.record(name: "sandbox_read_file", argsJSON: #"{"path":"notes.md"}"#, result: env)
        #expect(state.heldResult(name: "sandbox_read_file", argsJSON: #"{"path":"notes.md"}"#) == env)

        state.record(
            name: "sandbox_exec",
            argsJSON: #"{"command":"mv notes.md old.md"}"#,
            result: ToolEnvelope.success(tool: "sandbox_exec", text: "ok")
        )
        #expect(state.heldResult(name: "sandbox_read_file", argsJSON: #"{"path":"notes.md"}"#) == nil)
    }

    @Test func anyWriteInvalidatesSearchResults() {
        let state = AgentTaskState()
        let env = ToolEnvelope.success(
            tool: "file_search",
            result: ["matches": "a.txt:1: hit"] as [String: Any]
        )
        // Search without a `path` argument still dedupes (sentinel key)…
        state.record(name: "file_search", argsJSON: #"{"pattern":"hit"}"#, result: env)
        #expect(state.heldResult(name: "file_search", argsJSON: #"{"pattern":"hit"}"#) == env)

        // …and a write to ANY path invalidates it (search spans the tree).
        state.record(
            name: "file_write",
            argsJSON: #"{"path":"unrelated.txt","content":"x"}"#,
            result: ToolEnvelope.success(tool: "file_write", text: "ok")
        )
        #expect(state.heldResult(name: "file_search", argsJSON: #"{"pattern":"hit"}"#) == nil)
    }
}
