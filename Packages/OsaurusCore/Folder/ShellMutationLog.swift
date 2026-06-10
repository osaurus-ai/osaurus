//
//  ShellMutationLog.swift
//  osaurus
//
//  Conservative pre-exec planner that turns COMMON-CASE `shell_run`
//  filesystem mutations (`mv` / `cp` / `rm` / `mkdir`, simple forms only)
//  into `FileOperation` records so they join the same undo log as
//  `file_write` / `file_edit`.
//
//  Design constraints:
//    - Planning happens BEFORE the command runs: `rm` undo needs the
//      file's previous content, which only exists pre-exec.
//    - All-or-nothing per command: if ANY part of a mutation command
//      can't be captured faithfully (pipes, globs, quoting, directories,
//      non-UTF-8 content, paths outside the root), the whole command is
//      classified `.unloggable` and the tool result warns that the undo
//      log does not cover it. A half-logged command would make
//      `file_undo` silently restore a subset — worse than honesty.
//    - Non-mutation commands (builds, tests, git, …) classify `.none`
//      and pay only a token-split for the first-word check.
//

import Foundation

enum ShellMutationLog {

    /// One planned, fully-captured operation, ready to log on exit 0.
    struct PlannedOperation {
        let type: FileOperationType
        /// Relative to the working-folder root.
        let path: String
        let destinationPath: String?
        /// Pre-exec file body (for `rm` restore).
        let previousContent: String?
    }

    enum Plan {
        /// Not a filesystem-mutation command — nothing to log.
        case none
        /// Fully captured; log these if the command exits 0.
        case mutations([PlannedOperation])
        /// Looks like a mutation (`mv`/`cp`/`rm`/`mkdir` lead) but can't
        /// be captured faithfully — surface the "not undoable" warning.
        case unloggable
    }

    private static let mutationCommands: Set<String> = ["mv", "cp", "rm", "mkdir"]

    /// Shell metacharacters that put a command beyond faithful parsing.
    private static let shellMetaCharacters: [String] = [
        "|", "&&", "||", ";", ">", "<", "`", "$(", "\n", "&",
    ]

    /// Plan undo logging for `command`. Must be called BEFORE execution
    /// (captures `rm` targets' contents and resolves `mv`/`cp`
    /// into-directory destinations against the pre-exec filesystem).
    static func plan(command: String, rootPath: URL) -> Plan {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard mutationCommands.contains(head) else { return .none }

        // Compound/redirected/expanded commands are beyond the parser.
        for meta in shellMetaCharacters where trimmed.contains(meta) {
            return .unloggable
        }
        // Quoting and globs are deliberately unsupported: tokenising them
        // wrongly would log the WRONG path, which is worse than skipping.
        if trimmed.contains("\"") || trimmed.contains("'") || trimmed.contains("\\") {
            return .unloggable
        }
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains("[") {
            return .unloggable
        }

        var tokens = trimmed.split(separator: " ").map(String.init)
        tokens.removeFirst()  // the command word

        // Split off leading flags; anything after the first non-flag token
        // is treated as a path argument (mv/cp/rm/mkdir take no
        // interleaved value flags in their simple forms).
        var flags: [String] = []
        var paths: [String] = []
        for token in tokens {
            if paths.isEmpty, token.hasPrefix("-") {
                flags.append(token)
            } else {
                paths.append(token)
            }
        }
        guard !paths.isEmpty else { return .unloggable }

        switch head {
        case "mv":
            guard flags.allSatisfy({ $0 == "-f" }), paths.count == 2 else { return .unloggable }
            return planTransfer(.move, source: paths[0], destination: paths[1], rootPath: rootPath)
        case "cp":
            guard flags.allSatisfy({ ["-f", "-r", "-R", "-rf", "-fr", "-a", "-p"].contains($0) }),
                paths.count == 2
            else { return .unloggable }
            return planTransfer(.copy, source: paths[0], destination: paths[1], rootPath: rootPath)
        case "rm":
            // `-r`/`-rf` deletes directories — their contents can't be
            // captured as a single restorable body, so they stay unlogged.
            guard flags.allSatisfy({ $0 == "-f" }) else { return .unloggable }
            return planRemove(paths, rootPath: rootPath)
        case "mkdir":
            guard flags.allSatisfy({ $0 == "-p" }) else { return .unloggable }
            return planMkdir(paths, rootPath: rootPath)
        default:
            return .unloggable
        }
    }

    // MARK: - Per-command planners

    private static func planTransfer(
        _ type: FileOperationType,
        source: String,
        destination: String,
        rootPath: URL
    ) -> Plan {
        guard let sourceRel = relativePath(source, rootPath: rootPath),
            var destRel = relativePath(destination, rootPath: rootPath)
        else { return .unloggable }

        // `mv a dir/` (or an existing directory target) lands the file AT
        // `dir/basename(a)` — resolve now so undo moves the right path.
        let destURL = rootPath.appendingPathComponent(destRel)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir),
            isDir.boolValue
        {
            destRel = (destRel as NSString).appendingPathComponent(
                (sourceRel as NSString).lastPathComponent
            )
        } else if destination.hasSuffix("/") {
            // Target directory doesn't exist (command will fail) — but if
            // it somehow succeeds the landing spot is ambiguous. Skip.
            return .unloggable
        }
        return .mutations([
            PlannedOperation(
                type: type,
                path: sourceRel,
                destinationPath: destRel,
                previousContent: nil
            )
        ])
    }

    private static func planRemove(_ paths: [String], rootPath: URL) -> Plan {
        var operations: [PlannedOperation] = []
        for raw in paths {
            guard let rel = relativePath(raw, rootPath: rootPath) else { return .unloggable }
            let url = rootPath.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                !isDir.boolValue,
                let content = try? String(contentsOf: url, encoding: .utf8)
            else {
                // Missing file, directory, or non-UTF-8 body: not
                // restorable from a logged snapshot.
                return .unloggable
            }
            operations.append(
                PlannedOperation(
                    type: .delete,
                    path: rel,
                    destinationPath: nil,
                    previousContent: content
                )
            )
        }
        return .mutations(operations)
    }

    private static func planMkdir(_ paths: [String], rootPath: URL) -> Plan {
        var operations: [PlannedOperation] = []
        for raw in paths {
            guard let rel = relativePath(raw, rootPath: rootPath) else { return .unloggable }
            operations.append(
                PlannedOperation(
                    type: .dirCreate,
                    path: rel,
                    destinationPath: nil,
                    previousContent: nil
                )
            )
        }
        return .mutations(operations)
    }

    // MARK: - Path containment

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
        if resolved == root { return nil }  // the root itself is never a target
        guard resolved.hasPrefix(root + "/") else { return nil }
        return String(resolved.dropFirst(root.count + 1))
    }
}
