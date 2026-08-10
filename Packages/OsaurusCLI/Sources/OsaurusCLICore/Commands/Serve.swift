//
//  Serve.swift
//  osaurus
//
//  Command to start the Osaurus server with optional port configuration and network exposure settings.
//

import Foundation

public struct ServeCommand: Command {
    public static let name = "serve"

    public static func execute(args: [String]) async {
        // Parse optional --port argument
        var desiredPort: Int? = nil
        var expose: Bool = false
        var assumeYes: Bool = false
        var supervise: Bool = false
        var probeInterval: TimeInterval = 15.0
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
            } else if a == "--supervise" {
                supervise = true
                i += 1
                continue
            } else if a == "--interval", i + 1 < args.count {
                if let n = Double(args[i + 1]), n > 0 { probeInterval = n }
                i += 2
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

        let buildInfo: () -> [AnyHashable: Any] = {
            var info: [AnyHashable: Any] = [:]
            if let p = desiredPort { info["port"] = p }
            if expose { info["expose"] = true }
            return info
        }

        // Supervise mode: keep the server alive indefinitely instead of a
        // one-shot start. Probes /health and relaunches the app whenever it is
        // down. Intended to run under a launchd KeepAlive LaunchAgent so the
        // server (and its in-app scheduler) survives quit/crash/logout/reboot.
        if supervise {
            let serveDesiredPort = desiredPort
            let serveExpose = expose
            let supervisor = ServerSupervisor(
                port: desiredPort ?? (Configuration.resolveConfiguredPort() ?? 1337),
                probeInterval: probeInterval,
                ensureServing: {
                    await AppControl.launchAppIfNeeded()
                    var info: [AnyHashable: Any] = [:]
                    if let p = serveDesiredPort { info["port"] = p }
                    if serveExpose { info["expose"] = true }
                    AppControl.postDistributedNotification(
                        name: "com.dinoki.osaurus.control.serve",
                        userInfo: info
                    )
                }
            )
            await supervisor.run()
            return
        }

        // Launch the app if not running, then post local-only distributed notification to start
        await AppControl.launchAppIfNeeded()
        AppControl.postDistributedNotification(
            name: "com.dinoki.osaurus.control.serve",
            userInfo: buildInfo()
        )

        // Poll health until running or timeout
        let portToCheck = desiredPort ?? (Configuration.resolveConfiguredPort() ?? 1337)
        let start = Date()
        let deadline = start.addingTimeInterval(12.0)
        var retried = false
        var relaunched = false
        while Date() < deadline {
            if await ServerControl.checkHealth(port: portToCheck) {
                print("listening on http://127.0.0.1:\(portToCheck)")
                exit(EXIT_SUCCESS)
            }
            // If the app was still initializing and missed the first signal, retry once after ~3s
            if !retried && Date().timeIntervalSince(start) > 3.0 {
                if !relaunched {
                    // Attempt one more launch in case the first one didn't take
                    await AppControl.launchAppIfNeeded()
                    relaunched = true
                }
                AppControl.postDistributedNotification(
                    name: "com.dinoki.osaurus.control.serve",
                    userInfo: buildInfo()
                )
                retried = true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
        let diagnostic = await InstallationDiagnostics.collect(
            requestedPort: portToCheck,
            includeSignatureChecks: false,
            startupAttempted: true,
            includeModelInventory: false,
            includeComprehensiveAppSearch: false
        )
        if diagnostic.serverHealthy {
            print("listening on http://127.0.0.1:\(portToCheck)")
            exit(EXIT_SUCCESS)
        }
        fputs(
            """
            Failed to start server on port \(portToCheck)
            Diagnosis: \(diagnostic.diagnosis.rawValue)
            Next step: \(diagnostic.recommendation)
            Run `osaurus doctor --redact` for a shareable installation report.
            """.appending("\n"),
            stderr
        )
        exit(EXIT_FAILURE)
    }
}
