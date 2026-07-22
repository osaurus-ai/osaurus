//
//  BrowserSupport.swift
//  OsaurusCore — Native Browser Use
//
//  Behavior-free helpers shared by the native browser runtime: the snapshot
//  detail levels, the JS-string / selector escaping primitives, the snapshot
//  formatter, and the effect classification the shared autonomy gate reads.
//  Ported (verbatim where it matters for parity) from the MIT `osaurus.browser`
//  plugin so the native surface produces the same agent-facing output while
//  the plugin's semaphore-heavy ABI bridge is replaced by `@MainActor` async
//  WebKit calls (see `BrowserSession`).
//

import Foundation

// MARK: - Detail level

/// Snapshot verbosity requested by the model (mirrors the plugin's contract).
public enum BrowserDetailLevel: String, Sendable {
    case none
    case compact
    case standard
    case full

    /// Parse a raw string, falling back to `defaultLevel` when absent/invalid.
    public static func parse(_ raw: String?, default defaultLevel: BrowserDetailLevel) -> BrowserDetailLevel {
        guard let raw else { return defaultLevel }
        return BrowserDetailLevel(rawValue: raw) ?? defaultLevel
    }
}

// MARK: - JS / selector escaping

/// Escape a CSS selector for safe interpolation inside a single-quoted JS
/// string literal. Handles backslashes, single quotes, and whitespace that
/// would break a JS string. Free function so it stays unit-testable.
public func browserEscapeSelector(_ selector: String) -> String {
    selector
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

/// Escape a string for interpolation inside a double-quoted JSON literal.
public func browserEscapeJSON(_ s: String) -> String {
    s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

// MARK: - Effect classification

/// Classify a browser action into the shared Computer Use `EffectClass` so the
/// same autonomy gate governs both features (the plan's opt-in shared policy).
/// Reads (perception, inspection) are `.read`; ordinary navigation / focus is
/// `.navigate`; typing / selecting / setting cookies mutate reviewable state so
/// they are `.edit`; submit / send / delete / purchase / auth / session-reset /
/// arbitrary script are conservatively escalated to `.consequential`.
public enum BrowserEffectClassifier {
    /// Keyword needles in a click/link target that imply a hard-to-undo commit.
    static let consequentialNeedles: [String] = [
        "submit", "send", "delete", "remove", "buy", "purchase", "pay", "checkout",
        "order", "confirm", "place order", "sign in", "log in", "login", "sign up",
        "register", "transfer", "withdraw", "publish", "post", "delete account",
    ]

    /// Effect for a single primitive action verb + optional target label.
    /// `submit` folds the caller's explicit submit intent (type submit=true,
    /// Enter key) into the decision.
    public static func classify(action: String, target: String?, submit: Bool) -> EffectClass {
        switch action {
        case "snapshot", "wait_for", "console_messages", "network_requests", "get_cookies",
            "screenshot", "dialog_status", "read_page":
            return .read
        case "navigate", "back", "scroll", "hover":
            return .navigate
        case "type", "select", "set_cookie", "handle_dialog":
            return submit ? .consequential : .edit
        case "press_key":
            return submit ? .consequential : .navigate
        case "click":
            if targetLooksConsequential(target) { return .consequential }
            return .navigate
        case "clear_cookies", "reset_session", "open_login", "execute_script",
            "read_cookie_values":
            // read_cookie_values: exposing raw session tokens to the model is
            // an exfiltration channel, so it always needs a user confirm.
            return .consequential
        default:
            return .edit
        }
    }

    /// Whether a click/link target label reads like a consequential commit.
    public static func targetLooksConsequential(_ target: String?) -> Bool {
        guard let target = target?.lowercased(), !target.isEmpty else { return false }
        return consequentialNeedles.contains { target.contains($0) }
    }
}

// MARK: - Screenshot path confinement

/// Resolves where a `browser_screenshot` may be written. The `path` argument
/// is model-controlled, so without confinement it is an arbitrary-location
/// file write (overwriting anything the user can write). Policy: everything
/// lands inside ~/Downloads, traversal out of it is rejected, and existing
/// files are never overwritten (names are uniquified instead).
public enum BrowserScreenshotPath {
    /// Resolve the output URL for a screenshot.
    /// - `custom`: the model-provided `path` argument (may be nil).
    /// - `downloadsDir`: injection seam for tests; defaults to ~/Downloads.
    /// - Returns nil when the custom path escapes the downloads directory.
    public static func resolve(
        custom: String?,
        downloadsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads"),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: Date = Date()
    ) -> URL? {
        let base = downloadsDir.standardizedFileURL

        var candidate: URL
        if let custom, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                candidate = URL(fileURLWithPath: expanded)
            } else {
                // Relative paths are interpreted inside Downloads.
                candidate = base.appendingPathComponent(expanded)
            }
            candidate = candidate.standardizedFileURL
            // Containment check on path components — string prefix checks
            // would let "/Users/x/DownloadsEvil" slip past.
            let baseComponents = base.pathComponents
            let candidateComponents = candidate.pathComponents
            guard candidateComponents.count > baseComponents.count,
                Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
            else { return nil }
        } else {
            let timestamp = ISO8601DateFormatter().string(from: now)
                .replacingOccurrences(of: ":", with: "-")
            candidate = base.appendingPathComponent("screenshot_\(timestamp).png")
        }

        if candidate.pathExtension.lowercased() != "png" {
            candidate = candidate.appendingPathExtension("png")
        }

        // Never overwrite: uniquify with a numeric suffix.
        var unique = candidate
        var counter = 1
        let stem = candidate.deletingPathExtension()
        while fileExists(unique.path), counter < 1000 {
            unique = URL(fileURLWithPath: stem.path + "-\(counter)").appendingPathExtension("png")
            counter += 1
        }
        return unique
    }
}

// MARK: - Snapshot formatting

/// Formats the structured snapshot object (returned by the injected JS) into
/// the plain-text ref listing the model consumes. Ported from the plugin's
/// `formatSnapshotOutput` so the ref/type/attribute lines stay byte-identical.
public enum BrowserSnapshotFormatter {
    public static func format(_ data: [String: Any], detail: BrowserDetailLevel) -> String {
        let title = data["title"] as? String ?? ""
        let url = data["url"] as? String ?? ""
        let hasMore = data["hasMore"] as? Bool ?? false
        let bodyText = data["bodyText"] as? String ?? ""
        let crossOriginFrames = (data["crossOriginFrames"] as? [String] ?? [])
            .filter { !$0.isEmpty }

        switch detail {
        case .none:
            return ""
        case .compact:
            var output = "- page: \(title) | url: \(url)\n"
            guard let elements = data["elements"] as? [[String: Any]], !elements.isEmpty else {
                return output + "(no interactive elements found)"
            }
            var parts: [String] = []
            for element in elements {
                let ref = element["ref"] as? String ?? ""
                let type = element["type"] as? String ?? ""
                let text = element["text"] as? String ?? ""
                let truncText = text.count > 20 ? String(text.prefix(20)) + "..." : text
                if truncText.isEmpty {
                    parts.append("[\(ref)] \(type)")
                } else {
                    parts.append("[\(ref)] \(type) \"\(truncText)\"")
                }
            }
            output += parts.joined(separator: " ")
            if hasMore { output += " ..." }
            return output
        case .standard:
            var output = "- page: \(title)\n- url: \(url)\n"
            if !crossOriginFrames.isEmpty {
                output +=
                    "- cross-origin frames (content not reachable): "
                    + crossOriginFrames.joined(separator: " | ") + "\n"
            }
            output += "\n"
            guard let elements = data["elements"] as? [[String: Any]], !elements.isEmpty else {
                return output + "(no interactive elements found)"
            }
            for element in elements {
                output += line(for: element, includeId: false, includeAria: false) + "\n"
            }
            if hasMore {
                output += "\n... (more elements available, use filter or increase max_elements)"
            }
            return output
        case .full:
            var output = "- page: \(title)\n- url: \(url)\n"
            if !crossOriginFrames.isEmpty {
                output +=
                    "- cross-origin frames (content not reachable): "
                    + crossOriginFrames.joined(separator: " | ") + "\n"
            }
            if !bodyText.isEmpty {
                let truncBody = bodyText.count > 200 ? String(bodyText.prefix(200)) + "..." : bodyText
                let singleLine = truncBody
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                output += "- text: \(singleLine)\n"
            }
            output += "\n"
            guard let elements = data["elements"] as? [[String: Any]], !elements.isEmpty else {
                return output + "(no interactive elements found)"
            }
            for element in elements {
                output += line(for: element, includeId: true, includeAria: true) + "\n"
            }
            if hasMore {
                output += "\n... (more elements available, use filter or increase max_elements)"
            }
            return output
        }
    }

    private static func line(for element: [String: Any], includeId: Bool, includeAria: Bool) -> String {
        let ref = element["ref"] as? String ?? ""
        let type = element["type"] as? String ?? ""
        let text = element["text"] as? String ?? ""
        var line = "[\(ref)] \(type)"
        if !text.isEmpty { line += " \"\(text)\"" }

        var attrs: [String] = []
        if let name = element["name"] as? String, !name.isEmpty { attrs.append("name=\"\(name)\"") }
        if includeId, let id = element["id"] as? String, !id.isEmpty { attrs.append("id=\"\(id)\"") }
        if let placeholder = element["placeholder"] as? String, !placeholder.isEmpty {
            attrs.append("placeholder=\"\(placeholder)\"")
        }
        if let href = element["href"] as? String, !href.isEmpty {
            if includeId || type == "link" { attrs.append("href=\"\(href)\"") }
        }
        if let value = element["value"] as? String, !value.isEmpty { attrs.append("value=\"\(value)\"") }
        if includeAria, let ariaLabel = element["ariaLabel"] as? String, !ariaLabel.isEmpty {
            attrs.append("aria-label=\"\(ariaLabel)\"")
        }
        if element["checked"] as? Bool == true { attrs.append("checked") }
        if element["disabled"] as? Bool == true { attrs.append("disabled") }
        if element["required"] as? Bool == true { attrs.append("required") }
        if !attrs.isEmpty { line += " " + attrs.joined(separator: " ") }
        return line
    }
}

// MARK: - Login redirect detection

/// Conservative "did this navigation land on a login page?" heuristic. False
/// negatives are fine (the agent proceeds); false positives are worse (they
/// nag the user), so the needles stay narrow. Ported from the plugin.
public enum BrowserLoginDetector {
    static let pathHints = [
        "/login", "/signin", "/sign-in", "/sign_in", "/auth", "/account/login", "/users/sign_in",
    ]
    static let titlePattern = #"^(sign in|log in|login|authentication)"#

    /// Returns the host when the final URL / title look like a login page,
    /// else `nil`.
    public static func loginHost(finalURL: String, title: String) -> String? {
        let path = URL(string: finalURL)?.path.lowercased() ?? ""
        let host = URL(string: finalURL)?.host ?? ""
        let pathMatch = pathHints.contains { path.contains($0) }
        let titleMatch =
            title.range(of: titlePattern, options: [.regularExpression, .caseInsensitive]) != nil
        guard pathMatch || titleMatch else { return nil }
        return host
    }
}
