//
//  MockAppleScriptWorld.swift
//  OsaurusCore — AppleScript Computer Use (evals)
//
//  A minimal, deterministic simulation of the tiny slice of "app world" the
//  AppleScript capability evals need to assert outcomes WITHOUT touching the
//  real desktop: Notes bodies and the system output volume. It records writes
//  and answers the matching read-back so a `live` case can prove the model's
//  script actually set the right state, then read it back — the same
//  write-then-verify shape the loop encourages — with zero side effects.
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
    /// Canonical keys written, in order (e.g. `note:Quotes`, `volume`).
    public private(set) var writeLog: [String] = []

    public init(notes: [String: String] = [:], volume: Int? = nil) {
        self.notes = notes
        self.volume = volume
    }

    /// Canonical final state: `note:<name>` → body, `volume` → number.
    public func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for (name, body) in notes { out["note:\(name)"] = body }
        if let volume { out["volume"] = String(volume) }
        return out
    }

    /// Simulate running `script`. Writes update state and return a bare
    /// success; a recognized read returns the stored value; anything else
    /// returns `fallback` (so harness ignorance never scores against the model).
    public mutating func handle(
        _ script: String,
        fallback: AppleScriptExecutionResult
    ) -> AppleScriptExecutionResult {
        if let write = Self.parseNoteBodyWrite(script) {
            notes[write.name] = write.value
            writeLog.append("note:\(write.name)")
            return .success(nil)
        }
        if let newVolume = Self.parseVolumeWrite(script) {
            volume = newVolume
            writeLog.append("volume")
            return .success(nil)
        }
        if let name = Self.parseNoteBodyRead(script), let body = notes[name] {
            return .success(body)
        }
        if Self.isVolumeRead(script), let volume {
            return .success(String(volume))
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
