//
//  ToolsCommand.swift
//  osaurus
//
//  Main command router for tools subcommands (create, package, install, list, uninstall, reload).
//

import Foundation

public struct ToolsCommand: Command {
    public static let name = "tools"

    public static func execute(args: [String]) async {
        guard let sub = args.first else {
            fputs(
                "Missing tools subcommand. Use one of: create, package, install, list, uninstall, reload, search, outdated, upgrade, rollback, verify\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "create":
            ToolsCreate.execute(args: rest)
        case "package":
            ToolsPackage.execute(args: rest)
        case "install":
            await ToolsInstall.execute(args: rest)
        case "list":
            ToolsList.execute(args: rest)
        case "uninstall":
            ToolsUninstall.execute(args: rest)
        case "reload":
            ToolsReload.execute(args: rest)
        case "search":
            ToolsSearch.execute(args: rest)
        case "outdated":
            ToolsOutdated.execute(args: rest)
        case "upgrade":
            await ToolsUpgrade.execute(args: rest)
        case "rollback":
            ToolsRollback.execute(args: rest)
        case "verify":
            ToolsVerify.execute(args: rest)
        default:
            fputs("Unknown tools subcommand: \(sub)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
