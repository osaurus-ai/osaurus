//
//  AppControl.swift
//  osaurus
//
//  Service for controlling the Osaurus app via distributed notifications and launching it if needed.
//

import Foundation
import AppKit
import Darwin

public struct AppControl {
    /// Bundle identifier of the app this CLI drives.
    public static let appBundleIdentifier = "com.dinoki.osaurus"

    /// What the launch path should do for the app state it observed.
    public enum LaunchDecision: Equatable, Sendable {
        /// `/health` already answers; leave the running app alone.
        case serverHealthy
        /// An app process is up but its server has not answered yet. Poll it;
        /// never start a second instance.
        case waitForRunningApp
        /// No app process is up; start one.
        case launch
    }

    /// Decides whether to launch, wait, or do nothing.
    ///
    /// The order matters and is the fix for the duplicate-instance report: a
    /// running app process is enough reason to wait, even when `/health` is
    /// slow, because `open -n` would otherwise start another copy that never
    /// binds the port.
    public static func launchDecision(serverHealthy: Bool, appRunning: Bool) -> LaunchDecision {
        if serverHealthy { return .serverHealthy }
        if appRunning { return .waitForRunningApp }
        return .launch
    }

    public static func postDistributedNotification(name: String, userInfo: [AnyHashable: Any]) {
        // Use DistributedNotificationCenter to reach the app; restrict to local machine by default
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    @MainActor
    public static func launchAppIfNeeded() async {
        let port = Configuration.resolveConfiguredPort() ?? 1337
        let health = await ServerControl.checkHealth(port: port)
        switch launchDecision(serverHealthy: health, appRunning: isAppRunning()) {
        case .serverHealthy:
            return
        case .waitForRunningApp:
            // The app process is up while /health is still answering slowly
            // (DarkWake, busy model load, a swapped-out app). Wait it out
            // rather than launching a second copy that never binds the port.
            await waitForHealth(port: port)
            return
        case .launch:
            break
        }

        // Launch the app via `open -b` by bundle id, with fallback to explicit app path search.
        // `-n` is deliberately absent: it opens a new instance even when the app is already
        // running, which is the duplicate-instance bug this path has to avoid.
        var launched = false
        do {
            let openByBundle = Process()
            openByBundle.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openByBundle.arguments = ["-b", appBundleIdentifier, "--args", "--launched-by-cli"]
            try? openByBundle.run()
            openByBundle.waitUntilExit()
            launched = (openByBundle.terminationStatus == 0)
        }
        // Even if `open -b` returned success, verify the app process actually
        // came up (LaunchServices can fail to resolve the bundle id for some
        // setups) and only then fall back to an explicit-path launch. Checking
        // /health here instead would always fail on a cold start — the server
        // needs seconds to come up — so the fallback `open` fired every time,
        // and its reopen event made the running app pop the main window.
        var appIsRunning = false
        if launched {
            for _ in 0..<20 {  // up to ~2s
                if isAppRunning() {
                    appIsRunning = true
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if !launched || !appIsRunning {
            if let appPath = findAppBundlePath() {
                let openByPath = Process()
                openByPath.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                openByPath.arguments = ["-a", appPath, "--args", "--launched-by-cli"]
                try? openByPath.run()
                openByPath.waitUntilExit()
                launched = (openByPath.terminationStatus == 0)
            }
        }
        if !launched {
            fputs(
                "Could not launch Osaurus.app. Install it with Homebrew: brew install --cask osaurus\n",
                stderr
            )
            return
        }
        // Give the app a moment to initialize (cold start can take a bit)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// Whether an Osaurus app instance is already running.
    ///
    /// Reads the process list rather than `/health`: a running app whose server
    /// is slow to answer still must not be launched a second time.
    @MainActor
    public static func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).isEmpty
    }

    /// Polls `/health` until the already-running app answers or `timeout` elapses.
    ///
    /// Returns the last probe result so callers can report a genuinely stuck
    /// server instead of assuming the launch failed. Collaborators are
    /// injectable so the wait logic is unit-testable without a real server.
    @discardableResult
    public static func waitForHealth(
        port: Int,
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.25,
        healthCheck: @Sendable (Int) async -> Bool = { await ServerControl.checkHealth(port: $0) },
        sleep: @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var healthy = await healthCheck(port)
        while !healthy && Date() < deadline {
            await sleep(pollInterval)
            healthy = await healthCheck(port)
        }
        return healthy
    }

    /// Attempts to locate the installed Osaurus.app bundle path using common locations and Spotlight.
    @MainActor
    public static func findAppBundlePath() -> String? {
        let fm = FileManager.default
        for path in commonAppBundlePaths() where fm.fileExists(atPath: path) {
            return path
        }
        return findAppBundlePaths().first
    }

    /// Returns every known bundle for the Osaurus identifier. Multiple rows
    /// are significant because LaunchServices can otherwise launch a stale
    /// registration even when the CLI belongs to a newer app bundle.
    @MainActor
    public static func findAppBundlePaths(includeSpotlightSearch: Bool = true) -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = commonAppBundlePaths()
        var paths = candidates.filter { fm.fileExists(atPath: $0) }
        if let launchServicesSelection = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: appBundleIdentifier
        ) {
            paths.append(launchServicesSelection.path)
        }
        if includeSpotlightSearch {
            let query = "kMDItemCFBundleIdentifier == 'com.dinoki.osaurus'"
            paths.append(contentsOf: spotlightFindAll(queryArgs: ["-onlyin", "/Applications", query]))
            paths.append(contentsOf: spotlightFindAll(queryArgs: ["-onlyin", "\(home)/Applications", query]))
            // Preserve discovery of side-loaded and development bundles that
            // are indexed but not currently registered with LaunchServices.
            paths.append(contentsOf: spotlightFindAll(queryArgs: [query]))
        }
        return deduplicatedBundlePaths(paths.filter {
            fm.fileExists(atPath: $0) && URL(fileURLWithPath: $0).pathExtension.lowercased() == "app"
        })
    }

    private static func commonAppBundlePaths() -> [String] {
        [
            "/Applications/Osaurus.app",
            "\(NSHomeDirectory())/Applications/Osaurus.app",
            "/Applications/osaurus.app",
            "\(NSHomeDirectory())/Applications/osaurus.app",
        ]
    }

    static func deduplicatedBundlePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let canonical = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            // macOS application volumes are normally case-insensitive. Treat
            // spelling-only variants as one registration even on a test volume.
            guard seen.insert(canonical.lowercased()).inserted else { return nil }
            return canonical
        }
    }

    @MainActor
    public static func runningAppBundlePath() -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
            .first?.bundleURL?.path
    }

    /// Runs mdfind with the provided arguments and returns existing result paths.
    private static func spotlightFindAll(queryArgs: [String]) -> [String] {
        let mdfind = Process()
        let outPipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        mdfind.standardOutput = outPipe
        mdfind.standardError = FileHandle.nullDevice
        mdfind.arguments = queryArgs
        mdfind.terminationHandler = { _ in finished.signal() }
        do {
            try mdfind.run()
            guard finished.wait(timeout: .now() + 2) == .success else {
                mdfind.terminate()
                if finished.wait(timeout: .now() + 0.5) == .timedOut {
                    Darwin.kill(mdfind.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 1)
                }
                mdfind.waitUntilExit()
                return []
            }
            if mdfind.terminationStatus == 0 {
                let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
                if let s = String(data: data, encoding: .utf8) {
                    return s.split(separator: "\n").map(String.init)
                }
            }
        } catch {
            // ignore failures; fallback will be nil
        }
        return []
    }
}
