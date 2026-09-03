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
    public static func searchPath(env: [String: String]) -> String {
        var entries =
            (env["PATH"]?.isEmpty == false ? env["PATH"] : nil)?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for fallback in [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] where !entries.contains(fallback) {
            entries.append(fallback)
        }
        return entries.joined(separator: ":")
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
