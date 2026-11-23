//
//  Serve.swift
//  osaurus
//
//  Command to start the Osaurus server. The saved Expose to Network setting
//  is left alone unless `--expose` or `--no-expose` is given.
//

import Foundation

public struct ServeCommand: Command {
    public static let name = "serve"

    static let usage = """
        Usage: osaurus serve [--port N] [--expose | --no-expose] [--yes] [--supervise [--interval S]]

        Starts the Osaurus server, launching the app if it is not running.

          --port N        Listen on port N (1-65535) and save it.
          --expose        Turn on Expose to Network (other devices on your LAN can connect).
          --no-expose     Turn off Expose to Network (this Mac only).
          --yes, -y       Skip the confirmation for --expose.
          --supervise     Keep the server running; relaunch the app when it quits.
          --interval S    Seconds between supervise checks (default 15).

        Without --expose or --no-expose the saved setting is kept.
        """

    struct Options: Equatable, Sendable {
        var port: Int?
        var expose: Bool?
        var assumeYes = false
        var supervise = false
        var probeInterval: TimeInterval = 15
        var help = false
    }

    enum ArgumentError: Error, Equatable {
        case invalid(String)
    }

    static func parseOptions(_ args: [String]) throws -> Options {
        var options = Options()
        var i = 0
        func value(for flag: String) throws -> String {
            guard i + 1 < args.count else { throw ArgumentError.invalid("\(flag) requires a value") }
            return args[i + 1]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                options.help = true
                i += 1
            case "--port":
                guard let port = Int(try value(for: arg)), (1 ..< 65536).contains(port) else {
                    throw ArgumentError.invalid("--port must be an integer from 1 through 65535")
                }
                options.port = port
                i += 2
            case "--expose":
                if options.expose == false {
                    throw ArgumentError.invalid("--expose and --no-expose cannot be combined")
                }
                options.expose = true
                i += 1
            case "--no-expose":
                if options.expose == true {
                    throw ArgumentError.invalid("--expose and --no-expose cannot be combined")
                }
                options.expose = false
                i += 1
            case "--yes", "-y":
                options.assumeYes = true
                i += 1
            case "--supervise":
                options.supervise = true
                i += 1
            case "--interval":
                guard let seconds = Double(try value(for: arg)), seconds > 0 else {
                    throw ArgumentError.invalid("--interval must be a positive number of seconds")
                }
                options.probeInterval = seconds
                i += 2
            default:
                throw ArgumentError.invalid("unknown argument `\(arg)`")
            }
        }
        return options
    }

    /// The flag wins over the saved setting: the app may not have saved
    /// the change yet when the server first answers.
    static func listeningLine(port: Int, expose: Bool?) -> String {
        let exposed = expose ?? Configuration.resolveExposeToNetwork()
        return "listening on http://127.0.0.1:\(port)" + (exposed ? " and on your local network" : "")
    }

    /// The notification payload. `expose` is sent only when a flag asked
    /// for a change.
    static func serveUserInfo(_ options: Options) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let port = options.port { info["port"] = port }
        if let expose = options.expose { info["expose"] = expose }
        return info
    }

    static let serveNotification = "com.dinoki.osaurus.control.serve"

    public static func execute(args: [String]) async {
        let options: Options
        do {
            options = try parseOptions(args)
        } catch ArgumentError.invalid(let message) {
            fputs("osaurus serve: \(message)\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("osaurus serve: invalid arguments\n", stderr)
            exit(EXIT_FAILURE)
        }
        if options.help {
            print(usage)
            exit(EXIT_SUCCESS)
        }

        if options.expose == true && !options.assumeYes {
            let warning = """
                WARNING: Exposing Osaurus to the local network will allow other devices on your LAN
                to connect to your server. Make sure you trust your network and understand the risks.
                Proceed with exposure? [y/N]: 
                """
            fputs(warning, stderr)
            fflush(stderr)
            let answer = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if answer != "y" && answer != "yes" {
                fputs("aborted\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        let info = serveUserInfo(options)
        let port = options.port ?? (Configuration.resolveConfiguredPort() ?? 1337)

        // Supervise mode: keep the server alive indefinitely. Intended to run
        // under a launchd KeepAlive LaunchAgent so the server (and its in-app
        // scheduler) survives quit/crash/logout/reboot.
        if options.supervise {
            let supervisor = ServerSupervisor(
                port: port,
                probeInterval: options.probeInterval,
                launchAndServe: {
                    await AppControl.launchApp()
                    AppControl.postDistributedNotification(
                        name: serveNotification,
                        userInfo: serveUserInfo(options)
                    )
                },
                requestServe: {
                    AppControl.postDistributedNotification(
                        name: serveNotification,
                        userInfo: serveUserInfo(options)
                    )
                }
            )
            await supervisor.run()
            return
        }

        let state = await AppControl.launchAppIfNeeded(port: port)
        AppControl.postDistributedNotification(name: serveNotification, userInfo: info)

        // A cold start may miss the first notification while the app is
        // still registering observers, so it is re-posted. The app is never
        // launched a second time.
        let deadline = Date().addingTimeInterval(state == .appNotRunning ? 20 : 12)
        var lastPost = Date()
        while Date() < deadline {
            if await ServerControl.checkHealth(port: port, timeout: 1.0) {
                print(listeningLine(port: port, expose: options.expose))
                exit(EXIT_SUCCESS)
            }
            if Date().timeIntervalSince(lastPost) > 3 {
                AppControl.postDistributedNotification(name: serveNotification, userInfo: info)
                lastPost = Date()
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let diagnostic = await InstallationDiagnostics.collect(
            requestedPort: port,
            includeSignatureChecks: false,
            startupAttempted: true,
            includeModelInventory: false,
            includeComprehensiveAppSearch: false
        )
        if diagnostic.serverHealthy {
            print(listeningLine(port: port, expose: options.expose))
            exit(EXIT_SUCCESS)
        }
        fputs(
            """
            Failed to start server on port \(port)
            Diagnosis: \(diagnostic.diagnosis.rawValue)
            Next step: \(diagnostic.recommendation)
            Run `osaurus doctor --redact` for a shareable installation report.
            """.appending("\n"),
            stderr
        )
        exit(EXIT_FAILURE)
    }
}
