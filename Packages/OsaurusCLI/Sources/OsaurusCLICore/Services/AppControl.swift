//
//  AppControl.swift
//  osaurus
//
//  Service for controlling the Osaurus app via distributed notifications and launching it if needed.
//

import Foundation
import AppKit

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
    private static func findAppBundlePath() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/Osaurus.app",
            "\(home)/Applications/Osaurus.app",
            "/Applications/osaurus.app",
            "\(home)/Applications/osaurus.app",
        ]
        for c in candidates {
            if fm.fileExists(atPath: c) { return c }
        }
        // Try Spotlight via mdfind, restricted to Applications folders first
        if let path = spotlightFind(queryArgs: [
            "-onlyin", "/Applications",
            "-onlyin", "\(home)/Applications",
            "kMDItemCFBundleIdentifier == 'com.dinoki.osaurus'",
        ]) {
            if fm.fileExists(atPath: path) { return path }
        }
        // Unrestricted Spotlight fallback (search entire metadata index)
        if let path = spotlightFind(queryArgs: [
            "kMDItemCFBundleIdentifier == 'com.dinoki.osaurus'"
        ]) {
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Runs mdfind with the provided arguments and returns the first non-empty line.
    private static func spotlightFind(queryArgs: [String]) -> String? {
        let mdfind = Process()
        let outPipe = Pipe()
        mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        mdfind.standardOutput = outPipe
        mdfind.arguments = queryArgs
        do {
            try mdfind.run()
            mdfind.waitUntilExit()
            if mdfind.terminationStatus == 0 {
                let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
                if let s = String(data: data, encoding: .utf8) {
                    if let first = s.split(separator: "\n").first, !first.isEmpty {
                        return String(first)
                    }
                }
            }
        } catch {
            // ignore failures; fallback will be nil
        }
        return nil
    }
}
