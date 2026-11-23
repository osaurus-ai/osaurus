//
//  Stop.swift
//  osaurus
//
//  Command to stop the running Osaurus server via distributed notification.
//

import Foundation

public struct StopCommand: Command {
    public static let name = "stop"

    static let usage = """
        Usage: osaurus stop

        Stops the Osaurus server. The app keeps running.
        """

    public static func execute(args: [String]) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        if let unknown = args.first {
            fputs("osaurus stop: unknown argument `\(unknown)`\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let port = Configuration.resolveConfiguredPort() ?? 1337
        if await ServerControl.probe(port: port) == .appNotRunning {
            print("stopped")
            exit(EXIT_SUCCESS)
        }
        AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.stop", userInfo: [:])
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !(await ServerControl.checkHealth(port: port, timeout: 1.0)) {
                print("stopped")
                exit(EXIT_SUCCESS)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        fputs("Server did not stop in time\n", stderr)
        exit(EXIT_FAILURE)
    }
}
