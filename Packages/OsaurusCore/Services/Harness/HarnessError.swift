//
//  HarnessError.swift
//  osaurus
//

import Foundation

public enum HarnessError: LocalizedError, Sendable, Equatable {
    /// The agent points at a runtime that was deleted from Settings.
    case runtimeMissing
    case executableNotFound(command: String, searchedPath: String)
    case launchFailed(runtime: String, detail: String)
    /// The chat's selected folder can't be opened (stale bookmark, moved, or
    /// macOS denied access). Never silently replaced by a scratch folder.
    case workingFolderUnavailable(path: String)
    case notAuthenticated(runtime: String, detail: String)
    case rateLimited(runtime: String, detail: String)
    case turnFailed(runtime: String, detail: String)
    case exited(runtime: String, code: Int32, stderrTail: String)
    /// The harness rejected the message outright (Pi `success: false`).
    case rejected(runtime: String, detail: String)
    /// The caller is a path that cannot drive an external harness in v1
    /// (HTTP agent runs, delegation, Computer Use, AppleScript).
    case unsupportedPath(agentName: String)

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return L(
                "This agent's runtime was removed. Choose a runtime for the agent in its settings, then try again."
            )
        case .executableNotFound(let command, _):
            return String(
                format: L("Couldn't find `%@`. Install it, or set the runtime's executable to its full path."),
                command
            )
        case .launchFailed(let runtime, let detail):
            return String(format: L("Couldn't start %@: %@"), runtime, detail)
        case .workingFolderUnavailable(let path):
            return String(
                format: L(
                    "Osaurus can't open the working folder %@. Choose the folder again, or clear it, then resend."
                ),
                path
            )
        case .notAuthenticated(let runtime, let detail):
            let firstLine =
                detail.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if firstLine.isEmpty {
                return String(format: L("%@ isn't signed in. Sign in to it, then try again."), runtime)
            }
            return String(format: L("%@ isn't signed in: %@"), runtime, firstLine)
        case .rateLimited(let runtime, let detail):
            return String(format: L("%@ hit a rate limit: %@"), runtime, detail)
        case .turnFailed(let runtime, let detail):
            return String(format: L("%@ couldn't complete the turn: %@"), runtime, detail)
        case .exited(let runtime, let code, let tail):
            if tail.isEmpty {
                return String(format: L("%@ exited with code %d."), runtime, Int(code))
            }
            return String(format: L("%@ exited with code %d: %@"), runtime, Int(code), tail)
        case .rejected(let runtime, let detail):
            return String(format: L("%@ rejected the message: %@"), runtime, detail)
        case .unsupportedPath(let agentName):
            return String(
                format: L(
                    "%@ runs on an external harness, which this feature can't drive. Chat with the agent in Osaurus instead."
                ),
                agentName
            )
        }
    }

    /// Promote the failures a user can act on (sign in, wait out a limit) out
    /// of a harness's free-form error text.
    static func classify(runtime: String, detail: String) -> HarnessError {
        let lowered = detail.lowercased()
        if lowered.contains("not logged in") || lowered.contains("please run `claude login`")
            || lowered.contains("sign in") || lowered.contains("authentication")
            || lowered.contains("unauthorized") || lowered.contains("invalid api key")
        {
            return .notAuthenticated(runtime: runtime, detail: detail)
        }
        if lowered.contains("rate limit") || lowered.contains("usage limit") {
            return .rateLimited(runtime: runtime, detail: detail)
        }
        return .turnFailed(runtime: runtime, detail: detail)
    }
}
