//
//  ShellMutationPlanner.swift
//  osaurus
//
//  Conservative pre-exec planner that names the paths a COMMON-CASE
//  `shell_run` filesystem mutation (`mv` / `cp` / `rm` / `mkdir`, simple
//  forms only) will touch. `shell_run` is normally captured by a full
//  before/after scan of the folder; this planner is the fallback when the
//  folder is too large to scan, letting the file history snapshot just the
//  named paths instead of refusing to track the call.
//
//  Design constraints:
//    - All-or-nothing per command: if ANY part can't be mapped faithfully
//      (pipes, globs, quoting, paths outside the root), the planner returns
//      nil and the call is treated as untrackable — naming the wrong paths
//      would make a revert restore the wrong files.
//    - Non-mutation commands return an empty list: nothing to snapshot.
//

import Foundation

enum ShellMutationPlanner {

    private static let mutationCommands: Set<String> = ["mv", "cp", "rm", "mkdir"]

    /// Shell metacharacters that put a command beyond faithful parsing.
    private static let shellMetaCharacters: [String] = [
        "|", "&&", "||", ";", ">", "<", "`", "$(", "\n", "&",
    ]

    /// Root-relative paths `command` will mutate: `[]` when it isn't a
    /// filesystem mutation, nil when it can't be parsed faithfully.
    static func targets(command: String, rootPath: URL) -> [String]? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard mutationCommands.contains(head) else {
            // Anything else might still write (redirects, scripts): only a
            // plain read-only command is safely "nothing".
            for meta in shellMetaCharacters where trimmed.contains(meta) { return nil }
            return readOnlyCommands.contains(head) ? [] : nil
        }
        for meta in shellMetaCharacters where trimmed.contains(meta) { return nil }
        if trimmed.contains("\"") || trimmed.contains("'") || trimmed.contains("\\") { return nil }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") { return nil }

        var tokens = trimmed.split(separator: " ").map(String.init)
        tokens.removeFirst()
        var flags: [String] = []
        var paths: [String] = []
        for token in tokens {
            if paths.isEmpty, token.hasPrefix("-") {
                flags.append(token)
            } else {
                paths.append(token)
            }
        }
        guard !paths.isEmpty else { return nil }
        var relatives: [String] = []
        for raw in paths {
            guard let rel = relativePath(raw, rootPath: rootPath) else { return nil }
            relatives.append(rel)
        }

        switch head {
        case "mv":
            guard flags.allSatisfy({ $0 == "-f" }), relatives.count == 2 else { return nil }
            return transferTargets(source: relatives[0], destination: relatives[1], rootPath: rootPath)
        case "cp":
            guard flags.allSatisfy({ ["-f", "-r", "-R", "-rf", "-fr", "-a", "-p"].contains($0) }),
                relatives.count == 2
            else { return nil }
            return transferTargets(source: relatives[0], destination: relatives[1], rootPath: rootPath)
        case "rm":
            guard flags.allSatisfy({ ["-f", "-r", "-R", "-rf", "-fr"].contains($0) }) else { return nil }
            return relatives
        case "mkdir":
            guard flags.allSatisfy({ $0 == "-p" }) else { return nil }
            return relatives
        default:
            return nil
        }
    }

    /// Programs that never write when invoked plainly. `find` (`-delete`,
    /// `-exec`), `tree` (`-o file`) and `env` (`env cmd …`) can mutate, so
    /// they are deliberately absent and get a full shadow capture.
    private static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "echo", "stat", "file",
        "du", "df", "which", "whoami", "date", "printenv",
    ]

    /// `mv a dir/` lands at `dir/basename(a)`; name both ends.
    private static func transferTargets(source: String, destination: String, rootPath: URL) -> [String] {
        var dest = destination
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: rootPath.appendingPathComponent(destination).path, isDirectory: &isDir),
            isDir.boolValue
        {
            dest = (destination as NSString).appendingPathComponent((source as NSString).lastPathComponent)
        }
        return [source, dest]
    }

    /// Resolve a (relative or absolute) token against the root and return
    /// its root-relative form, or nil when it escapes the working folder.
    private static func relativePath(_ raw: String, rootPath: URL) -> String? {
        let root = rootPath.standardized.path
        let resolved: String
        if raw.hasPrefix("/") {
            resolved = (raw as NSString).standardizingPath
        } else {
            resolved = rootPath.appendingPathComponent(raw).standardized.path
        }
        if resolved == root { return nil }
        guard resolved.hasPrefix(root + "/") else { return nil }
        return String(resolved.dropFirst(root.count + 1))
    }
}
