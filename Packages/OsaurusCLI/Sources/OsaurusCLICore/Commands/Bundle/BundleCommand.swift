//
//  BundleCommand.swift
//  osaurus
//
//  Main command router for MCPB (MCP Bundle) subcommands.
//

import Foundation

public struct BundleCommand: Command {
    public static let name = "bundle"

    public static func execute(args: [String]) async {
        fputs("osaurus bundle is experimental and may change or be removed.\n", stderr)
        guard let sub = args.first else {
            fputs(
                "Missing bundle subcommand. Use one of: load\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "load":
            await BundleLoad.execute(args: rest)
        default:
            fputs("Unknown bundle subcommand: \(sub)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
