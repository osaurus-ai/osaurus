//
//  PluginsCommand.swift
//  osaurus
//
//  Main command router for plugins subcommands (list, install, verify, search, outdated, upgrade, rollback).
//

import Foundation
import OsaurusRepository

public struct PluginsCommand: Command {
    public static let name = "plugins"

    public static func execute(args: [String]) async {
        guard let sub = args.first else {
            fputs(
                "Missing plugins subcommand. Use one of: list, install, verify, search, outdated, upgrade, rollback\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            PluginsList.execute(args: rest)
        case "install":
            await PluginsInstall.execute(args: rest)
        case "verify":
            PluginsVerify.execute(args: rest)
        case "search":
            PluginsSearch.execute(args: rest)
        case "outdated":
            PluginsOutdated.execute(args: rest)
        case "upgrade":
            await PluginsUpgrade.execute(args: rest)
        case "rollback":
            PluginsRollback.execute(args: rest)
        default:
            fputs("Unknown plugins subcommand: \(sub)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
