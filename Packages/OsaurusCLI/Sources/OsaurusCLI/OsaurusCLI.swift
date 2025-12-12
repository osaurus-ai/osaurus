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
        case show(String)
        case run(String)
        case mcp
        case ui
        case tools([String])
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
        case "show":
            if let modelId = rest.first, !modelId.isEmpty { return .show(modelId) }
            return nil
        case "run":
            if let modelId = rest.first, !modelId.isEmpty { return .run(modelId) }
            return nil
        case "mcp": return .mcp
        case "ui": return .ui
        case "tools": return .tools(rest)
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
        case .show(let modelId):
            await ShowCommand.execute(args: [modelId])
        case .run(let modelId):
            await RunCommand.execute(args: [modelId])
        case .mcp:
            await MCPCommand.execute(args: [])
        case .ui:
            await UICommand.execute(args: [])
        case .tools(let args):
            await ToolsCommand.execute(args: args)
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
              osaurus show <model_id> Show metadata for a model
              osaurus run <model_id>  Chat with a downloaded model (interactive)
              osaurus ui              Show the Osaurus menu popover in the menu bar
              osaurus tools list      List installed tools
              osaurus tools install <plugin_id|url-or-path>
                                      Install a tool from registry or local/URL
              osaurus tools search <query>
                                      Search for tools in the registry
              osaurus tools outdated  Check for outdated tools
              osaurus tools upgrade   Upgrade installed tools
              osaurus tools uninstall <tool_name>
                                      Uninstall a tool
              osaurus tools verify    Verify installed tools
              osaurus tools create <name> [--language swift|rust]
                                      Scaffold a tool project
              osaurus tools package   Build and zip the current tool
              osaurus tools reload    Ask the app to rescan tools
              osaurus help            Show this help

            """
        print(usage)
    }
}
