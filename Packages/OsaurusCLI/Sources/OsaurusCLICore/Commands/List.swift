//
//  List.swift
//  osaurus
//
//  Command to list all available model IDs from the running server.
//

import Foundation

public struct ListCommand: Command {
    public static let name = "list"

    private struct ModelsListResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    public static func execute(args: [String]) async {
        // Ensure server is up (best-effort)
        let port = await ServerControl.ensureServerReadyOrExit()

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
}
