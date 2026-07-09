//
//  AppleScriptAppKnowledge.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Composes the per-run "app knowledge" prompt sections for the AppleScript
//  loop: which app(s) the task targets, the distilled scripting dictionary for
//  each (via `AppleScriptDictionaryService`), and the curated idiom tips (via
//  `AppleScriptRecipeCatalog`). Shared by the production kind and the eval
//  harness so both inject byte-identical knowledge for the same task/desktop.
//
//  Detection is deliberately conservative: an app is a target only when its
//  name appears in the task text (word-boundary, case-insensitive), or — when
//  the task names no app but asks about the "frontmost"/"current" app — the
//  frontmost app. No match → no injection (a battery query gets no Safari
//  dictionary just because Safari is frontmost).
//

import Foundation

public enum AppleScriptAppKnowledge {

    /// A running app the desktop snapshot captured. `bundleURL` powers the
    /// dictionary lookup; `nil` (eval-provided contexts) falls back to the
    /// standard install locations.
    public struct RunningApp: Sendable {
        public let name: String
        public let bundleURL: URL?

        public init(name: String, bundleURL: URL?) {
            self.name = name
            self.bundleURL = bundleURL
        }
    }

    /// Both knowledge sections for one run, either of which may be absent.
    public struct Sections: Sendable, Equatable {
        public let dictionary: String?
        public let recipes: String?

        public static let empty = Sections(dictionary: nil, recipes: nil)
    }

    /// Most apps whose knowledge is injected per run. Two keeps a multi-app
    /// chain covered while bounding the prompt.
    public static let maxApps = 2

    // MARK: - Target detection

    /// The app names `task` targets, in task order, capped at `limit`.
    /// Candidates are the running apps plus the recipe catalog's known names
    /// (so "Notes" matches even when Notes isn't running yet — the model may
    /// launch it). Falls back to the frontmost app only when the task names no
    /// app but refers to the frontmost/current/active app.
    public static func detectTargetApps(
        task: String,
        frontmost: String?,
        runningAppNames: [String],
        limit: Int = maxApps
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        for name in runningAppNames + AppleScriptRecipeCatalog.knownAppNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            candidates.append(trimmed)
        }

        var matches: [(position: Int, name: String)] = []
        for candidate in candidates {
            guard let range = wordRange(of: candidate, in: task) else { continue }
            matches.append((task.distance(from: task.startIndex, to: range.lowerBound), candidate))
        }
        matches.sort { $0.position < $1.position }

        var result: [String] = []
        for match in matches where result.count < limit {
            // "Shortcuts Events" ⊂ "Shortcuts" style overlaps: skip a name that
            // is a sub-match of one already taken at the same position.
            if !result.contains(where: { $0.caseInsensitiveCompare(match.name) == .orderedSame }) {
                result.append(match.name)
            }
        }
        if result.isEmpty, let frontmost, !frontmost.isEmpty, mentionsFrontmost(task) {
            result = [frontmost]
        }
        return result
    }

    /// Word-boundary, case-insensitive occurrence of `name` in `text`.
    private static func wordRange(of name: String, in text: String) -> Range<String.Index>? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return text.range(
            of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func mentionsFrontmost(_ task: String) -> Bool {
        let lower = task.lowercased()
        return lower.contains("frontmost") || lower.contains("front app")
            || lower.contains("current app") || lower.contains("active app")
            || lower.contains("front window") || lower.contains("this app")
    }

    // MARK: - Composition

    /// Compose the dictionary + recipe sections for `apps` (already detected /
    /// capped). Dictionary lookups resolve each app's bundle via the running
    /// snapshot, then the standard install locations; an app with no usable
    /// dictionary simply contributes nothing.
    public static func compose(apps: [String], runningApps: [RunningApp]) -> Sections {
        guard !apps.isEmpty else { return .empty }
        let lookup = runningApps.map { (name: $0.name, bundleURL: $0.bundleURL) }

        var dictionaries: [String] = []
        var recipeBlocks: [String] = []
        for app in apps.prefix(maxApps) {
            if let url = AppleScriptDictionaryService.bundleURL(appName: app, runningApps: lookup),
                let summary = AppleScriptDictionaryService.dictionarySummary(
                    appName: app,
                    bundleURL: url
                )
            {
                dictionaries.append(summary)
            }
            let tips = AppleScriptRecipeCatalog.recipes(for: app).flatMap(\.tips)
            if !tips.isEmpty {
                recipeBlocks.append(
                    "\(app) AppleScript tips:\n" + tips.map { "- \($0)" }.joined(separator: "\n")
                )
            }
        }
        return Sections(
            dictionary: dictionaries.isEmpty ? nil : dictionaries.joined(separator: "\n\n"),
            recipes: recipeBlocks.isEmpty ? nil : recipeBlocks.joined(separator: "\n\n")
        )
    }

    /// Parse a desktop-context string in the `desktopContext()` format
    /// ("Frontmost app: X\nRunning apps: a, b, c") back into its parts. Used by
    /// the eval harness, whose cases carry that exact format.
    public static func parseEnvironmentContext(_ context: String?) -> (
        frontmost: String?, runningNames: [String]
    ) {
        guard let context, !context.isEmpty else { return (nil, []) }
        var frontmost: String?
        var names: [String] = []
        for line in context.components(separatedBy: "\n") {
            if let value = suffix(of: line, after: "Frontmost app:") {
                frontmost = value
            } else if let value = suffix(of: line, after: "Running apps:") {
                names = value.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            }
        }
        return (frontmost, names)
    }

    private static func suffix(of line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
