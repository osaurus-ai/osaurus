//
//  AppleSchema.swift
//  osaurus
//
//  Tiny JSON-schema builder so the ~60 Apple tool schemas stay readable and
//  byte-stable (OpenAI-compatible minimal subset: object / string / integer /
//  number / boolean / array with `description` and optional `enum`).
//

import Foundation

enum AppleSchema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
        ]
        if !required.isEmpty { dict["required"] = .array(required.map(JSONValue.string)) }
        return .object(dict)
    }

    /// Nested object property. Closed like the top level
    /// (`BuiltinToolResilienceTests` enforces `additionalProperties: false`
    /// at every object level), so list every key a caller may send.
    static func nested(_ description: String, _ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var dict: [String: JSONValue] = [
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
        ]
        if !required.isEmpty { dict["required"] = .array(required.map(JSONValue.string)) }
        return .object(dict)
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var dict: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let values { dict["enum"] = .array(values.map(JSONValue.string)) }
        return .object(dict)
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func stringArray(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["type": .string("string")]
        if let values { item["enum"] = .array(values.map(JSONValue.string)) }
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(item),
        ])
    }

    static func integerArray(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("integer")]),
        ])
    }

    /// Standard date parameter description carrying the shared contract.
    static func date(_ lead: String) -> JSONValue {
        string(lead + " " + AppleDateParsing.contractDescription)
    }

    /// Standard `limit` parameter.
    static func limit(default defaultValue: Int, max maxValue: Int = 500) -> JSONValue {
        integer("Maximum number of results (default \(defaultValue), max \(maxValue)).")
    }

    /// Shared recurrence sub-schema (Calendar + Reminders).
    static var recurrence: JSONValue {
        nested(
            "Repeat rule. Omit for a one-off item.",
            [
                "frequency": string("How often it repeats.", enum: ["daily", "weekly", "monthly", "yearly"]),
                "interval": integer("Every N periods (default 1)."),
                "days_of_week": stringArray(
                    "For weekly rules: weekday names to repeat on (e.g. [\"monday\", \"wednesday\"]).",
                    enum: ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
                ),
                "end_date": date("Stop repeating after this date (optional)."),
                "occurrence_count": integer("Stop after this many occurrences (optional; ignored when end_date is set)."),
            ],
            required: ["frequency"]
        )
    }
}
