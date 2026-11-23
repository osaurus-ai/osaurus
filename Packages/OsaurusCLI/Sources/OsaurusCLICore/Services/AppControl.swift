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
    public static func postDistributedNotification(name: String, userInfo: [AnyHashable: Any]) {
        // Use DistributedNotificationCenter to reach the app; restrict to local machine by default
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    /// Probes the server and launches the app only when it is not running.
    /// Returns the probe result from before any launch, so callers know
    /// whether to wait for a cold start or for a busy app.
    @MainActor
    @discardableResult
    public static func launchAppIfNeeded(
        port: Int = Configuration.resolveConfiguredPort() ?? 1337
    ) async -> ServerState {
        let state = await ServerControl.probe(port: port)
        guard state == .appNotRunning else { return state }
        await launchApp()
        return state
    }

    /// Launches the app without `-n`, so LaunchServices reuses a copy that
    /// started in the meantime instead of opening a second one.
    @MainActor
    static func launchApp() async {
        let bundleId = AppIdentity.bundleIdentifier
        var launched = runOpen(["-b", bundleId, "--args", "--launched-by-cli"])
        // `open -b` can succeed without starting anything when LaunchServices
        // cannot resolve the id; confirm the process exists before falling
        // back to an explicit path. Waiting for /health here instead would
        // always time out on a cold start.
        if launched { launched = await waitForAppProcess(seconds: 2) }
        if !launched, let appPath = findAppBundlePath() {
            launched = runOpen(["-a", appPath, "--args", "--launched-by-cli"])
            if launched { launched = await waitForAppProcess(seconds: 2) }
        }
        if !launched {
            fputs(
                "Could not launch Osaurus.app. Install it with Homebrew: brew install --cask osaurus\n",
                stderr
            )
        }
    }

    private static func runOpen(_ arguments: [String]) -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
        } catch {
            return false
        }
        open.waitUntilExit()
        return open.terminationStatus == 0
    }

    private static func waitForAppProcess(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if ServerControl.isAppRunning() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return false
    }

    /// Attempts to locate the installed Osaurus.app bundle path using common locations and Spotlight.
    @MainActor
    public static func findAppBundlePath() -> String? {
        let bundleId = AppIdentity.bundleIdentifier
        if let companion = CLIVersionResolver.companionAppPath(for: CommandLine.arguments.first ?? ""),
            AppIdentity.bundleIdentifier(ofAppAt: companion) == bundleId
        {
            return companion
        }
        for path in commonAppBundlePaths() where AppIdentity.bundleIdentifier(ofAppAt: path) == bundleId {
            return path
        }
        return findAppBundlePaths().first
    }

    /// Every running process of this app. More than one means a duplicate
    /// launch slipped past the app's own guard.
    public static func runningInstances() -> [(pid: Int32, path: String?)] {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
            .filter { !$0.isTerminated }
            .map { ($0.processIdentifier, $0.bundleURL?.path) }
    }

    /// Returns every known bundle for the Osaurus identifier. Multiple rows
    /// are significant because LaunchServices can otherwise launch a stale
    /// registration even when the CLI belongs to a newer app bundle.
    @MainActor
    public static func findAppBundlePaths(includeSpotlightSearch: Bool = true) -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = commonAppBundlePaths()
        var paths = candidates.filter { AppIdentity.bundleIdentifier(ofAppAt: $0) == AppIdentity.bundleIdentifier }
        if let launchServicesSelection = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: AppIdentity.bundleIdentifier
        ) {
            paths.append(launchServicesSelection.path)
        }
        if includeSpotlightSearch {
            let query = "kMDItemCFBundleIdentifier == '\(AppIdentity.bundleIdentifier)'"
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
            "/Applications/Osaurus Beta.app",
            "\(NSHomeDirectory())/Applications/Osaurus Beta.app",
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
        NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
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
