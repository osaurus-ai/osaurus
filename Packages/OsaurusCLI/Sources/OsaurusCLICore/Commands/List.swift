//
//  List.swift
//  osaurus
//
//  Command to list all available model IDs from the running server.
//

import Foundation

public struct ListCommand: Command {
    public static let name = "list"

    static let usage = """
        Usage: osaurus list [--json] [--access-key KEY]

        Lists the model ids the running server can use.
        """

    private struct ModelsListResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    public static func execute(args: [String]) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        let rest = AccessKeyResolver.removingAccessKeyOptions(from: args)
        let json = rest.contains("--json")
        if let unknown = rest.first(where: { $0 != "--json" }) {
            fputs("osaurus list: unknown argument `\(unknown)`\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }

        let client = await LocalServerClient.connect(command: "list", args: args)
        do {
            let (data, http) = try await client.data(for: client.request("/models", timeout: 10))
            if http.statusCode == 401 { client.exitUnauthorized() }
            guard http.statusCode == 200 else {
                fputs("Failed to fetch models (status \(http.statusCode))\n", stderr)
                exit(EXIT_FAILURE)
            }
            if json {
                print(String(decoding: data, as: UTF8.self))
                exit(EXIT_SUCCESS)
            }
            let list = try JSONDecoder().decode(ModelsListResponse.self, from: data)
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
