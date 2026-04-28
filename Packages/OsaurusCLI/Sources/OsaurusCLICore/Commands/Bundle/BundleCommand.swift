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
        guard let sub = args.first else {
            fputs(
                "Отсутствует подкоманда bundle. Используйте одну из: load\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "load":
            await BundleLoad.execute(args: rest)
        default:
            fputs("Неизвестная подкоманда bundle: \(sub)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
