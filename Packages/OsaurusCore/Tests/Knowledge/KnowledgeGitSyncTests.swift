//
//  KnowledgeGitSyncTests.swift
//  osaurusTests
//
//  Integration coverage for KnowledgeGitSyncService against the real
//  system `git`: remote detection on an adopted folder, commit + push of
//  a curated document, fast-forward pull, and safe stop on divergence.
//  Everything runs in throwaway temp repos (a local bare "remote" plus
//  working clones) — no network, no user config touched.
//

import Foundation
import Testing

@testable import OsaurusCore

/// These integration tests run real git processes through one shared service
/// actor, so keep the cases from competing with one another.
@Suite(.serialized)
struct KnowledgeGitSyncTests {

    // MARK: - Git harness

    private static let gitPath = "/usr/bin/git"

    private static var gitAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: gitPath)
    }

    /// Run raw git for test setup (distinct from the service under test).
    @discardableResult
    private func git(_ args: [String], cwd: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.gitPath)
            process.arguments = args
            process.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            env["GIT_AUTHOR_NAME"] = "Test"
            env["GIT_AUTHOR_EMAIL"] = "test@example.com"
            env["GIT_COMMITTER_NAME"] = "Test"
            env["GIT_COMMITTER_EMAIL"] = "test@example.com"
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            process.terminationHandler = { terminatedProcess in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                guard terminatedProcess.terminationStatus == 0 else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "git",
                            code: Int(terminatedProcess.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "git \(args.joined(separator: " ")): \(text)"
                            ]
                        )
                    )
                    return
                }
                continuation.resume(returning: text)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func configureIdentity(_ repo: URL) async throws {
        try await git(["config", "user.name", "Test"], cwd: repo)
        try await git(["config", "user.email", "test@example.com"], cwd: repo)
    }

    /// Create a bare "remote" plus a working clone with one initial commit
    /// pushed. Returns (remote, workingClone).
    private func makeRemoteAndClone() async throws -> (remote: URL, work: URL) {
        let root = try tempDir()
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try await git(["init", "--bare", "--initial-branch=main", remote.path], cwd: root)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try await git(["clone", remote.path, work.path], cwd: root)
        try await configureIdentity(work)
        try "seed\n".write(
            to: work.appendingPathComponent("index.md"), atomically: true, encoding: .utf8
        )
        try await git(["add", "-A"], cwd: work)
        try await git(["commit", "-m", "seed"], cwd: work)
        try await git(["push", "origin", "main"], cwd: work)
        return (remote, work)
    }

    private func collection(at folder: URL) -> KnowledgeCollection {
        KnowledgeCollection(name: "T", folderPath: folder.path)
    }

    // MARK: - Remote detection (the wired-in remoteURL(of:))

    @Test
    func detectsOriginOfAdoptedRepo() async throws {
        guard Self.gitAvailable else { return }
        let (remote, work) = try await makeRemoteAndClone()

        let detected = await KnowledgeGitSyncService.shared.remoteURL(of: work)
        #expect(detected == remote.path)
    }

    @Test
    func remoteURLIsNilForRepoWithoutRemote() async throws {
        guard Self.gitAvailable else { return }
        let repo = try tempDir()
        try await git(
            ["init", "--initial-branch=main", repo.path],
            cwd: repo.deletingLastPathComponent()
        )

        let detected = await KnowledgeGitSyncService.shared.remoteURL(of: repo)
        #expect(detected == nil)
    }

    // MARK: - Commit + push

    @Test
    func commitDocumentThenPushAdvancesRemote() async throws {
        guard Self.gitAvailable else { return }
        let (remote, work) = try await makeRemoteAndClone()
        let coll = collection(at: work)

        try "updated body\n".write(
            to: work.appendingPathComponent("index.md"), atomically: true, encoding: .utf8
        )
        let commit = await KnowledgeGitSyncService.shared.commitDocument(
            in: coll, relPath: "index.md", message: "update index.md via knowledge curation"
        )
        #expect(commit == .updated("Committed index.md."))

        let push = await KnowledgeGitSyncService.shared.push(coll)
        if case .updated = push {} else { Issue.record("expected push .updated, got \(push)") }

        // The bare remote now carries the new commit's file content.
        let show = try await git(["show", "HEAD:index.md"], cwd: remote)
        #expect(show.contains("updated body"))
    }

    @Test
    func commitWithNoChangesIsUpToDate() async throws {
        guard Self.gitAvailable else { return }
        let (_, work) = try await makeRemoteAndClone()
        let coll = collection(at: work)

        // Rewrite identical bytes: git finds nothing to commit.
        try "seed\n".write(
            to: work.appendingPathComponent("index.md"), atomically: true, encoding: .utf8
        )
        let commit = await KnowledgeGitSyncService.shared.commitDocument(
            in: coll, relPath: "index.md", message: "noop"
        )
        #expect(commit == .upToDate)
    }

    // MARK: - Pull

    @Test
    func pullFastForwardsFromRemote() async throws {
        guard Self.gitAvailable else { return }
        let (remote, work) = try await makeRemoteAndClone()

        // A second clone pushes a new commit to the remote.
        let root = remote.deletingLastPathComponent()
        let other = root.appendingPathComponent("other", isDirectory: true)
        try await git(["clone", remote.path, other.path], cwd: root)
        try await configureIdentity(other)
        try "from other\n".write(
            to: other.appendingPathComponent("note.md"), atomically: true, encoding: .utf8
        )
        try await git(["add", "-A"], cwd: other)
        try await git(["commit", "-m", "add note"], cwd: other)
        try await git(["push", "origin", "main"], cwd: other)

        let coll = collection(at: work)
        let pulled = await KnowledgeGitSyncService.shared.pull(coll)
        #expect(pulled == .updated("Pulled new changes."))
        #expect(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("note.md").path)
        )

        // Second pull has nothing new.
        let again = await KnowledgeGitSyncService.shared.pull(coll)
        #expect(again == .upToDate)
    }

    // MARK: - Divergence stops safely

    @Test
    func divergentHistoryNeedsAttention() async throws {
        guard Self.gitAvailable else { return }
        let (remote, work) = try await makeRemoteAndClone()

        // Remote gains a commit via a second clone...
        let root = remote.deletingLastPathComponent()
        let other = root.appendingPathComponent("other", isDirectory: true)
        try await git(["clone", remote.path, other.path], cwd: root)
        try await configureIdentity(other)
        try "remote side\n".write(
            to: other.appendingPathComponent("r.md"), atomically: true, encoding: .utf8
        )
        try await git(["add", "-A"], cwd: other)
        try await git(["commit", "-m", "remote commit"], cwd: other)
        try await git(["push", "origin", "main"], cwd: other)

        // ...while the working clone makes its own conflicting local commit.
        try "local side\n".write(
            to: work.appendingPathComponent("l.md"), atomically: true, encoding: .utf8
        )
        try await git(["add", "-A"], cwd: work)
        try await git(["commit", "-m", "local commit"], cwd: work)

        let coll = collection(at: work)
        let outcome = await KnowledgeGitSyncService.shared.sync(coll)
        guard case .needsAttention = outcome else {
            Issue.record("expected .needsAttention on divergence, got \(outcome)")
            return
        }
    }
}
