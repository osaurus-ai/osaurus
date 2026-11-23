//
//  Status.swift
//  osaurus
//
//  Command to report whether the Osaurus server is answering. A running app
//  whose server does not answer is reported separately from a stopped one.
//

import Foundation

public struct StatusCommand: Command {
    public static let name = "status"

    static let usage = """
        Usage: osaurus status

        Prints `running (port N)`, `app running, server not answering (port N)` or `stopped`.
        Exits 0 only when the server answers.
        """

    static func describe(_ state: ServerState, port: Int) -> String {
        switch state {
        case .healthy: return "running (port \(port))"
        case .appRunningNotAnswering: return "app running, server not answering (port \(port))"
        case .appNotRunning: return "stopped"
        }
    }

    public static func execute(args: [String]) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        if let unknown = args.first {
            fputs("osaurus status: unknown argument `\(unknown)`\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let port = Configuration.resolveConfiguredPort() ?? 1337
        let state = await ServerControl.probe(port: port)
        print(describe(state, port: port))
        exit(state == .healthy ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
