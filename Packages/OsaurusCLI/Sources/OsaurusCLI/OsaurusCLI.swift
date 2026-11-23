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
        case status, doctor, serve, stop, list, show, run, pull, bench, mcp, ui
        case bundle, coord, config, importCmd, version, workflow, agent
        case removed(String)
        case help
    }

    private static func parseCommand(_ command: String) -> CommandType? {
        switch command {
        case "status": return .status
        case "doctor": return .doctor
        case "serve": return .serve
        case "stop": return .stop
        case "list": return .list
        case "show": return .show
        case "run": return .run
        case "pull": return .pull
        case "bench": return .bench
        case "mcp": return .mcp
        case "ui": return .ui
        case "tools", "manifest": return .removed(command)
        case "bundle": return .bundle
        case "coord": return .coord
        case "config": return .config
        case "import": return .importCmd
        case "workflow", "workflows": return .workflow
        case "agent", "agents": return .agent
        case "version", "--version", "-v": return .version
        case "help", "-h", "--help": return .help
        default: return nil
        }
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let first = arguments.first, let cmd = parseCommand(first) else {
            if let first = arguments.first { fputs("Unknown command: \(first)\n\n", stderr) }
            printUsage()
            exit(EXIT_FAILURE)
        }
        let args = Array(arguments.dropFirst())

        switch cmd {
        case .status: await StatusCommand.execute(args: args)
        case .doctor: await DoctorCommand.execute(args: args)
        case .serve: await ServeCommand.execute(args: args)
        case .stop: await StopCommand.execute(args: args)
        case .list: await ListCommand.execute(args: args)
        case .show: await ShowCommand.execute(args: args)
        case .run: await RunCommand.execute(args: args)
        case .pull: await PullCommand.execute(args: args)
        case .bench: await BenchCommand.execute(args: args)
        case .mcp: await MCPCommand.execute(args: args)
        case .ui: await UICommand.execute(args: args)
        case .removed(let command):
            fputs("osaurus \(command): plugin commands were removed; Osaurus no longer supports plugins.\n", stderr)
            exit(EXIT_FAILURE)
        case .bundle: await BundleCommand.execute(args: args)
        case .coord: await CoordCommand.execute(args: args)
        case .config: await ConfigCommand.execute(args: args)
        case .importCmd: await ImportCommand.execute(args: args)
        case .version: await VersionCommand.execute(args: args)
        case .workflow: await WorkflowCommand.execute(args: args)
        case .agent: await AgentCommand.execute(args: args)
        case .help:
            printUsage()
            exit(EXIT_SUCCESS)
        }
    }

    private static func printUsage() {
        let usage = """
            osaurus - CLI for Osaurus

            Usage:
              osaurus serve [--port N] [--expose | --no-expose] [--yes|-y] [--supervise] [--interval N]
                                      Start the server. Exposure stays as saved in Settings
                                      unless --expose (LAN, asks to confirm unless --yes) or
                                      --no-expose (this Mac only) is given. --supervise keeps
                                      it running (probe every --interval seconds, default 15),
                                      for a launchd KeepAlive LaunchAgent.
              osaurus stop            Stop the server
              osaurus status          Check if the Osaurus server is running
              osaurus ui              Show the Osaurus menu popover in the menu bar
              osaurus doctor [--port N] [--json] [--redact] [--verify-signatures]
                                      Diagnose CLI/app version skew, duplicate app bundles
                                      and running copies, server startup and model storage
              osaurus version         Show version (also: --version or -v)

            Models:
              osaurus list            List available model IDs
              osaurus show <model_id> Show metadata for a model
              osaurus pull <model_id> Download a model from Hugging Face (HF_TOKEN for gated models)
              osaurus run <model_id>  Chat with a model (interactive)
              osaurus bench [--model <id>] [--prompt-tokens 1024,8192] [--runs 3] [--json <path>]
                                      Benchmark TTFT / prefill / decode against the server

            Agents and workflows:
              osaurus agent list      List your agents
              osaurus agent run <name|id|default> [-p PROMPT] [--session ID] [--json]
                                      Run an agent headlessly; piped stdin is added to the prompt
              osaurus workflow list   List workflows
              osaurus workflow run <name|id> [--input key=value ...] [--no-wait] [--json]
                                      Run a workflow; forms are answered in the terminal
              osaurus workflow status|runs|cancel
                                      Inspect or cancel workflow runs

            MCP:
              osaurus mcp [--tools PATTERNS] [--workflows PATTERNS]
                                      Run an MCP stdio server proxying Osaurus tools (and
                                      workflows) to another AI app
              osaurus mcp install --client cursor|claude-code|claude-desktop|codex
                                      Add Osaurus to an MCP client's config (also: uninstall)

            Configuration:
              osaurus config export|schema|plan|apply
                                      Export, inspect, dry-run or apply a declarative YAML
                                      configuration (see `osaurus config help`)
              osaurus import validate|install|update|remove|list
                                      Install agents, skills and MCP servers from an Osaurus
                                      bundle folder (see `osaurus import help`)

            Access: when Expose to Network or Require Access Key for Local Admin
            Routes is on, the first command run in Terminal asks you to allow it in
            Osaurus. Scripts can pass --access-key KEY or set OSAURUS_API_KEY.

            Run `osaurus <command> --help` for a command's options.
            Bundle author guide: docs/OSAURUS_BUNDLES.md
            """
        print(usage)
    }
}
