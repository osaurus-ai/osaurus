import Foundation

@main
struct OsaurusCLI {
  static func main() async {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else {
      printUsage()
      exit(EXIT_FAILURE)
    }

    switch command {
    case "status":
      await runStatus()

    case "serve":
      await runServe(Array(arguments.dropFirst()))

    case "stop":
      await runStop()

    case "help", "-h", "--help":
      printUsage()
      exit(EXIT_SUCCESS)

    default:
      fputs("Unknown command: \(command)\n\n", stderr)
      printUsage()
      exit(EXIT_FAILURE)
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
      osaurus help         Show this help

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
    guard let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let configURL = supportDir
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
    let port = resolveConfiguredPort() ?? 8080

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
    postDistributedNotification(name: "com.dinoki.osaurus.control.serve", userInfo: {
      var info: [AnyHashable: Any] = [:]
      if let p = desiredPort { info["port"] = p }
      if expose { info["expose"] = true }
      return info
    }())

    // Poll health until running or timeout
    let portToCheck = desiredPort ?? (resolveConfiguredPort() ?? 8080)
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
      if await checkHealth(port: portToCheck) {
        print("listening on http://127.0.0.1:\(portToCheck)")
        exit(EXIT_SUCCESS)
      }
      try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }
    fputs("Failed to start server on port \(portToCheck)\n", stderr)
    exit(EXIT_FAILURE)
  }

  // MARK: - Stop
  private static func runStop() async {
    postDistributedNotification(name: "com.dinoki.osaurus.control.stop", userInfo: [:])
    // Verify stopped within a short timeout
    let port = resolveConfiguredPort() ?? 8080
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
    let port = resolveConfiguredPort() ?? 8080
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
}
