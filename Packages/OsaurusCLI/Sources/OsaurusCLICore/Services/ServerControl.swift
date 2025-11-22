//
//  ServerControl.swift
//  osaurus
//
//  Service for checking server health and ensuring the server is ready before executing commands.
//

import Foundation

public struct ServerControl {
    public static func checkHealth(port: Int) async -> Bool {
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

    /// Ensures the server is running locally and returns the port.
    /// If not up, attempts to auto-launch briefly and polls until healthy.
    /// Exits the process with failure on timeout.
    public static func ensureServerReadyOrExit(pollSeconds: TimeInterval = 3.0) async -> Int {
        let port = Configuration.resolveConfiguredPort() ?? 1337
        if !(await checkHealth(port: port)) {
            await AppControl.launchAppIfNeeded()
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
