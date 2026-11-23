//
//  UI.swift
//  osaurus
//
//  Command to show the Osaurus menu bar popover UI by sending a distributed notification to the app.
//

import Foundation

public struct UICommand: Command {
    public static let name = "ui"

    static let usage = """
        Usage: osaurus ui

        Opens the Osaurus menu bar window, launching the app if it is not running.
        """

    static let uiNotification = "com.dinoki.osaurus.control.ui"

    public static func execute(args: [String]) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        if let unknown = args.first {
            fputs("osaurus ui: unknown argument `\(unknown)`\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let port = Configuration.resolveConfiguredPort() ?? 1337
        let state = await AppControl.launchAppIfNeeded(port: port)
        if state != .appNotRunning {
            // Already running: the observers are registered, one post is enough.
            AppControl.postDistributedNotification(name: uiNotification, userInfo: [:])
            try? await Task.sleep(nanoseconds: 150_000_000)
            exit(EXIT_SUCCESS)
        }
        // Cold start: the app may not have registered its observers yet, so
        // post periodically until the server answers, then once more.
        let deadline = Date().addingTimeInterval(10.0)
        var lastPost = Date.distantPast
        while Date() < deadline {
            if await ServerControl.checkHealth(port: port, timeout: 1.0) {
                AppControl.postDistributedNotification(name: uiNotification, userInfo: [:])
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(EXIT_SUCCESS)
            }
            if Date().timeIntervalSince(lastPost) > 0.8 {
                AppControl.postDistributedNotification(name: uiNotification, userInfo: [:])
                lastPost = Date()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        AppControl.postDistributedNotification(name: uiNotification, userInfo: [:])
        try? await Task.sleep(nanoseconds: 150_000_000)
        exit(EXIT_SUCCESS)
    }
}
