//
//  UI.swift
//  osaurus
//
//  Command to show the Osaurus menu bar popover UI by sending a distributed notification to the app.
//

import Foundation

public struct UICommand: Command {
    public static let name = "ui"

    public static func execute(args: [String]) async {
        await AppControl.launchAppIfNeeded()
        let port = Configuration.resolveConfiguredPort() ?? 1337
        let start = Date()
        let deadline = start.addingTimeInterval(6.0)
        var lastPost = Date.distantPast
        var postedAtLeastOnce = false
        while Date() < deadline {
            // Once the server is healthy, (re)post a UI request to ensure it is handled
            if await ServerControl.checkHealth(port: port) {
                AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.ui", userInfo: [:])
                // Give the app a moment to show the popover, then exit
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(EXIT_SUCCESS)
            }
            // If still not healthy, periodically post the UI request as the app may not have registered observers yet
            if Date().timeIntervalSince(lastPost) > 0.8 {
                AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.ui", userInfo: [:])
                postedAtLeastOnce = true
                lastPost = Date()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Best-effort: post one final time and exit success
        if !postedAtLeastOnce {
            AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.ui", userInfo: [:])
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        exit(EXIT_SUCCESS)
    }
}
