//
//  ExecutableLocator.swift
//  osaurus
//
//  Shared PATH resolution for child processes Osaurus spawns on the host.
//
//  Promoted verbatim from `MCPStdioHostRunner`, which needed it first for
//  stdio MCP servers (`npx`, `uvx`, `python`) and is now one of two callers —
//  `ClaudeCodeConfiguration` uses the same lookup to find the `claude` binary.
//  The rules below were learned from real MCP support reports; keep them here
//  rather than re-deriving them per call site.
//

import Foundation

/// Locates executables the way a login shell would, for child processes
/// spawned out of a GUI app.
public enum ExecutableLocator {
    /// Resolve `command` to an absolute path the kernel can exec.
    ///
    /// Absolute / relative paths are trusted as-is; bare names are resolved by
    /// walking `PATH` ourselves. Going through `/usr/bin/env` instead would
    /// hide ENOENT inside the env exec (env itself spawns fine, then exits
    /// non-zero), which is why nvm / asdf users never used to see a useful
    /// error.
    ///
    /// - Returns: the absolute path, or `nil` when a bare name isn't on `PATH`.
    ///   Callers map `nil` onto their own typed "not found" error so each
    ///   surface keeps its own user-facing copy.
    public static func resolve(command: String, env: [String: String]) -> String? {
        let expanded = expandUserPath(command)
        if expanded.contains("/") {
            return expanded
        }
        return resolveOnPath(expanded, path: searchPath(env: env))
    }

    /// GUI-launched macOS apps often inherit a sparse PATH that misses
    /// Homebrew, MacPorts, or user-local bins. Keep the user's PATH order
    /// first, then append safe local command directories so common launchers
    /// (`npx`, `uvx`, `python`, `claude`) are discoverable without forcing
    /// users to paste absolute paths.
    public static func searchPath(
        env: [String: String],
        loginShellEntries: [String]? = LoginShellPath.cachedEntries
    ) -> String {
        var entries =
            (env["PATH"]?.isEmpty == false ? env["PATH"] : nil)?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            ?? []
        // The login shell's PATH (mise / nvm / asdf / fnm / direnv add their bins only there, #3024).
        for entry in loginShellEntries ?? [] where !entries.contains(entry) {
            entries.append(entry)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for fallback in [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            // Version-manager shims, for when the login-shell probe is unavailable.
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] where !entries.contains(fallback) {
            entries.append(fallback)
        }
        return entries.joined(separator: ":")
    }

    /// PATH for a host child process the user did not give an explicit PATH: the login shell's entries first
    /// (the user's own order), then the inherited ones, then the fallbacks.
    public static func childPath(inherited: [String: String], loginShellEntries: [String]?) -> String {
        var env = inherited
        env["PATH"] = ((loginShellEntries ?? []) + (inherited["PATH"]?.split(separator: ":").map(String.init) ?? []))
            .joined(separator: ":")
        var seen = Set<String>()
        return searchPath(env: env, loginShellEntries: nil)
            .split(separator: ":").map(String.init).filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// For `#!/usr/bin/env <interpreter>` scripts: the script's own directory when the interpreter sits beside
    /// it (mise / nvm / asdf install `npx` next to `node`), so a full-path command runs with the toolchain the
    /// user picked. `nil` for binaries, other shebangs, or when the interpreter is not alongside.
    public static func envShebangSiblingDirectory(executable: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: executable) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256),
            let text = String(data: head, encoding: .utf8),
            text.hasPrefix("#!"), let firstLine = text.split(separator: "\n").first
        else { return nil }
        let words = firstLine.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let launcher = words.first, (launcher as NSString).lastPathComponent == "env" else { return nil }
        guard let interpreter = words.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.contains("=") })
        else { return nil }
        let directory = ((executable as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent
        let unresolvedDirectory = (executable as NSString).deletingLastPathComponent
        for dir in [unresolvedDirectory, directory]
        where FileManager.default.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(interpreter)) {
            return dir
        }
        return nil
    }

    /// Expand a leading `~` against the current user's home directory.
    /// `Process` does not do this for us — it execs the literal path.
    public static func expandUserPath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        return home + String(path.dropFirst())
    }

    /// Walk the colon-separated `path` looking for an executable named
    /// `command`. Returns the first hit's absolute path, or nil. Mirrors
    /// `/usr/bin/env`'s lookup just enough to give us a useful error before
    /// we hand off to `Process.run()`.
    public static func resolveOnPath(_ command: String, path: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(dir)/\(command)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
