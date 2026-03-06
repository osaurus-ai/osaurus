//
//  main.swift
//  osaurus-host
//
//  CLI shim that runs inside agent VMs. Translates subcommands into JSON-RPC
//  calls over vsock to the Osaurus runtime on the host.
//
//  Usage:
//    osaurus-host secrets get <name>
//    osaurus-host config get <key>
//    osaurus-host config set <key> <value>
//    osaurus-host log info|warn|error <message>
//    osaurus-host inference chat              (reads JSON from stdin)
//    osaurus-host agent dispatch <agent> <task>
//    osaurus-host agent memory query <query>
//    osaurus-host agent memory store <content>
//    osaurus-host events emit <type> [payload]
//    osaurus-host plugin create               (reads JSON from stdin)
//    osaurus-host plugin list
//    osaurus-host plugin remove <name>
//    osaurus-host identity address
//    osaurus-host identity sign <data_hex>
//

import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let client = VsockClient()

do {
    try client.connect()
    defer { client.disconnect() }

    let command = args[1]
    switch command {
    case "secrets":
        try handleSecrets(args: Array(args.dropFirst(2)), client: client)
    case "config":
        try handleConfig(args: Array(args.dropFirst(2)), client: client)
    case "log":
        try handleLog(args: Array(args.dropFirst(2)), client: client)
    case "inference":
        try handleInference(args: Array(args.dropFirst(2)), client: client)
    case "agent":
        try handleAgent(args: Array(args.dropFirst(2)), client: client)
    case "events":
        try handleEvents(args: Array(args.dropFirst(2)), client: client)
    case "plugin":
        try handlePlugin(args: Array(args.dropFirst(2)), client: client)
    case "identity":
        try handleIdentity(args: Array(args.dropFirst(2)), client: client)
    case "mcp":
        try handleMCP(args: Array(args.dropFirst(2)))
    default:
        fputs("Unknown command: \(command)\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}

// MARK: - Command Handlers

func handleSecrets(args: [String], client: VsockClient) throws {
    guard args.count >= 2, args[0] == "get" else {
        throw ShimError.missingArgument("Usage: osaurus-host secrets get <name>")
    }
    let pluginName = ProcessInfo.processInfo.environment["OSAURUS_PLUGIN"] ?? "unknown"
    let result = try client.call(method: "secrets.get", params: ["name": args[1], "plugin": pluginName])
    if let value = result["value"] as? String {
        print(value)
    }
}

func handleConfig(args: [String], client: VsockClient) throws {
    guard !args.isEmpty else { throw ShimError.missingArgument("Usage: osaurus-host config get|set <key> [value]") }
    let pluginName = ProcessInfo.processInfo.environment["OSAURUS_PLUGIN"] ?? "unknown"

    switch args[0] {
    case "get":
        guard args.count >= 2 else { throw ShimError.missingArgument("config get <key>") }
        let result = try client.call(method: "config.get", params: ["key": args[1], "plugin": pluginName])
        if let value = result["value"] as? String { print(value) }
    case "set":
        guard args.count >= 3 else { throw ShimError.missingArgument("config set <key> <value>") }
        _ = try client.call(method: "config.set", params: ["key": args[1], "value": args[2], "plugin": pluginName])
    default:
        throw ShimError.missingArgument("config get|set")
    }
}

func handleLog(args: [String], client: VsockClient) throws {
    guard args.count >= 2 else { throw ShimError.missingArgument("log info|warn|error <message>") }
    let level = args[0]
    let message = args.dropFirst().joined(separator: " ")
    _ = try client.call(method: "log", params: ["level": level, "message": message])
}

func handleInference(args: [String], client: VsockClient) throws {
    guard !args.isEmpty, args[0] == "chat" else { throw ShimError.missingArgument("inference chat") }
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
        throw ShimError.missingArgument("Expected JSON on stdin for inference chat")
    }
    let result = try client.call(method: "inference.chat", params: json)
    if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func handleAgent(args: [String], client: VsockClient) throws {
    guard !args.isEmpty else { throw ShimError.missingArgument("agent dispatch|memory") }

    switch args[0] {
    case "dispatch":
        guard args.count >= 3 else { throw ShimError.missingArgument("agent dispatch <agent> <task>") }
        let result = try client.call(method: "agent.dispatch", params: ["agent": args[1], "task": args[2]])
        printJSON(result)
    case "memory":
        guard args.count >= 2 else { throw ShimError.missingArgument("agent memory query|store") }
        switch args[1] {
        case "query":
            guard args.count >= 3 else { throw ShimError.missingArgument("agent memory query <query>") }
            let result = try client.call(method: "memory.query", params: ["query": args[2]])
            printJSON(result)
        case "store":
            guard args.count >= 3 else { throw ShimError.missingArgument("agent memory store <content>") }
            let result = try client.call(method: "memory.store", params: ["content": args[2]])
            printJSON(result)
        default:
            throw ShimError.missingArgument("agent memory query|store")
        }
    default:
        throw ShimError.missingArgument("agent dispatch|memory")
    }
}

func handleEvents(args: [String], client: VsockClient) throws {
    guard !args.isEmpty else { throw ShimError.missingArgument("events emit <type> [payload]") }

    switch args[0] {
    case "emit":
        guard args.count >= 2 else { throw ShimError.missingArgument("events emit <type> [payload]") }
        let payload = args.count >= 3 ? args[2] : "{}"
        _ = try client.call(method: "events.emit", params: ["event_type": args[1], "payload": payload])
    default:
        throw ShimError.missingArgument("events emit")
    }
}

func handlePlugin(args: [String], client: VsockClient) throws {
    guard !args.isEmpty else { throw ShimError.missingArgument("plugin create|list|remove") }

    switch args[0] {
    case "create":
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: stdinData) else {
            throw ShimError.missingArgument("Expected JSON on stdin for plugin create")
        }
        let result = try client.call(method: "plugin.create", params: ["plugin": json])
        printJSON(result)
    case "list":
        let result = try client.call(method: "plugin.list")
        printJSON(result)
    case "remove":
        guard args.count >= 2 else { throw ShimError.missingArgument("plugin remove <name>") }
        let result = try client.call(method: "plugin.remove", params: ["name": args[1]])
        printJSON(result)
    default:
        throw ShimError.missingArgument("plugin create|list|remove")
    }
}

func handleIdentity(args: [String], client: VsockClient) throws {
    guard !args.isEmpty else { throw ShimError.missingArgument("identity address|sign") }

    switch args[0] {
    case "address":
        let result = try client.call(method: "identity.address")
        if let address = result["address"] as? String { print(address) }
    case "sign":
        guard args.count >= 2 else { throw ShimError.missingArgument("identity sign <data_hex>") }
        let result = try client.call(method: "identity.sign", params: ["data": args[1]])
        printJSON(result)
    default:
        throw ShimError.missingArgument("identity address|sign")
    }
}

func handleMCP(args: [String]) throws {
    guard args.count >= 2, args[0] == "relay" else {
        throw ShimError.missingArgument("Usage: osaurus-host mcp relay <plugin-name>")
    }
    let pluginName = args[1]

    // Read a JSON-RPC request from stdin and relay it to the MCP server process.
    // The MCP server is expected to be a long-running stdio process in
    // /workspace/plugins/<plugin-name>/. This stub reads stdin, pipes it to the
    // MCP server's stdin, and writes the server's stdout response back out.
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    guard !stdinData.isEmpty else {
        throw ShimError.missingArgument("Expected JSON-RPC request on stdin")
    }

    let mcpCommand = ProcessInfo.processInfo.environment["MCP_COMMAND"] ?? ""
    guard !mcpCommand.isEmpty else {
        fputs("MCP_COMMAND env var not set for plugin \(pluginName)\n", stderr)
        throw ShimError.missingArgument("MCP_COMMAND not set")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", mcpCommand]
    process.currentDirectoryURL = URL(fileURLWithPath: "/workspace/plugins/\(pluginName)")

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.standardError

    try process.run()
    inputPipe.fileHandleForWriting.write(stdinData)
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: outputData, encoding: .utf8) {
        print(output, terminator: "")
    }
}

// MARK: - Helpers

func printJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func printUsage() {
    let usage = """
    osaurus-host - VM shim for Osaurus Host API

    Usage:
      osaurus-host secrets get <name>
      osaurus-host config get|set <key> [value]
      osaurus-host log info|warn|error <message>
      osaurus-host inference chat                 (reads JSON from stdin)
      osaurus-host agent dispatch <agent> <task>
      osaurus-host agent memory query|store <content>
      osaurus-host events emit <type> [payload]
      osaurus-host plugin create|list|remove [name]
      osaurus-host identity address|sign [data_hex]
      osaurus-host mcp relay <plugin-name>           (reads JSON-RPC from stdin)
    """
    fputs(usage, stderr)
}
