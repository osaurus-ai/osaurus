//
//  OsaurusCLI.swift
//  osaurus
//
//  Main entry point for the Osaurus CLI. Parses command-line arguments and routes to appropriate command handlers.
//

import Foundation
import OsaurusCLICore

@main
struct OsaurusCLI {
    private enum CommandType {
        case status
        case serve([String])
        case stop
        case list
        case run(String)
        case mcp
        case ui
        case tools([String])
        case plugins([String])
        case version
        case help
    }

    private static func parseCommand(_ args: ArraySlice<String>) -> CommandType? {
        guard let command = args.first else { return nil }
        let rest = Array(args.dropFirst())
        switch command {
        case "status": return .status
        case "serve": return .serve(rest)
        case "stop": return .stop
        case "list": return .list
        case "run":
            if let modelId = rest.first, !modelId.isEmpty { return .run(modelId) }
            return nil
        case "mcp": return .mcp
        case "ui": return .ui
        case "tools": return .tools(rest)
        case "plugins": return .plugins(rest)
        case "version", "--version", "-v": return .version
        case "help", "-h", "--help": return .help
        default: return nil
        }
    }

    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        guard let cmd = parseCommand(arguments) else {
            if let first = arguments.first { fputs("Unknown or invalid command: \(first)\n\n", stderr) }
            printUsage()
            exit(EXIT_FAILURE)
        }

        switch cmd {
        case .status:
            await StatusCommand.execute(args: [])
        case .serve(let args):
            await ServeCommand.execute(args: args)
        case .stop:
            await StopCommand.execute(args: [])
        case .list:
            await ListCommand.execute(args: [])
        case .run(let modelId):
            await RunCommand.execute(args: [modelId])
        case .mcp:
            await MCPCommand.execute(args: [])
        case .ui:
            await UICommand.execute(args: [])
        case .tools(let args):
            await ToolsCommand.execute(args: args)
        case .plugins(let args):
            await PluginsCommand.execute(args: args)
        case .version:
            await VersionCommand.execute(args: [])
        case .help:
            printUsage()
            exit(EXIT_SUCCESS)
        }
    }

    private static func printUsage() {
        let usage = """
            osaurus - CLI for Osaurus

            Usage:
              osaurus serve [--port N] [--expose] [--yes|-y]
                                      Start the server (default: localhost only). If --expose
                                      is set, a warning prompt will appear unless --yes is provided.
              osaurus stop            Stop the server
              osaurus mcp             Run MCP stdio server proxying to local HTTP
              osaurus version         Show version (also: --version or -v)
              osaurus status          Check if the Osaurus server is running
              osaurus list            List available model IDs
              osaurus run <model_id>  Chat with a downloaded model (interactive)
              osaurus ui              Show the Osaurus menu popover in the menu bar
              osaurus tools create <name> [--language swift|rust]
                                      Scaffold a plugin project
              osaurus tools package   Build and zip the current plugin (requires manifest.json)
              osaurus tools install <url-or-path>
                                      Install a plugin zip or unpacked directory
              osaurus tools list      List installed plugins
              osaurus tools reload    Ask the app to rescan plugins
              osaurus plugins list    List installed plugins (versioned)
              osaurus plugins install <plugin_id> [--version <semver>]
                                     Install a plugin from configured taps
              osaurus plugins verify [<plugin_id>]
                                     Re-verify installed plugin(s)
              osaurus help            Show this help

            """
        print(usage)
    }
}
