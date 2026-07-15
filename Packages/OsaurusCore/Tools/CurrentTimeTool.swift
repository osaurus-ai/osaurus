//
//  CurrentTimeTool.swift
//  osaurus
//
//  `get_current_time()` — returns the current date and time. Local models have
//  no clock in-context, so "what is the time?" (a common first-message smoke
//  test from non-technical users) otherwise makes the model guess or reach for
//  `sandbox_exec date`. This built-in answers it directly with no side effects.
//

import Foundation

public final class CurrentTimeTool: OsaurusTool, @unchecked Sendable {
    public let name = "get_current_time"
    public let description =
        "Get the current date and time. Call this whenever the user asks what "
        + "the time or date is — you have no clock otherwise, so never guess. "
        + "Optionally pass an IANA `timezone` (e.g. \"America/New_York\"); "
        + "defaults to the host's local timezone."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "timezone": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional IANA timezone identifier (e.g. \"Europe/London\", "
                    + "\"America/New_York\"). Defaults to the host's local timezone."
                ),
            ])
        ]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let tzReq = optionalString(
            args,
            "timezone",
            expected: "an IANA timezone identifier",
            tool: name
        )
        guard case .value(let tzName) = tzReq else { return tzReq.failureEnvelope ?? "" }

        let timeZone: TimeZone
        if let tzName, !tzName.isEmpty {
            guard let resolved = TimeZone(identifier: tzName) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Unknown timezone `\(tzName)`. Pass an IANA identifier "
                        + "such as \"America/New_York\", or omit it to use the "
                        + "host's local timezone.",
                    field: "timezone",
                    expected: "an IANA timezone identifier",
                    tool: name
                )
            }
            timeZone = resolved
        } else {
            timeZone = TimeZone.current
        }

        let now = Date()

        // ISO 8601 for unambiguous machine-readable time, plus a human-friendly
        // rendering so the model can answer directly without reformatting.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone
        isoFormatter.formatOptions = [.withInternetDateTime]

        let humanFormatter = DateFormatter()
        humanFormatter.timeZone = timeZone
        humanFormatter.locale = Locale(identifier: "en_US_POSIX")
        humanFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"

        let result: [String: Any] = [
            "iso8601": isoFormatter.string(from: now),
            "readable": humanFormatter.string(from: now),
            "timezone": timeZone.identifier,
            "unix_seconds": Int(now.timeIntervalSince1970),
        ]
        return ToolEnvelope.success(tool: name, result: result)
    }
}
