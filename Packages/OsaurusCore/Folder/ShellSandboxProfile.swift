//
//  ShellSandboxProfile.swift
//  osaurus
//
//  macOS Seatbelt (`sandbox-exec`) confinement for host shell tools.
//  `shell_run` / `git_commit` subprocesses get an allow-everything profile
//  EXCEPT filesystem writes, which are limited to the user-selected folder,
//  temp directories, and a few device nodes. Reads and network stay open so
//  builds, tests, and toolchains keep working; the deny is kernel-enforced
//  and inherited by every child process, so `bash -c`, absolute paths, and
//  symlinks pointing outside the root are all blocked (Seatbelt evaluates
//  real paths). A blocked write fails with EPERM, which surfaces in the
//  streamed stderr so the model can see why and adapt.
//
//  `sandbox-exec` is deprecated-but-stable API (used by Bazel, Codex CLI,
//  Claude Code). Everything lives in this one helper so a future
//  Sandbox.framework swap is localized.
//

import Foundation

enum ShellSandboxProfile {
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    enum ConfinementError: Error, LocalizedError {
        case sandboxExecMissing

        var errorDescription: String? {
            "sandbox-exec is not available at \(ShellSandboxProfile.sandboxExecPath); "
                + "refusing to run the command unconfined."
        }
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExecPath)
    }

    /// Seatbelt profile string: allow everything, deny `file-write*` outside
    /// the writable root + temp dirs + tty/null device nodes.
    static func profile(writableRootRealPath: String) -> String {
        var writableSubpaths = [writableRootRealPath]
        let tmpdir = realPath(of: NSTemporaryDirectory())
        if !tmpdir.isEmpty { writableSubpaths.append(tmpdir) }
        writableSubpaths.append("/private/tmp")
        writableSubpaths.append("/private/var/tmp")
        let subpathClauses = writableSubpaths
            .map { "(subpath \"\(escape($0))\")" }
            .joined(separator: " ")
        return """
            (version 1)
            (allow default)
            (deny file-write*)
            (allow file-write* \(subpathClauses))
            (allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))
            (allow file-write* (regex #"^/dev/tty"))
            """
    }

    /// Resolve symlinks the way Seatbelt does before matching (`/tmp` must
    /// become `/private/tmp` or the subpath rule never fires). POSIX
    /// `realpath` on purpose: `URL.resolvingSymlinksInPath()` special-cases
    /// `/tmp` and `/var` and leaves them unresolved.
    static func realPath(of path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buffer) else { return path }
        return String(cString: resolved)
    }

    /// Escape a path for embedding in a Seatbelt (Scheme) string literal.
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The confined form of `executable args...`: run through
    /// `sandbox-exec -p <profile>` with writes limited to `writableRoot`.
    /// Fails closed when `sandbox-exec` is unavailable — callers surface a
    /// tool error rather than silently running unconfined.
    static func wrappedInvocation(
        executable: String,
        arguments: [String],
        writableRoot: URL
    ) throws -> (executableURL: URL, arguments: [String]) {
        guard isAvailable else { throw ConfinementError.sandboxExecMissing }
        let profile = profile(writableRootRealPath: realPath(of: writableRoot.path))
        return (
            URL(fileURLWithPath: sandboxExecPath),
            ["-p", profile, executable] + arguments
        )
    }
}
