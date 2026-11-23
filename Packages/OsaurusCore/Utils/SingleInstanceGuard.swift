//
//  SingleInstanceGuard.swift
//  osaurus
//
//  A second copy of the same app bundle (for example one started with
//  `open -n`) would share `~/.osaurus` and the server port with the first.
//  Like `SiblingAppGuard` for stable and beta, but for two processes of one
//  bundle: the later one hands focus to the earlier one and exits before any
//  singleton touches the data folder.
//

import AppKit

public enum SingleInstanceGuard {
    public static func exitIfAlreadyRunning() {
        if let root = ProcessEnvironment.value("OSAURUS_TEST_ROOT"),
            !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let ownPath = canonicalPath(Bundle.main.bundleURL)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { !$0.isTerminated && $0.bundleURL.map(canonicalPath) == ownPath }
        let own = Instance(pid: me.processIdentifier, launchDate: me.launchDate)
        guard
            let earlier = earlierInstance(
                than: own,
                among: running.map { Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
            ),
            let existing = running.first(where: { $0.processIdentifier == earlier.pid })
        else { return }
        fputs("Osaurus is already running (pid \(earlier.pid)); this copy is exiting.\n", stderr)
        // A CLI launch only wants the server; a Finder or Dock launch wants
        // the app in front.
        if !CommandLine.arguments.contains("--launched-by-cli") {
            existing.activate()
        }
        exit(0)
    }

    struct Instance: Equatable {
        let pid: pid_t
        let launchDate: Date?
    }

    /// The instance this one should defer to, if any. Two copies launched at
    /// the same moment agree on one survivor: the lower pid.
    static func earlierInstance(than own: Instance, among others: [Instance]) -> Instance? {
        let ownLaunch = own.launchDate ?? .distantFuture
        return others.filter { other in
            guard other.pid != own.pid else { return false }
            let otherLaunch = other.launchDate ?? .distantPast
            if otherLaunch != ownLaunch { return otherLaunch < ownLaunch }
            return other.pid < own.pid
        }
        .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}
