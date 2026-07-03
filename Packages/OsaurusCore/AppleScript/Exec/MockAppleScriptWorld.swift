//
//  MockAppleScriptWorld.swift
//  OsaurusCore — AppleScript Computer Use (evals)
//
//  A minimal, deterministic simulation of the tiny slice of "app world" the
//  AppleScript capability evals need to assert outcomes WITHOUT touching the
//  real desktop: Notes bodies, the system output volume, the front Safari
//  page's URL, Mail's inbox unread count, Finder folders, and the frontmost
//  process (System Events). It records writes and answers the matching
//  read-back so a `live` case can prove the model's script actually set the
//  right state, then read it back — the same write-then-verify shape the loop
//  encourages — with zero side effects.
//
//  It is a TEST DOUBLE, not production behavior: it simulates the OS, it never
//  inspects, coerces, or repairs the model's output. A script it can't
//  confidently classify returns the caller's per-case default result, so the
//  model is never scored against the mock's parsing gaps (AGENTS.md: no fake
//  guards / synthetic output filters). Values round-trip verbatim: a note body
//  is stored by UN-escaping the AppleScript string literal, so a read-back
//  equals the exact text the parent passed in.
//

import Foundation

/// A keyed "app world" the mock executor mutates. Value type: each `handle`
/// returns a result and a possibly-mutated copy, so the executor can snapshot
/// final state for `finalStateEquals` assertions.
public struct MockAppleScriptWorld: Sendable, Equatable {
    /// Note name → body (raw, un-escaped text).
    public private(set) var notes: [String: String]
    /// System output volume (0–100), if set/seeded.
    public private(set) var volume: Int?
    /// The front Safari document's URL, if seeded/set.
    public private(set) var safariURL: String?
    /// Mail inbox unread count, if seeded.
    public private(set) var mailUnread: Int?
    /// The frontmost application process name (System Events), if seeded.
    public private(set) var frontmostApp: String?
    /// Finder folder name → exists. Seeded folders read as existing; a
    /// `make new folder` records the new name.
    public private(set) var folders: [String: Bool]
    /// Canonical keys written, in order (e.g. `note:Quotes`, `volume`).
    public private(set) var writeLog: [String] = []

    public init(
        notes: [String: String] = [:],
        volume: Int? = nil,
        safariURL: String? = nil,
        mailUnread: Int? = nil,
        frontmostApp: String? = nil,
        folders: [String: Bool] = [:]
    ) {
        self.notes = notes
        self.volume = volume
        self.safariURL = safariURL
        self.mailUnread = mailUnread
        self.frontmostApp = frontmostApp
        self.folders = folders
    }

    /// Canonical final state: `note:<name>` → body, `volume` → number,
    /// `safari:url` → URL, `mail:unread` → count, `frontmost` → app name,
    /// `folder:<name>` → "true"/"false".
    public func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for (name, body) in notes { out["note:\(name)"] = body }
        if let volume { out["volume"] = String(volume) }
        if let safariURL { out["safari:url"] = safariURL }
        if let mailUnread { out["mail:unread"] = String(mailUnread) }
        if let frontmostApp { out["frontmost"] = frontmostApp }
        for (name, exists) in folders { out["folder:\(name)"] = exists ? "true" : "false" }
        return out
    }

    /// Simulate running `script`. Writes update state and return a bare
    /// success; a recognized read returns the stored value; anything else
    /// returns `fallback` (so harness ignorance never scores against the model).
    /// A multi-app script (e.g. Safari + Finder in one `run_applescript`)
    /// records EVERY recognized write, not just the first — otherwise a
    /// well-formed combined script would be scored as if half of it never ran.
    public mutating func handle(
        _ script: String,
        fallback: AppleScriptExecutionResult
    ) -> AppleScriptExecutionResult {
        // Simple `set name to "literal"` bindings, so idiomatic scripts that
        // hoist their values (`set folderName to "Osaurus Drops"` … `{name:
        // folderName}`) resolve to the same literal a direct form would.
        let bindings = Self.parseStringBindings(script)

        var wroteAny = false
        if let write = Self.parseNoteBodyWrite(script) {
            notes[write.name] = write.value
            writeLog.append("note:\(write.name)")
            wroteAny = true
        }
        if let create = Self.parseNoteCreate(script) {
            notes[create.name] = create.value
            writeLog.append("note:\(create.name)")
            wroteAny = true
        }
        if let newVolume = Self.parseVolumeWrite(script) {
            volume = newVolume
            writeLog.append("volume")
            wroteAny = true
        }
        if let url = Self.parseSafariURLWrite(script, bindings: bindings) {
            safariURL = url
            writeLog.append("safari:url")
            wroteAny = true
        }
        if let folder = Self.parseFolderCreate(script, bindings: bindings) {
            folders[folder] = true
            writeLog.append("folder:\(folder)")
            wroteAny = true
        }
        if wroteAny { return .success(nil) }

        if let name = Self.parseNoteBodyRead(script), let body = notes[name] {
            return .success(body)
        }
        if Self.isVolumeRead(script), let volume {
            return .success(String(volume))
        }
        if Self.isSafariURLRead(script), let safariURL {
            return .success(safariURL)
        }
        if Self.isMailUnreadRead(script), let mailUnread {
            return .success(String(mailUnread))
        }
        if Self.isFrontmostRead(script), let frontmostApp {
            return .success(frontmostApp)
        }
        if let folder = Self.parseFolderExistsRead(script, bindings: bindings) {
            return .success(folders[folder] == true ? "true" : "false")
        }
        return fallback
    }

    // MARK: - Heuristic parsers
    //
    // Deliberately narrow: they confidently recognize the single-statement
    // Notes-body and volume forms the suite exercises and bail (→ fallback) on
    // anything else rather than guessing.

    /// `set body of note "NAME" to "VALUE"` → (NAME, un-escaped VALUE).
    static func parseNoteBodyWrite(_ script: String) -> (name: String, value: String)? {
        let lower = script.lowercased()
        guard lower.contains("set"), lower.range(of: "body of note") != nil else { return nil }
        guard let bodyRange = lower.range(of: "body of note") else { return nil }
        // The write form is `set body of note … to …`; a `set x to body of
        // note …` is a read (the `to` comes BEFORE `body of note`), so require
        // a `to` AFTER the note name literal.
        let afterBody = script[bodyRange.upperBound...]
        guard let name = firstStringLiteral(afterBody) else { return nil }
        let afterName = script[name.end...]
        guard
            let toRange = afterName.range(of: #"\bto\b"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        guard let value = firstStringLiteral(afterName[toRange.upperBound...]) else { return nil }
        return (name.value, value.value)
    }

    /// A note CREATE via `make new note with properties {name:"NAME", body:
    /// "VALUE"}` (property order not significant, optional `at folder …`) → the
    /// (NAME, un-escaped VALUE). Simulates the find-or-create path so a
    /// create-if-missing script records the new note for a final-state check.
    static func parseNoteCreate(_ script: String) -> (name: String, value: String)? {
        let lower = script.lowercased()
        guard lower.contains("make new note") else { return nil }
        guard let nameKey = lower.range(of: #"name\s*:"#, options: .regularExpression),
            let name = firstStringLiteral(script[nameKey.upperBound...])
        else { return nil }
        guard let bodyKey = lower.range(of: #"body\s*:"#, options: .regularExpression),
            let body = firstStringLiteral(script[bodyKey.upperBound...])
        else { return nil }
        return (name.value, body.value)
    }

    /// A note-body READ (`return body of note "NAME"`, `get body of note
    /// "NAME"`, `set t to body of note "NAME"`). Returns the note name.
    static func parseNoteBodyRead(_ script: String) -> String? {
        // Not a write (write is handled first, but guard anyway).
        if parseNoteBodyWrite(script) != nil { return nil }
        let lower = script.lowercased()
        guard let bodyRange = lower.range(of: "body of note") else { return nil }
        return firstStringLiteral(script[bodyRange.upperBound...])?.value
    }

    /// `set volume output volume N` / `set volume N` → N (clamped 0–100).
    static func parseVolumeWrite(_ script: String) -> Int? {
        let lower = script.lowercased()
        guard lower.contains("set volume") else { return nil }
        // Prefer an explicit `output volume N`, else the first integer after
        // `set volume`.
        if let range = lower.range(of: #"output volume\s+(\d+)"#, options: .regularExpression) {
            return Int(lower[range].filter(\.isNumber)).map { min(100, max(0, $0)) }
        }
        guard let setRange = lower.range(of: "set volume") else { return nil }
        let after = lower[setRange.upperBound...]
        if let digits = after.range(of: #"\d+"#, options: .regularExpression) {
            return Int(after[digits]).map { min(100, max(0, $0)) }
        }
        return nil
    }

    /// A volume READ: mentions volume with a read verb and is not a write.
    static func isVolumeRead(_ script: String) -> Bool {
        let lower = script.lowercased()
        guard lower.contains("volume"), !lower.contains("set volume") else { return false }
        return lower.contains("get") || lower.contains("return") || lower.contains("output volume")
    }

    /// A Safari URL WRITE in any of the idiomatic forms — `set URL of front
    /// document to …`, `set URL of current tab of front window to …`,
    /// `open location …`, `make new document with properties {URL:…}` — where
    /// the value is a string literal or a bound identifier. Returns the URL.
    static func parseSafariURLWrite(
        _ script: String,
        bindings: [String: String] = [:]
    ) -> String? {
        let writeMarkers = [
            #"set\s+(the\s+)?url\s+of\s+(the\s+)?front\s+document\s+to"#,
            #"set\s+(the\s+)?url\s+of\s+(the\s+)?current\s+tab\s+of\s+(the\s+)?front\s+window\s+to"#,
            #"open\s+location"#,
            #"make\s+new\s+document\s+with\s+properties\s*\{\s*url\s*:"#,
        ]
        for marker in writeMarkers {
            if let range = script.range(
                of: marker,
                options: [.regularExpression, .caseInsensitive]
            ),
                let value = stringValue(after: range.upperBound, in: script, bindings: bindings)
            {
                return value
            }
        }
        return nil
    }

    /// A Safari front-document URL READ (`URL of front document` /
    /// `URL of current tab of front window`) that is not the write form.
    static func isSafariURLRead(_ script: String) -> Bool {
        guard parseSafariURLWrite(script) == nil else { return false }
        let lower = script.lowercased()
        return lower.range(
            of: #"url\s+of\s+(the\s+)?(front\s+document|current\s+tab)"#,
            options: .regularExpression
        ) != nil
    }

    /// A Mail inbox unread-count READ: the canonical `unread count of inbox`
    /// property, or the equivalent manual filter `(count of) messages of
    /// inbox whose read status is false`. Both unambiguously ask for the
    /// same number the world seeds.
    static func isMailUnreadRead(_ script: String) -> Bool {
        let lower = script.lowercased()
        if lower.contains("unread count") { return true }
        return lower.range(
            of: #"messages\s+of\s+(the\s+)?inbox\s+whose\s+read\s+status\s+is\s+false"#,
            options: .regularExpression
        ) != nil
    }

    /// A System Events frontmost-process READ (`… application process whose
    /// frontmost is true`). Must not be a write (`set frontmost …`).
    static func isFrontmostRead(_ script: String) -> Bool {
        let lower = script.lowercased()
        guard !lower.contains("set frontmost") else { return false }
        return lower.range(
            of: #"(application\s+)?process(es)?\s+whose\s+frontmost\s+is\s+true"#,
            options: .regularExpression
        ) != nil
    }

    /// A Finder folder CREATE (`make new folder … {name:"NAME"}` or
    /// `{name:boundIdentifier}`) → NAME.
    static func parseFolderCreate(
        _ script: String,
        bindings: [String: String] = [:]
    ) -> String? {
        guard
            let makeRange = script.range(
                of: "make new folder",
                options: .caseInsensitive
            )
        else { return nil }
        guard
            let nameKey = script.range(
                of: #"name\s*:"#,
                options: [.regularExpression, .caseInsensitive],
                range: makeRange.upperBound ..< script.endIndex
            )
        else { return nil }
        return stringValue(after: nameKey.upperBound, in: script, bindings: bindings)
    }

    /// A Finder folder-existence READ (`exists folder "NAME"` /
    /// `exists folder boundIdentifier`) → NAME. The write is handled first, so
    /// a create-if-missing COMPOUND script (both forms in one script) resolves
    /// as the create.
    static func parseFolderExistsRead(
        _ script: String,
        bindings: [String: String] = [:]
    ) -> String? {
        guard
            let existsRange = script.range(
                of: #"exists\s+folder"#,
                options: [.regularExpression, .caseInsensitive]
            )
        else { return nil }
        return stringValue(after: existsRange.upperBound, in: script, bindings: bindings)
    }

    // MARK: - Identifier bindings

    /// Collect `set <identifier> to "literal"` bindings so parsers can resolve
    /// an idiomatic hoisted value (`set folderName to "Osaurus Drops"`).
    /// Only DIRECT string-literal assignments bind; anything computed stays
    /// unresolved (→ fallback), never guessed.
    static func parseStringBindings(_ script: String) -> [String: String] {
        var bindings: [String: String] = [:]
        var searchStart = script.startIndex
        while let setRange = script.range(
            of: #"\bset\s+([A-Za-z_][A-Za-z0-9_]*)\s+to\s+""#,
            options: [.regularExpression, .caseInsensitive],
            range: searchStart ..< script.endIndex
        ) {
            let clause = script[setRange]
            // The identifier sits between "set" and "to" in the matched clause.
            let afterSet = clause.dropFirst(3).drop(while: \.isWhitespace)
            let identifier = String(afterSet.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            if !identifier.isEmpty,
                let literal = firstStringLiteral(script[setRange.lowerBound...])
            {
                bindings[identifier.lowercased()] = literal.value
                searchStart = literal.end
            } else {
                searchStart = setRange.upperBound
            }
        }
        return bindings
    }

    /// Resolve the value expression at `index`: a direct string literal, or a
    /// bare identifier previously bound to one. Anything else (computed
    /// expressions, parenthesized forms) stays unresolved — the caller falls
    /// back rather than guessing.
    private static func stringValue(
        after index: String.Index,
        in script: String,
        bindings: [String: String]
    ) -> String? {
        let head = script[index...].drop(while: { $0 == " " || $0 == "\t" })
        if head.first == "\"" {
            return firstStringLiteral(head)?.value
        }
        let identifier = String(head.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        guard !identifier.isEmpty else { return nil }
        return bindings[identifier.lowercased()]
    }

    // MARK: - AppleScript string-literal scanner

    /// Scan the FIRST double-quoted AppleScript string literal in `text`,
    /// honoring `\`-escapes, and return its UN-escaped content plus the index
    /// just past the closing quote. Inverse of
    /// `AppleScriptLiterals.escapeForAppleScriptLiteral`, so a value written via
    /// a `{{…}}` placeholder round-trips to the exact text. `nil` when there is
    /// no complete literal.
    static func firstStringLiteral(_ text: Substring) -> (value: String, end: String.Index)? {
        guard let openQuote = text.firstIndex(of: "\"") else { return nil }
        var out = ""
        var index = text.index(after: openQuote)
        while index < text.endIndex {
            let char = text[index]
            if char == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                switch text[next] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case let other: out.append(other)
                }
                index = text.index(after: next)
                continue
            }
            if char == "\"" {
                return (out, text.index(after: index))
            }
            out.append(char)
            index = text.index(after: index)
        }
        return nil
    }
}

extension AppleScriptExecutionResult {
    /// A bare success carrying `output` (nil = ran, no return value).
    fileprivate static func success(_ output: String?) -> AppleScriptExecutionResult {
        AppleScriptExecutionResult(
            status: .success,
            output: output,
            errorNumber: nil,
            errorMessage: nil
        )
    }
}
