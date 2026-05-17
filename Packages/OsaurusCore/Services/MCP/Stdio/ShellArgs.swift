//
//  ShellArgs.swift
//  osaurus
//
//  Shell-like argument tokenization and re-quoting helpers for stdio MCP
//  providers. Both directions are needed:
//
//    * `splitShellArgs` parses what the user types in the editor's "Args"
//      field. A naive `split(separator: " ")` breaks quoted paths such as
//      `--root '/Users/me/long path'`, so we honor single + double quotes
//      and `\` escapes the way `sh` does.
//    * `joinShellArgs` is the inverse — used when loading a saved
//      provider into the editor so quoted args round-trip cleanly.
//
//  These helpers are intentionally minimal: no `$VAR` expansion, no
//  redirection / pipe handling, no globbing. They only need to be a
//  faithful inverse pair for the simple "command + args" use case.
//

import Foundation

public enum ShellArgs {
    /// Split a shell-like command tail into individual arguments.
    ///
    /// Honors:
    ///   * Single quotes (`'…'`): literal until the closing quote.
    ///   * Double quotes (`"…"`): literal until the closing quote, with
    ///     `\\"` and `\\\\` escapes recognised inside.
    ///   * Backslash outside quotes: escape the next character.
    ///   * Whitespace runs: argument separator.
    ///
    /// Unterminated quotes are tolerated — the tail of the string up to
    /// EOF becomes the current argument. The UI should validate before
    /// saving if a stricter contract is needed.
    public static func split(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var hasCurrent = false

        enum Quote { case none, single, double }
        var quote: Quote = .none
        /// Set when the previous character was a `\` outside single
        /// quotes. The exact handling on the next char depends on
        /// whether we're inside double quotes (POSIX restricts which
        /// chars `\` escapes there); the consumer switch knows the rule.
        var pendingBackslash = false

        for char in input {
            if pendingBackslash {
                switch quote {
                case .double:
                    // POSIX: inside double quotes, `\` is only an escape
                    // before `"`, `\`, `$`, `` ` ``, or newline. Anything
                    // else keeps the backslash literal — important for
                    // regex args like `--regex "\d+"`.
                    if char == "\"" || char == "\\" || char == "$" || char == "`" || char == "\n" {
                        current.append(char)
                    } else {
                        current.append("\\")
                        current.append(char)
                    }
                case .none, .single:
                    current.append(char)
                }
                hasCurrent = true
                pendingBackslash = false
                continue
            }

            switch quote {
            case .none:
                if char == "\\" {
                    pendingBackslash = true
                } else if char == "'" {
                    quote = .single
                    hasCurrent = true
                } else if char == "\"" {
                    quote = .double
                    hasCurrent = true
                } else if char.isWhitespace {
                    if hasCurrent {
                        args.append(current)
                        current = ""
                        hasCurrent = false
                    }
                } else {
                    current.append(char)
                    hasCurrent = true
                }

            case .single:
                if char == "'" {
                    quote = .none
                } else {
                    current.append(char)
                }

            case .double:
                if char == "\\" {
                    pendingBackslash = true
                } else if char == "\"" {
                    quote = .none
                } else {
                    current.append(char)
                }
            }
        }

        // Trailing backslash with no follow-up character — keep it
        // literal rather than swallowing the user's input.
        if pendingBackslash {
            current.append("\\")
            hasCurrent = true
        }
        if hasCurrent {
            args.append(current)
        }
        return args
    }

    /// Join args back into a shell-friendly string. Bare-safe tokens
    /// (alphanumerics + `-_./:@`) pass through; everything else is
    /// single-quoted with embedded `'` rewritten as `'\''`.
    public static func join(_ args: [String]) -> String {
        args.map(quote(_:)).joined(separator: " ")
    }

    /// Single-arg quoting. Exposed so other call sites (e.g. the sandbox
    /// runner that builds a `sh -c` command) don't reimplement the rule.
    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:@".contains($0) }) {
            return s
        }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
