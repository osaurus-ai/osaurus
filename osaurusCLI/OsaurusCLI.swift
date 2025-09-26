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
      osaurus status       Check if the Osaurus server is running
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
}



