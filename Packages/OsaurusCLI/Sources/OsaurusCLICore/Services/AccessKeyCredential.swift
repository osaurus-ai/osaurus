//
//  AccessKeyCredential.swift
//  osaurus
//
//  Access-key lookup shared by CLI commands that call the local server
//  (`osaurus mcp`, `osaurus config`): a `--access-key` style option first,
//  then the documented environment variables.
//

import Foundation

struct AccessKeyCredential: Equatable {
    let token: String
    let source: String
}

enum AccessKeyResolver {
    static let optionNames: Set<String> = [
        "--access-key",
        "--api-key",
        "--token",
        "--bearer-token",
    ]

    static let environmentNames = [
        "OSAURUS_MCP_ACCESS_KEY",
        "OSAURUS_ACCESS_KEY",
        "OSAURUS_API_KEY",
        "OSU_ACCESS_KEY",
        "OSU_API_KEY",
    ]

    static let authorizationEnvironmentNames = [
        "OSAURUS_MCP_AUTHORIZATION",
        "AUTHORIZATION",
        "HTTP_AUTHORIZATION",
    ]

    static func resolve(
        args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AccessKeyCredential? {
        for index in args.indices {
            let arg = args[index]
            if let value = valueFromInlineArgument(arg) {
                return AccessKeyCredential(token: value, source: sourceFromInlineArgument(arg))
            }
            guard optionNames.contains(arg), args.indices.contains(index + 1) else {
                continue
            }
            if let token = normalizedAccessKey(args[index + 1]) {
                return AccessKeyCredential(token: token, source: arg)
            }
        }

        for name in environmentNames {
            if let token = normalizedAccessKey(environment[name]) {
                return AccessKeyCredential(token: token, source: name)
            }
        }

        for name in authorizationEnvironmentNames {
            if let token = normalizedAuthorizationHeader(environment[name]) {
                return AccessKeyCredential(token: token, source: name)
            }
        }

        return nil
    }

    /// `args` without any access-key option (and the value that follows a
    /// space-separated one), for commands that reject unknown options.
    static func removingAccessKeyOptions(from args: [String]) -> [String] {
        var remaining: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if optionNames.contains(arg) {
                index += 2
                continue
            }
            if optionNames.contains(where: { arg.hasPrefix($0 + "=") }) {
                index += 1
                continue
            }
            remaining.append(arg)
            index += 1
        }
        return remaining
    }

    private static func valueFromInlineArgument(_ argument: String) -> String? {
        for option in optionNames {
            let prefix = option + "="
            guard argument.hasPrefix(prefix) else { continue }
            return normalizedAccessKey(String(argument.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func sourceFromInlineArgument(_ argument: String) -> String {
        argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "--access-key"
    }

    private static func normalizedAccessKey(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func normalizedAuthorizationHeader(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.lowercased().hasPrefix("bearer ")
        else {
            return nil
        }
        return normalizedAccessKey(value)
    }
}
