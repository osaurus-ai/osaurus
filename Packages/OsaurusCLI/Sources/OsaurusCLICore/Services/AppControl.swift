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

    @MainActor
    public static func launchAppIfNeeded() async {
        // Try to detect if server responds; if yes, nothing to do
        let port = Configuration.resolveConfiguredPort() ?? 1337
        if await ServerControl.checkHealth(port: port) { return }

        // Launch the app via `open -b` by bundle id, with fallback to explicit app path search
        var launched = false
        do {
            let openByBundle = Process()
            openByBundle.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openByBundle.arguments = ["-n", "-b", "com.dinoki.osaurus", "--args", "--launched-by-cli"]
            try? openByBundle.run()
            openByBundle.waitUntilExit()
            launched = (openByBundle.terminationStatus == 0)
        }
        // Even if `open -b` returned success, do a quick health-based fallback attempt
        // in case LaunchServices couldn't resolve the bundle id for some setups.
        let healthyAfterBundle = await ServerControl.checkHealth(port: port)
        if !launched || !healthyAfterBundle {
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
            withBundleIdentifier: "com.dinoki.osaurus"
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
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.dinoki.osaurus")
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
