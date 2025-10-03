//
//  OsaurusCLI.swift
//  osaurus
//
//  Created by Terence on 9/26/25.
//

import Foundation

@main
struct OsaurusCLI {
  private enum Command {
    case status
    case serve([String])
    case stop
    case list
    case run(String)
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
        osaurus status          Check if the Osaurus server is running
        osaurus list            List available model IDs
        osaurus run <model_id>  Chat with a downloaded model (interactive)
        osaurus help            Show this help

      """
    print(usage)
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
        if let p = Int(args[i + 1]), (1..<65536).contains(p) { desiredPort = p }
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
    postDistributedNotification(
      name: "com.dinoki.osaurus.control.serve",
      userInfo: {
        var info: [AnyHashable: Any] = [:]
        if let p = desiredPort { info["port"] = p }
        if expose { info["expose"] = true }
        return info
      }())

    // Poll health until running or timeout
    let portToCheck = desiredPort ?? (resolveConfiguredPort() ?? 1337)
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
      if await checkHealth(port: portToCheck) {
        print("listening on http://127.0.0.1:\(portToCheck)")
        exit(EXIT_SUCCESS)
      }
      try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    }
    fputs("Failed to start server on port \(portToCheck)\n", stderr)
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

  private static func launchAppIfNeeded() async {
    // Try to detect if server responds; if yes, nothing to do
    let port = resolveConfiguredPort() ?? 1337
    if await checkHealth(port: port) { return }

    // Launch the app via `open -b` by bundle id
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", "com.dinoki.osaurus"]
    try? process.run()
    process.waitUntilExit()
    // Give the app a moment to initialize
    try? await Task.sleep(nanoseconds: 300_000_000)
  }

  private static func appURLForBundleId(_ bundleId: String) -> URL? { nil }

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
          stderr)
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
