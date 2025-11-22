//
//  Stop.swift
//  osaurus
//
//  Command to stop the running Osaurus server via distributed notification.
//

import Foundation

public struct StopCommand: Command {
    public static let name = "stop"

    public static func execute(args: [String]) async {
        AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.stop", userInfo: [:])
        // Verify stopped within a short timeout
        let port = Configuration.resolveConfiguredPort() ?? 1337
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if !(await ServerControl.checkHealth(port: port)) {
                print("stopped")
                exit(EXIT_SUCCESS)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        fputs("Server did not stop in time\n", stderr)
        exit(EXIT_FAILURE)
    }
}
