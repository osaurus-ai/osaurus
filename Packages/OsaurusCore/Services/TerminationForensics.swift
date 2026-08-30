//
//  TerminationForensics.swift
//  osaurus
//
//  Attribution for silent restarts. The motivating report: the app's UI and
//  menu bar icon vanished and reappeared every few minutes with NO crash
//  report, and a factory reset destroyed the evidence — leaving nothing to
//  attribute. The gap: a clean `exit(0)`/watchdog kill produces no crash log,
//  so an unexplained termination is indistinguishable from a normal quit.
//
//  Mechanism, deliberately file-based so it works even in builds whose log
//  sink is disabled:
//  - Every INTENTIONAL exit path writes `last-exit.json` (reason, timestamp,
//    pid, version) atomically before the process dies.
//  - The next launch reads-and-clears the marker and writes
//    `last-exit-verdict.json`: `clean` (marker present — normal quit) or
//    `unattributed` (no marker — the previous instance died without passing
//    through any intentional exit path: crash, SIGKILL, watchdog, or an
//    unmarked termination call that should then be found and marked).
//    Unattributed verdicts also go to the crash-reporting breadcrumb trail so
//    a Sentry-visible session carries the evidence forward.
//
//  A fresh install (no marker AND no verdict history) is `firstLaunch`, not
//  `unattributed` — otherwise every new user would start with a false alarm.
//

import Foundation

public enum TerminationForensics {

    public struct ExitMarker: Codable, Equatable {
        public let reason: String
        public let timestamp: Date
        public let pid: Int32
        public let version: String
    }

    public enum LaunchVerdict: String, Codable {
        /// Previous instance exited through an intentional path.
        case clean
        /// Previous instance died without reaching ANY intentional exit path.
        case unattributed
        /// No previous-instance evidence at all (fresh root).
        case firstLaunch
    }

    public struct VerdictRecord: Codable {
        public let verdict: LaunchVerdict
        public let at: Date
        /// The prior marker's reason when the verdict is `clean`.
        public let previousReason: String?
    }

    static let markerName = "last-exit.json"
    static let verdictName = "last-exit-verdict.json"
    /// Sentinel proving a prior launch ran with forensics active, so a
    /// missing marker means "died unattributed", not "predates forensics".
    static let sentinelName = ".termination-forensics-active"

    private static func url(_ name: String) -> URL {
        OsaurusPaths.root().appendingPathComponent(name)
    }

    /// Write the intentional-exit marker. Synchronous and atomic: callers
    /// invoke this immediately before `NSApp.terminate` / `Darwin._exit`, so
    /// the write must complete before the process can die.
    public static func recordIntentionalExit(reason: String) {
        let marker = ExitMarker(
            reason: reason,
            timestamp: Date(),
            pid: ProcessInfo.processInfo.processIdentifier,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        )
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: url(markerName), options: .atomic)
    }

    /// Launch-time evaluation: read-and-clear the marker, emit the verdict.
    /// Returns the verdict so the caller can breadcrumb it.
    @discardableResult
    public static func evaluateAtLaunch() -> LaunchVerdict {
        let fm = FileManager.default
        let markerURL = url(markerName)
        let sentinelURL = url(sentinelName)

        let verdict: LaunchVerdict
        var previousReason: String?
        if let data = try? Data(contentsOf: markerURL),
            let marker = try? JSONDecoder().decode(ExitMarker.self, from: data)
        {
            verdict = .clean
            previousReason = marker.reason
        } else if fm.fileExists(atPath: sentinelURL.path) {
            verdict = .unattributed
        } else {
            verdict = .firstLaunch
        }

        try? fm.removeItem(at: markerURL)
        try? fm.createDirectory(
            at: OsaurusPaths.root(), withIntermediateDirectories: true)
        fm.createFile(atPath: sentinelURL.path, contents: Data())

        let record = VerdictRecord(verdict: verdict, at: Date(), previousReason: previousReason)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url(verdictName), options: .atomic)
        }

        if verdict == .unattributed {
            CrashReportingService.recordBreadcrumb(
                category: "lifecycle.termination",
                message: "previous instance ended without an intentional exit (no crash report expected — SIGKILL/watchdog/unmarked path)"
            )
        }
        return verdict
    }
}
