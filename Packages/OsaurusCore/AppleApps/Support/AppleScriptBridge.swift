//
//  AppleScriptBridge.swift
//  osaurus
//
//  Thin wrapper over `AppleScriptExecutor` for the Apple app tools that
//  drive Notes, Mail, Music, Messages (send) and Maps (open) through Apple
//  Events. The executor already serialises runs, arms the main-runloop
//  heartbeat, and classifies -1743 permission denials; this layer adds:
//
//    - typed `AppleToolError` mapping (permission / not running / AE timeout),
//    - one shared record encoding for scripts that return tabular data
//      (unit-separator fields, record-separator rows — replaces the three
//      slightly different `encodeField` handlers the plugins duplicated),
//    - string-literal escaping so user text can be embedded safely, and
//    - a "make sure the app is running without stealing focus" helper.
//

import AppKit
import Foundation

enum AppleScriptBridge {
    /// Default per-script budget for the app tools. Reads finish in well under
    /// a second once the app is up; a cold launch can take several seconds.
    static let defaultTimeout: TimeInterval = 45

    /// AppleScript error numbers this layer classifies.
    enum ErrorNumber {
        /// `errAEEventNotPermitted` — Automation permission denied.
        static let permissionDenied = -1743
        /// `procNotFound` — the target application is not running / crashed.
        static let appNotRunning = -600
        /// `connectionInvalid` — the app quit mid-conversation.
        static let connectionInvalid = -609
        /// `errAETimeout` — the app did not reply in time.
        static let appleEventTimeout = -1712
        /// `errAENoSuchObject` — the referenced object does not exist.
        static let noSuchObject = -1728
        /// `errAEEventFailed`.
        static let eventFailed = -10000
    }

    // MARK: - Run

    /// Run `source`, mapping failures to `AppleToolError`. On success returns
    /// the coerced textual output (empty string when the script returned
    /// nothing).
    ///
    /// `isWrite` marks scripts that mutate or send: when the executor gives
    /// up on one of those (`.timedOut`), the script may still complete inside
    /// the app, so the error explicitly says the outcome is unknown and is
    /// flagged non-retryable — a blind retry could send twice.
    @discardableResult
    static func run(
        _ source: String,
        permission: SystemPermission,
        appName: String,
        timeout: TimeInterval = defaultTimeout,
        isWrite: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        // A run queued behind another script must not start once the caller's
        // task is cancelled (the user pressed Stop): for writes that would be
        // a send nobody asked for any more. The executor checks the flag on
        // the serial queue right before executing; an already-running script
        // cannot be interrupted and is governed by `timeout`.
        let cancelled = CancellationFlag()
        let result = await withTaskCancellationHandler {
            await AppleScriptExecutor.run(source: source, timeout: timeout, skipIf: { cancelled.isSet })
        } onCancel: {
            cancelled.set()
        }
        if cancelled.isSet, result.status == .timedOut,
            result.errorMessage == AppleScriptExecutor.skippedBeforeStartMessage
        {
            throw CancellationError()
        }
        switch result.status {
        case .success:
            // A successful send proves the Automation grant; keep the
            // Permissions pane / Abilities card state fresh.
            await MainActor.run {
                SystemPermissionService.shared.updatePermissionState(permission, isGranted: true)
            }
            return result.output ?? ""
        case .permissionRequired:
            await MainActor.run {
                SystemPermissionService.shared.updatePermissionState(permission, isGranted: false)
            }
            throw AppleToolError.permissionDenied(
                permission,
                detail: "macOS shows the \"Osaurus wants access to control \(appName)\" dialog on the first attempt; if it was dismissed, re-enable it under Automation → Osaurus → \(appName)."
            )
        case .timedOut:
            if isWrite {
                throw AppleToolError.timeout(
                    "\(appName) did not confirm the change within \(Int(timeout))s. The outcome is unknown — it may still complete inside \(appName). Check \(appName) before retrying; do not repeat a send blindly.",
                    outcomeUnknown: true
                )
            }
            throw AppleToolError.timeout(
                result.errorMessage ?? "\(appName) did not respond within \(Int(timeout))s."
            )
        case .compileError:
            throw AppleToolError.execution(
                "Internal AppleScript for \(appName) failed to compile: \(result.errorMessage ?? "unknown error")"
            )
        case .runtimeError:
            throw mapRuntimeError(
                number: result.errorNumber, message: result.errorMessage, appName: appName, timeout: timeout
            )
        }
    }

    /// Lock-free-enough flag shared between the cancellation handler and the
    /// executor's serial queue.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static func mapRuntimeError(
        number: Int?, message: String?, appName: String, timeout: TimeInterval
    ) -> AppleToolError {
        let text = message ?? "\(appName) reported an error."
        switch number {
        case ErrorNumber.appNotRunning?, ErrorNumber.connectionInvalid?:
            return .unavailable(
                "\(appName) is not running or stopped responding (\(text)). Open \(appName) and try again.",
                retryable: true
            )
        case ErrorNumber.appleEventTimeout?:
            return .timeout("\(appName) did not reply within \(Int(timeout))s (\(text)). Try a narrower request.")
        case ErrorNumber.noSuchObject?:
            return .notFound("\(appName) could not find the requested item (\(text)).")
        default:
            // Only -1728 is a not-found. "Can't get …" also covers wrong
            // property names and coercion failures, which must surface as
            // execution errors so a script bug is not mistaken for a
            // missing item.
            let lowered = text.lowercased()
            if lowered.contains("isn't running") || lowered.contains("is not running") {
                return .unavailable("\(appName) is not running (\(text)). Open \(appName) and try again.", retryable: true)
            }
            let suffix = number.map { " [\($0)]" } ?? ""
            return .execution("\(appName) error\(suffix): \(text)")
        }
    }

    // MARK: - App lifecycle

    /// Launch `bundleIdentifier` in the background (never activates / steals
    /// focus) if it is not already running. Returns `true` when the app is
    /// running after the call. Waits briefly for a cold launch so the first
    /// Apple Event does not race the app's startup.
    static func ensureRunning(bundleIdentifier: String, appName: String, launch: Bool = true) async -> Bool {
        let workspace = NSWorkspace.shared
        if workspace.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return true
        }
        guard launch, let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = false
        config.addsToRecentItems = false
        do {
            _ = try await workspace.openApplication(at: url, configuration: config)
        } catch {
            return false
        }
        // Give the app a moment to bring up its scripting server.
        for _ in 0 ..< 20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if workspace.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return true
            }
        }
        return false
    }

    /// Whether `error` is the "app went away" family (-600 / -609) worth one
    /// relaunch-and-retry from services that already called `ensureRunning`.
    static func isAppGoneError(_ error: Error) -> Bool {
        guard let apple = error as? AppleToolError, case .unavailable(_, let retryable) = apple else { return false }
        return retryable
    }

    /// Run `body` once; if the app vanished mid-call (-600 / -609), relaunch
    /// it and retry exactly once. Writes are never retried (they may have
    /// landed) — callers pass `isWrite: true` to opt out.
    static func runRetryingIfAppGone<T>(
        bundleIdentifier: String, appName: String, isWrite: Bool, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch where !isWrite && isAppGoneError(error) {
            try Task.checkCancellation()
            guard await ensureRunning(bundleIdentifier: bundleIdentifier, appName: appName) else { throw error }
            return try await body()
        }
    }

    /// Whether the app is currently running (no launch).
    static func isRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    // MARK: - Literals

    /// Escape `value` for embedding inside an AppleScript double-quoted string.
    ///
    /// Iterates Unicode scalars, not `Character`s: a quote or backslash fused
    /// with a following combining mark forms one grapheme cluster, so a
    /// `Character` loop would append it unescaped and let the string break out
    /// of the literal. AppleScript strings are UTF-16 code units, so escaping
    /// per scalar is the correct granularity.
    static func literal(_ value: String) -> String {
        var out = "\""
        out.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    /// AppleScript list literal of strings.
    static func listLiteral(_ values: [String]) -> String {
        "{" + values.map(literal).joined(separator: ", ") + "}"
    }

    // MARK: - Record encoding

    /// Field separator (ASCII unit separator) used by tabular scripts.
    static let fieldSeparator: Character = "\u{1F}"
    /// Record separator (ASCII record separator) between rows.
    static let recordSeparator: Character = "\u{1E}"

    /// AppleScript prelude that defines `FS` / `RS` as the separator
    /// characters so scripts can build rows with `item & FS & item & RS`.
    static let separatorPrelude = """
        set FS to character id 31
        set RS to character id 30
        """

    /// Split a script's output into rows of fields. Empty output → `[]`.
    ///
    /// Splits on Unicode scalars: a separator control character immediately
    /// followed by a combining mark would otherwise merge into one
    /// `Character` and vanish as a boundary, shifting every later field.
    static func parseRecords(_ output: String) -> [[String]] {
        guard !output.isEmpty else { return [] }
        let rs = recordSeparator.unicodeScalars.first!
        let fs = fieldSeparator.unicodeScalars.first!
        return output.unicodeScalars.split(separator: rs, omittingEmptySubsequences: true).map { row in
            row.split(separator: fs, omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        }
    }

    /// AppleScript handler that renders a `date` as `yyyy-MM-dd HH:mm:ss` in
    /// the app's (local) timezone. Scripts call `my isoDate(theDate)`; the
    /// Swift side parses it with `AppleDateParsing.parse` and re-emits with
    /// the local offset — the plugin bug was suffixing this local string with
    /// "Z".
    static let isoDateHandler = """
        on isoDate(d)
            if d is missing value then return ""
            try
                set y to year of d as integer
                set m to (month of d as integer)
                set dd to day of d as integer
                set hh to hours of d as integer
                set mm to minutes of d as integer
                set ss to seconds of d as integer
                return (y as string) & "-" & my pad2(m) & "-" & my pad2(dd) & " " & my pad2(hh) & ":" & my pad2(mm) & ":" & my pad2(ss)
            on error
                return ""
            end try
        end isoDate
        on pad2(n)
            if n < 10 then return "0" & (n as string)
            return n as string
        end pad2
        """

    /// Parse the `yyyy-MM-dd HH:mm:ss` local string produced by
    /// `isoDateHandler` into an ISO8601-with-offset string (or nil).
    static func isoOutput(_ scriptDate: String) -> String? {
        let trimmed = scriptDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = AppleDateParsing.parse(trimmed) else { return nil }
        return AppleDateParsing.format(parsed.date)
    }

    /// Parse the local script date into a `Date`.
    static func date(_ scriptDate: String) -> Date? {
        let trimmed = scriptDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AppleDateParsing.parse(trimmed)?.date
    }

    /// AppleScript expression building a `date` object from a Swift `Date`
    /// in local time, e.g. for "since" filters. Uses the locale-safe
    /// component-setting idiom rather than `date "string"` coercion.
    static func dateExpression(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return """
            (my makeDate(\(c.year ?? 1970), \(c.month ?? 1), \(c.day ?? 1), \(c.hour ?? 0), \(c.minute ?? 0), \(c.second ?? 0)))
            """
    }

    /// Handler paired with `dateExpression`.
    static let makeDateHandler = """
        on makeDate(y, m, d, hh, mm, ss)
            set theDate to current date
            set day of theDate to 1
            set year of theDate to y
            set month of theDate to m
            set day of theDate to d
            set time of theDate to (hh * 3600 + mm * 60 + ss)
            return theDate
        end makeDate
        """

    /// Interpret a boolean rendered by the executor (`true`/`false`).
    static func bool(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    /// Interpret an integer rendered by the executor.
    static func int(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Interpret a real rendered by the executor.
    static func double(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}
