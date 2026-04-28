//
//  Status.swift
//  osaurus
//
//  Command to check if the Osaurus server is currently running and healthy.
//

import Foundation

public struct StatusCommand: Command {
    public static let name = "status"

    public static func execute(args: [String]) async {
        let port = Configuration.resolveConfiguredPort() ?? 1337

        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            fputs("Неверный URL для проверки состояния\n", stderr)
            exit(EXIT_FAILURE)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.6

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                print("запущен (порт \(port))")
                exit(EXIT_SUCCESS)
            } else {
                print("остановлен")
                exit(EXIT_FAILURE)
            }
        } catch {
            print("остановлен")
            exit(EXIT_FAILURE)
        }
    }
}
