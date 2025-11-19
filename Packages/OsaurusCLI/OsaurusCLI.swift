//
//  OsaurusCLI.swift
//  osaurus
//
//  Created by Terence on 9/26/25.
//

import Foundation
import MCP

@main
struct OsaurusCLI {
    private enum Command {
        case status
        case serve([String])
        case stop
        case list
        case run(String)
        case mcp
        case ui
        case version
        case help
    }

    private static func parseCommand(_ args: ArraySlice<String>) -> Command? {
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
            await runStatus()
        case .serve(let args):
            await runServe(args)
        case .stop:
            await runStop()
        case .list:
            await runList()
        case .run(let modelId):
            await runRun([modelId])
        case .mcp:
            await runMCP()
        case .ui:
            await runUI()
        case .version:
            runVersion()
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
              osaurus help            Show this help

            """
        print(usage)
    }

    // MARK: - Version
    private static func runVersion() {
        let invokedPath = CommandLine.arguments.first ?? ""
        var versionString: String?
        var buildString: String?

        // Try: If running inside an app bundle (Contents/Helpers or Contents/MacOS)
        do {
            let execURL = URL(fileURLWithPath: invokedPath)
            let contentsURL = execURL.deletingLastPathComponent().deletingLastPathComponent()
            if contentsURL.lastPathComponent == "Contents" {
                let infoURL = contentsURL.appendingPathComponent("Info.plist")
                if FileManager.default.fileExists(atPath: infoURL.path) {
                    let data = try Data(contentsOf: infoURL)
                    var format = PropertyListSerialization.PropertyListFormat.xml
                    if let plist = try PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: &format
                    ) as? [String: Any] {
                        if let v = plist["CFBundleShortVersionString"] as? String { versionString = v }
                        if let b = plist["CFBundleVersion"] as? String { buildString = b }
                    }
                }
            }
        } catch {
            // ignore
        }

        // Fallback to Bundle.main (may be empty for SPM executables)
        if versionString == nil {
            let info = Bundle.main.infoDictionary ?? [:]
            if let v = info["CFBundleShortVersionString"] as? String { versionString = v }
            if let b = info["CFBundleVersion"] as? String { buildString = b }
        }

        let output: String
        if let v = versionString, let b = buildString, !b.isEmpty {
            output = "Osaurus \(v) (\(b))"
        } else if let v = versionString {
            output = "Osaurus \(v)"
        } else {
            output = "Osaurus dev"
        }
        print(output)
        exit(EXIT_SUCCESS)
    }

    private static func resolveConfiguredPort() -> Int? {
        // Allow override for testing
        if let env = ProcessInfo.processInfo.environment["OSU_PORT"], let p = Int(env) {
            return p
        }

        // Read the same configuration the app persists
        // ~/Library/Application Support/com.dinoki.osaurus/ServerConfiguration.json
        let fm = FileManager.default
        guard let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        let configURL =
            supportDir
            .appendingPathComponent("com.dinoki.osaurus", isDirectory: true)
            .appendingPathComponent("ServerConfiguration.json")

        guard fm.fileExists(atPath: configURL.path) else { return nil }

        struct PartialConfig: Decodable { let port: Int? }
        do {
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(PartialConfig.self, from: data)
            return cfg.port
        } catch {
            return nil
        }
    }

    private static func runStatus() async {
        let port = resolveConfiguredPort() ?? 1337

        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            fputs("Invalid URL for health check\n", stderr)
            exit(EXIT_FAILURE)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.6

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                print("running (port \(port))")
                exit(EXIT_SUCCESS)
            } else {
                print("stopped")
                exit(EXIT_FAILURE)
            }
        } catch {
            print("stopped")
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Serve
    private static func runServe(_ args: [String]) async {
        // Parse optional --port argument
        var desiredPort: Int? = nil
        var expose: Bool = false
        var assumeYes: Bool = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--port", i + 1 < args.count {
                if let p = Int(args[i + 1]), (1 ..< 65536).contains(p) { desiredPort = p }
                i += 2
                continue
            } else if a == "--expose" {
                expose = true
                i += 1
                continue
            } else if a == "--yes" || a == "-y" {
                assumeYes = true
                i += 1
                continue
            }
            i += 1
        }

        if expose && !assumeYes {
            // Security warning prompt
            let warning = """
                WARNING: Exposing Osaurus to the local network will allow other devices on your LAN
                to connect to your server. Make sure you trust your network and understand the risks.
                Proceed with exposure? [y/N]: 
                """
            fputs(warning, stderr)
            fflush(stderr)
            if let line = readLine(strippingNewline: true) {
                let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if answer != "y" && answer != "yes" {
                    fputs("aborted\n", stderr)
                    exit(EXIT_FAILURE)
                }
            } else {
                fputs("aborted\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        // Launch the app if not running, then post local-only distributed notification to start
        await launchAppIfNeeded()
        let buildInfo: () -> [AnyHashable: Any] = {
            var info: [AnyHashable: Any] = [:]
            if let p = desiredPort { info["port"] = p }
            if expose { info["expose"] = true }
            return info
        }
        postDistributedNotification(
            name: "com.dinoki.osaurus.control.serve",
            userInfo: buildInfo()
        )

        // Poll health until running or timeout
        let portToCheck = desiredPort ?? (resolveConfiguredPort() ?? 1337)
        let start = Date()
        let deadline = start.addingTimeInterval(12.0)
        var retried = false
        var relaunched = false
        while Date() < deadline {
            if await checkHealth(port: portToCheck) {
                print("listening on http://127.0.0.1:\(portToCheck)")
                exit(EXIT_SUCCESS)
            }
            // If the app was still initializing and missed the first signal, retry once after ~3s
            if !retried && Date().timeIntervalSince(start) > 3.0 {
                if !relaunched {
                    // Attempt one more launch in case the first one didn't take
                    await launchAppIfNeeded()
                    relaunched = true
                }
                postDistributedNotification(
                    name: "com.dinoki.osaurus.control.serve",
                    userInfo: buildInfo()
                )
                retried = true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
        // Improved guidance on failure
        let altPort = min(max(portToCheck + 1, 1), 65535)
        fputs(
            """
            Failed to start server on port \(portToCheck)
            Hints:
              - The port may be busy. Try: osaurus serve --port \(altPort)
              - Ensure Osaurus.app is installed: brew install --cask osaurus
              - Try launching the app first, then serve:
                open -a /Applications/Osaurus.app && osaurus serve
              - You can also open the UI: osaurus ui
            """.appending("\n"),
            stderr
        )
        exit(EXIT_FAILURE)
    }

    // MARK: - Stop
    private static func runStop() async {
        postDistributedNotification(name: "com.dinoki.osaurus.control.stop", userInfo: [:])
        // Verify stopped within a short timeout
        let port = resolveConfiguredPort() ?? 1337
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if !(await checkHealth(port: port)) {
                print("stopped")
                exit(EXIT_SUCCESS)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        fputs("Server did not stop in time\n", stderr)
        exit(EXIT_FAILURE)
    }

    // MARK: - Helpers
    private static func checkHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func postDistributedNotification(name: String, userInfo: [AnyHashable: Any]) {
        // Use DistributedNotificationCenter to reach the app; restrict to local machine by default
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    // MARK: - UI
    private static func runUI() async {
        await launchAppIfNeeded()
        let port = resolveConfiguredPort() ?? 1337
        let start = Date()
        let deadline = start.addingTimeInterval(6.0)
        var lastPost = Date.distantPast
        var postedAtLeastOnce = false
        while Date() < deadline {
            // Once the server is healthy, (re)post a UI request to ensure it is handled
            if await checkHealth(port: port) {
                postDistributedNotification(name: "com.dinoki.osaurus.control.ui", userInfo: [:])
                // Give the app a moment to show the popover, then exit
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit(EXIT_SUCCESS)
            }
            // If still not healthy, periodically post the UI request as the app may not have registered observers yet
            if Date().timeIntervalSince(lastPost) > 0.8 {
                postDistributedNotification(name: "com.dinoki.osaurus.control.ui", userInfo: [:])
                postedAtLeastOnce = true
                lastPost = Date()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Best-effort: post one final time and exit success
        if !postedAtLeastOnce {
            postDistributedNotification(name: "com.dinoki.osaurus.control.ui", userInfo: [:])
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        exit(EXIT_SUCCESS)
    }

    private static func launchAppIfNeeded() async {
        // Try to detect if server responds; if yes, nothing to do
        let port = resolveConfiguredPort() ?? 1337
        if await checkHealth(port: port) { return }

        // Launch the app via `open -b` by bundle id, with fallback to explicit app path search
        var launched = false
        do {
            let openByBundle = Process()
            openByBundle.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openByBundle.arguments = ["-n", "-b", "com.dinoki.osaurus", "--args", "--launched-by-cli"]
            try? openByBundle.run()
            openByBundle.waitUntilExit()
            launched = (openByBundle.terminationStatus == 0)
        }
        // Even if `open -b` returned success, do a quick health-based fallback attempt
        // in case LaunchServices couldn't resolve the bundle id for some setups.
        let healthyAfterBundle = await checkHealth(port: port)
        if !launched || !healthyAfterBundle {
            if let appPath = findAppBundlePath() {
                let openByPath = Process()
                openByPath.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                openByPath.arguments = ["-a", appPath, "--args", "--launched-by-cli"]
                try? openByPath.run()
                openByPath.waitUntilExit()
                launched = (openByPath.terminationStatus == 0)
            }
        }
        if !launched {
            fputs(
                "Could not launch Osaurus.app. Install it with Homebrew: brew install --cask osaurus\n",
                stderr
            )
            return
        }
        // Give the app a moment to initialize (cold start can take a bit)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// Attempts to locate the installed Osaurus.app bundle path using common locations and Spotlight.
    private static func findAppBundlePath() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/Osaurus.app",
            "\(home)/Applications/Osaurus.app",
            "/Applications/osaurus.app",
            "\(home)/Applications/osaurus.app",
        ]
        for c in candidates {
            if fm.fileExists(atPath: c) { return c }
        }
        // Try Spotlight via mdfind, restricted to Applications folders first
        if let path = spotlightFind(queryArgs: [
            "-onlyin", "/Applications",
            "-onlyin", "\(home)/Applications",
            "kMDItemCFBundleIdentifier == 'com.dinoki.osaurus'",
        ]) {
            if fm.fileExists(atPath: path) { return path }
        }
        // Unrestricted Spotlight fallback (search entire metadata index)
        if let path = spotlightFind(queryArgs: [
            "kMDItemCFBundleIdentifier == 'com.dinoki.osaurus'"
        ]) {
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Runs mdfind with the provided arguments and returns the first non-empty line.
    private static func spotlightFind(queryArgs: [String]) -> String? {
        let mdfind = Process()
        let outPipe = Pipe()
        mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        mdfind.standardOutput = outPipe
        mdfind.arguments = queryArgs
        do {
            try mdfind.run()
            mdfind.waitUntilExit()
            if mdfind.terminationStatus == 0 {
                let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
                if let s = String(data: data, encoding: .utf8) {
                    if let first = s.split(separator: "\n").first, !first.isEmpty {
                        return String(first)
                    }
                }
            }
        } catch {
            // ignore failures; fallback will be nil
        }
        return nil
    }

    // MARK: - List
    private struct ModelsListResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private static func runList() async {
        // Ensure server is up (best-effort)
        let port = await ensureServerReadyOrExit()

        guard let url = URL(string: "http://127.0.0.1:\(port)/models") else {
            fputs("Invalid URL for models\n", stderr)
            exit(EXIT_FAILURE)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                fputs(
                    "Failed to fetch models (status \((response as? HTTPURLResponse)?.statusCode ?? -1))\n",
                    stderr
                )
                exit(EXIT_FAILURE)
            }
            let decoder = JSONDecoder()
            let list = try decoder.decode(ModelsListResponse.self, from: data)
            if list.data.isEmpty {
                print("(no models found)")
                exit(EXIT_SUCCESS)
            }
            for m in list.data { print(m.id) }
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Error fetching models: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Run (interactive chat)
    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let temperature: Float?
        let max_tokens: Int?
        let session_id: String?
    }
    private struct NDJSONEvent: Decodable {
        struct NDMessage: Decodable {
            let role: String?
            let content: String?
        }
        let message: NDMessage?
        let done: Bool?
    }

    private static func runRun(_ args: [String]) async {
        guard let modelArg = args.first, !modelArg.isEmpty else {
            fputs("Missing required <model_id>\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        }

        let port = await ensureServerReadyOrExit(pollSeconds: 5.0)

        let sessionId = "cli-\(UUID().uuidString.prefix(8))"
        var transcript: [ChatMessage] = []

        print("Chatting with \(modelArg). Type 'exit' to quit.\n")
        while true {
            // Prompt
            fputs("> ", stdout)
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else { break }
            let userInput = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if userInput.lowercased() == "exit" { break }
            if userInput.isEmpty { continue }

            transcript.append(ChatMessage(role: "user", content: userInput))

            // Build streaming request
            guard let url = URL(string: "http://127.0.0.1:\(port)/chat") else {
                fputs("Invalid URL for chat\n", stderr)
                exit(EXIT_FAILURE)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 3600  // allow long-lived stream (1 hour)

            let body = ChatRequest(
                model: modelArg,
                messages: transcript,
                stream: true,
                temperature: nil,
                max_tokens: nil,
                session_id: sessionId
            )
            do {
                let payload = try JSONEncoder().encode(body)
                request.httpBody = payload
            } catch {
                fputs("Failed to encode chat request: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }

            // Stream NDJSON response
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var errorData = Data()
                    do {
                        for try await chunk in bytes { errorData.append(contentsOf: [chunk]) }
                    } catch { /* ignore stream read errors on failure */  }
                    let message = String(data: errorData, encoding: .utf8) ?? ""
                    fputs("Chat request failed (status \(http.statusCode)). \n\(message)\n", stderr)
                    exit(EXIT_FAILURE)
                }

                let decoder = JSONDecoder()
                var assistantAggregate = ""
                for try await line in bytes.lines {
                    if line.isEmpty { continue }
                    // Decode NDJSON event and print incremental content
                    if let data = line.data(using: .utf8),
                        let event = try? decoder.decode(NDJSONEvent.self, from: data)
                    {
                        if let content = event.message?.content, !content.isEmpty {
                            assistantAggregate += content
                            print(content, terminator: "")
                            fflush(stdout)
                        }
                        if event.done == true {
                            print("")
                            break
                        }
                    } else {
                        // Fallback: just print raw line
                        print(line)
                    }
                }
                if !assistantAggregate.isEmpty {
                    transcript.append(ChatMessage(role: "assistant", content: assistantAggregate))
                }
            } catch {
                fputs("Streaming error: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        print("Goodbye.")
        exit(EXIT_SUCCESS)
    }

    // MARK: - Shared server readiness helper
    /// Ensures the server is running locally and returns the port.
    /// If not up, attempts to auto-launch briefly and polls until healthy.
    /// Exits the process with failure on timeout.
    private static func ensureServerReadyOrExit(pollSeconds: TimeInterval = 3.0) async -> Int {
        let port = resolveConfiguredPort() ?? 1337
        if !(await checkHealth(port: port)) {
            await launchAppIfNeeded()
        }
        let deadline = Date().addingTimeInterval(pollSeconds)
        var healthy = await checkHealth(port: port)
        while !healthy && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            healthy = await checkHealth(port: port)
        }
        guard healthy else {
            fputs("Server is not running. Start it with 'osaurus serve'\n", stderr)
            exit(EXIT_FAILURE)
        }
        return port
    }
}

// MARK: - MCP Proxy (stdio -> HTTP)
extension OsaurusCLI {
    private static func runMCP() async {
        // Ensure app server is up; auto-launch only if not already running
        let port = await ensureServerReadyOrExit(pollSeconds: 5.0)
        let baseURL = "http://127.0.0.1:\(port)"

        // Build MCP server
        let server = MCP.Server(
            name: "Osaurus MCP Proxy",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "cli",
            capabilities: .init(tools: .init(listChanged: true))
        )

        // Register ListTools -> GET /mcp/tools
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            guard let url = URL(string: "\(baseURL)/mcp/tools") else {
                return .init(tools: [])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 5.0
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return .init(tools: [])
                }
                let tools: [MCP.Tool]
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let arr = obj["tools"] as? [[String: Any]]
                {
                    tools = arr.map { item in
                        let name = (item["name"] as? String) ?? ""
                        let description = (item["description"] as? String) ?? ""
                        let schemaAny = item["inputSchema"]
                        let schema = toMCPValue(from: schemaAny)
                        return MCP.Tool(name: name, description: description, inputSchema: schema)
                    }
                } else {
                    tools = []
                }
                return .init(tools: tools)
            } catch {
                return .init(tools: [])
            }
        }

        // Register CallTool -> POST /mcp/call
        await server.withMethodHandler(MCP.CallTool.self) { params in
            struct CallBody: Encodable {
                let name: String
                let arguments: MCP.Value?
            }
            struct CallResponse: Decodable {
                struct Item: Decodable {
                    let type: String
                    let text: String?
                }
                let content: [Item]
                let isError: Bool
            }
            guard let url = URL(string: "\(baseURL)/mcp/call") else {
                return .init(content: [.text("Invalid URL")], isError: true)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30.0

            do {
                // Wrap dictionary arguments into a single MCP.Value object if present
                let argValue: MCP.Value? = params.arguments.map { .object($0) }
                let body = CallBody(name: params.name, arguments: argValue)
                request.httpBody = try JSONEncoder().encode(body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let message = String(decoding: data, as: UTF8.self)
                    return .init(
                        content: [
                            .text("HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode)): \(message)")
                        ],
                        isError: true
                    )
                }
                let decoded = try JSONDecoder().decode(CallResponse.self, from: data)
                // Aggregate text items into a single text content to match our server's MCP usage
                let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
                if text.isEmpty {
                    return .init(content: [], isError: decoded.isError)
                } else {
                    return .init(content: [.text(text)], isError: decoded.isError)
                }
            } catch {
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        }

        // Start stdio transport
        do {
            let transport = MCP.StdioTransport()
            try await server.start(transport: transport)
            // Returned when stdio closes
            exit(EXIT_SUCCESS)
        } catch {
            fputs("MCP server error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    // Convert loosely-typed JSON (from JSONSerialization) into MCP.Value
    private static func toMCPValue(from any: Any?) -> MCP.Value {
        guard let value = any else { return .null }
        if value is NSNull { return .null }
        if let b = value as? Bool { return .bool(b) }
        if let i = value as? Int { return .double(Double(i)) }
        if let d = value as? Double { return .double(d) }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] {
            return .array(arr.map { toMCPValue(from: $0) })
        }
        if let dict = value as? [String: Any] {
            var mapped: [String: MCP.Value] = [:]
            for (k, v) in dict {
                mapped[k] = toMCPValue(from: v)
            }
            return .object(mapped)
        }
        // NSNumber (covers both ints and doubles when decoded by JSONSerialization)
        if let n = value as? NSNumber {
            if CFNumberGetType(n) == .charType { return .bool(n.boolValue) }
            return .double(n.doubleValue)
        }
        return .null
    }
}
