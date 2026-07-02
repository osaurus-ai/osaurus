//
//  KnowledgeGitSyncService.swift
//  osaurus
//
//  Git sync for knowledge collections, via the system `git` binary.
//  Design constraints:
//    - Fail safe, never clever: pulls are `--ff-only`; a divergent
//      remote surfaces as "needs attention" instead of an auto-merge
//      that could mangle the user's corpus.
//    - No credential management: git runs with the user's own config
//      and credential helpers (osxkeychain, SSH agent).
//      GIT_TERMINAL_PROMPT=0 and SSH BatchMode make missing credentials
//      fail fast instead of hanging on an invisible prompt.
//    - Indexes are derived artifacts and never committed, so sync can
//      never conflict on them.
//  All process work runs on this actor, off the main thread.
//

import Foundation

public enum KnowledgeSyncOutcome: Sendable, Equatable {
    case upToDate
    case updated(String)
    /// Sync stopped safely and the user must act (diverged branches,
    /// merge conflict, missing credentials).
    case needsAttention(String)
    case failed(String)

    public var message: String {
        switch self {
        case .upToDate: return "Already up to date."
        case .updated(let detail): return detail
        case .needsAttention(let detail): return detail
        case .failed(let detail): return detail
        }
    }
}

public actor KnowledgeGitSyncService {
    public static let shared = KnowledgeGitSyncService()

    private static let gitPath = "/usr/bin/git"
    private static let cloneTimeout: TimeInterval = 300
    private static let networkTimeout: TimeInterval = 120
    private static let localTimeout: TimeInterval = 30

    private init() {}

    // MARK: - Public operations

    /// Clone `remoteURL` into the managed content directory for a new
    /// collection. Throws with git's stderr on failure.
    public func clone(remoteURL: String, collectionId: UUID) throws -> URL {
        let target = OsaurusPaths.knowledgeManagedContentDirectory(for: collectionId)
        OsaurusPaths.ensureExistsSilent(target.deletingLastPathComponent())
        // A retried add-from-URL may leave a partial clone behind.
        try? FileManager.default.removeItem(at: target)
        let result = runGit(
            ["clone", "--single-branch", remoteURL, target.path],
            cwd: target.deletingLastPathComponent(),
            timeout: Self.cloneTimeout
        )
        guard result.succeeded else {
            throw KnowledgeCurationError.writeFailed(Self.failureDetail(result))
        }
        return target
    }

    /// Pull the collection's repo, fast-forward only. Divergence is
    /// reported, never merged.
    public func pull(_ collection: KnowledgeCollection) -> KnowledgeSyncOutcome {
        let folder = collection.folderURL
        guard collection.isGitRepository else {
            return .failed("Not a git repository: \(folder.path)")
        }
        let before = headCommit(in: folder)
        let result = runGit(
            ["pull", "--ff-only"],
            cwd: folder,
            timeout: Self.networkTimeout
        )
        guard result.succeeded else {
            let detail = Self.failureDetail(result)
            if detail.localizedCaseInsensitiveContains("divergent")
                || detail.localizedCaseInsensitiveContains("not possible to fast-forward")
            {
                return .needsAttention(
                    "Local and remote history diverged. Resolve in the folder with your git tools; Osaurus will not merge for you."
                )
            }
            if detail.localizedCaseInsensitiveContains("authentication")
                || detail.localizedCaseInsensitiveContains("could not read")
                || detail.localizedCaseInsensitiveContains("permission denied")
            {
                return .needsAttention(
                    "Git could not authenticate. Sign in with your usual git tooling (credential helper or SSH agent), then sync again."
                )
            }
            return .failed(detail)
        }
        let after = headCommit(in: folder)
        return before == after ? .upToDate : .updated("Pulled new changes.")
    }

    /// Push local commits. No-op success when there is no remote.
    public func push(_ collection: KnowledgeCollection) -> KnowledgeSyncOutcome {
        let folder = collection.folderURL
        guard collection.isGitRepository else {
            return .failed("Not a git repository: \(folder.path)")
        }
        guard hasRemote(in: folder) else { return .upToDate }
        let result = runGit(["push"], cwd: folder, timeout: Self.networkTimeout)
        guard result.succeeded else {
            let detail = Self.failureDetail(result)
            if detail.localizedCaseInsensitiveContains("rejected")
                || detail.localizedCaseInsensitiveContains("fetch first")
            {
                return .needsAttention(
                    "Push rejected: the remote has changes you don't have. Sync (pull) first, then push again."
                )
            }
            return .failed(detail)
        }
        return .updated("Pushed local changes.")
    }

    /// Pull then push. The standard "Sync now" gesture.
    public func sync(_ collection: KnowledgeCollection) -> KnowledgeSyncOutcome {
        let pullOutcome = pull(collection)
        switch pullOutcome {
        case .needsAttention, .failed:
            return pullOutcome
        case .upToDate, .updated:
            let pushOutcome = push(collection)
            switch (pullOutcome, pushOutcome) {
            case (.upToDate, .upToDate):
                return .upToDate
            case (_, .needsAttention), (_, .failed):
                return pushOutcome
            case (.updated, _):
                return .updated("Synced: pulled and pushed.")
            default:
                return pushOutcome
            }
        }
    }

    /// Stage and commit one document inside the collection repo. Used by
    /// curation approval; a failure here must not fail the approval (the
    /// file write already succeeded), so it returns an outcome instead
    /// of throwing.
    public func commitDocument(
        in collection: KnowledgeCollection,
        relPath: String,
        message: String
    ) -> KnowledgeSyncOutcome {
        let folder = collection.folderURL
        guard collection.isGitRepository else {
            return .failed("Not a git repository: \(folder.path)")
        }
        let add = runGit(["add", "--", relPath], cwd: folder, timeout: Self.localTimeout)
        guard add.succeeded else { return .failed(Self.failureDetail(add)) }
        let commit = runGit(
            ["commit", "-m", message, "--", relPath],
            cwd: folder,
            timeout: Self.localTimeout
        )
        guard commit.succeeded else {
            // "nothing to commit" (approval wrote identical bytes) is fine.
            let detail = Self.failureDetail(commit)
            if detail.localizedCaseInsensitiveContains("nothing to commit") {
                return .upToDate
            }
            return .failed(detail)
        }
        return .updated("Committed \(relPath).")
    }

    /// `origin` URL of a repo, for detecting remotes on user folders.
    public func remoteURL(of folderURL: URL) -> String? {
        let result = runGit(
            ["remote", "get-url", "origin"],
            cwd: folderURL,
            timeout: Self.localTimeout
        )
        guard result.succeeded else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    // MARK: - Repo probes

    private func headCommit(in folder: URL) -> String? {
        let result = runGit(["rev-parse", "HEAD"], cwd: folder, timeout: Self.localTimeout)
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasRemote(in folder: URL) -> Bool {
        let result = runGit(["remote"], cwd: folder, timeout: Self.localTimeout)
        return result.succeeded
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Process plumbing

    private struct GitResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var succeeded: Bool { exitCode == 0 && !timedOut }
    }

    private static func failureDetail(_ result: GitResult) -> String {
        if result.timedOut { return "git timed out." }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "git exited with status \(result.exitCode)." : stdout
    }

    private func runGit(_ arguments: [String], cwd: URL, timeout: TimeInterval) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = cwd

        var environment = ProcessInfo.processInfo.environment
        // Never hang on an invisible credential/host prompt: fail fast
        // and surface the error in the UI instead.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return GitResult(
                exitCode: -1,
                stdout: "",
                stderr: "Could not run git: \(error.localizedDescription)",
                timedOut: false
            )
        }

        // Watchdog: terminate a wedged process at the deadline. Reads
        // happen on the pipes after exit; git's output volumes here are
        // small (no --progress), so pipe back-pressure is not a concern.
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            group.wait()
        }

        let stdout =
            String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        let stderr =
            String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

        KnowledgeLogger.index.info(
            "git \(arguments.first ?? "?", privacy: .public) exited \(process.terminationStatus) in \(cwd.lastPathComponent, privacy: .public)"
        )
        return GitResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
