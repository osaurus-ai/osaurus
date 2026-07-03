//
//  AppleScriptAction.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The single model-facing envelope inside the AppleScript loop. The
//  AppleScript model only ever fills ONE `run_applescript` call per step,
//  carrying the complete script to execute. Mirrors the Computer Use
//  `AgentAction` contract (strict schema + coercion/validation via
//  `SchemaValidator` + a model-readable re-ask reason on a shape miss) so the
//  loop drives a parsed call with NO new tool-call parser — the runtime already
//  emits this from the bundle's native Gemma-4 tool-call format.
//

import Foundation

/// Which OSA language a proposed script is written in. AppleScript is the
/// default and the primary surface; JXA (JavaScript for Automation) is the
/// opt-in alternative for apps better served by their JS bridge. Executed via
/// the matching OSA component in `AppleScriptExecutor`.
public enum AppleScriptLanguage: String, Sendable, Equatable, CaseIterable {
    case appleScript = "applescript"
    case javascript = "javascript"

    /// Lenient parse of the model-provided `language` string: common JXA
    /// spellings map to `.javascript`; anything else (absent, blank, or
    /// unrecognized) defaults to AppleScript rather than failing the call.
    public init(callValue raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "javascript", "jxa", "js", "javascript for automation":
            self = .javascript
        default:
            self = .appleScript
        }
    }

    /// The OSA component name `OSALanguage(forName:)` resolves.
    public var osaLanguageName: String {
        switch self {
        case .appleScript: return "AppleScript"
        case .javascript: return "JavaScript"
        }
    }

    /// Short human label for feed / confirm surfaces.
    public var displayLabel: String {
        switch self {
        case .appleScript: return "AppleScript"
        case .javascript: return "JXA (JavaScript)"
        }
    }
}

/// Outcome of decoding a model-emitted `run_applescript` call.
public enum AppleScriptActionDecode: Sendable, Equatable {
    /// A non-empty script to compile + run, in the given OSA language.
    case script(String, AppleScriptLanguage)
    /// The shape was wrong (or the script was blank). `reason` is fed back to
    /// the model as a tool result for a bounded re-ask.
    case invalid(reason: String)

    /// Convenience for the default-language (AppleScript) form.
    public static func script(_ source: String) -> AppleScriptActionDecode {
        .script(source, .appleScript)
    }
}

/// Namespace for the `run_applescript` tool contract: name, JSON schema, the
/// OpenAI-compatible spec, the forced tool choice, and the decoder.
public enum AppleScriptAction {
    /// The tool name the AppleScript model calls inside the loop.
    public static let toolName = "run_applescript"

    /// Strict JSON schema: one required `script` string plus an optional
    /// `language` discriminator. `additionalProperties: false` keeps the
    /// contract tight, the same posture as `agent_action`.
    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "script": .object([
                "type": .string("string"),
                "description": .string(
                    "The complete, executable script to run. Provide the entire script as one "
                        + "string (use \\n for newlines). Do not wrap it in Markdown code fences. If the "
                        + "task provided content as a {{name}} placeholder, write that token where the "
                        + "text value goes instead of re-typing it — it expands to the exact text."
                ),
            ]),
            "language": .object([
                "type": .string("string"),
                "enum": .array([.string("applescript"), .string("javascript")]),
                "description": .string(
                    "Optional. The script's language: \"applescript\" (default) or \"javascript\" "
                        + "for JXA (JavaScript for Automation), when an app is better served by its "
                        + "JS bridge."
                ),
            ]),
        ]),
        "required": .array([.string("script")]),
    ])

    /// The OpenAI-compatible tool spec for the request `tools[]`.
    /// Internal: `Tool` is a module-internal type.
    static var toolSpec: Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: toolName,
                description:
                    "Run a complete AppleScript on macOS to accomplish the task. Emit the entire script "
                    + "in `script`. When the task asks for information, END the script with `return` of "
                    + "the requested value(s) (build a string or list for several values). If the task "
                    + "provided verbatim content as a {{name}} placeholder, insert that token where the "
                    + "text goes rather than re-typing it. You will receive its return value (or a "
                    + "compile/runtime error) and can correct and call again. Scripts are AppleScript "
                    + "unless you set `language` to \"javascript\" (JXA). When the task is done, "
                    + "reply with a short plain-text summary that includes the value(s) and no tool call.",
                parameters: schema
            )
        )
    }

    /// `.auto`, NOT forced: the loop treats a plain-text reply with no tool
    /// call as the natural completion signal (the model's native training emits
    /// the tool call when there's work to do and prose when finished), so we do
    /// not coerce a tool call on the terminal turn.
    static var autoToolChoice: ToolChoiceOption { .auto }

    /// Decode + coerce + validate a model-emitted `run_applescript` arguments
    /// JSON string. Returns `.invalid(reason:)` with a model-readable
    /// explanation on any shape problem (or a blank script) so the loop can
    /// re-ask.
    public static func decode(argumentsJSON: String) -> AppleScriptActionDecode {
        guard let data = argumentsJSON.data(using: .utf8),
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .invalid(
                reason:
                    "Your call was not valid JSON. Reply with a single run_applescript call whose "
                    + "`script` is the complete AppleScript."
            )
        }

        // The chat engine pre-validates tool arguments and, on a schema miss,
        // replaces the model's JSON with an `_error` envelope before the loop
        // ever sees it. Surface that real message so the re-ask tells the model
        // what to fix (mirrors `AgentAction.decode`).
        if let errorKind = raw["_error"] as? String, errorKind == "invalid_tool_arguments" {
            let message =
                (raw["_message"] as? String)
                ?? "Your call did not match the required shape. Provide `script` as one string."
            return .invalid(reason: message)
        }

        let coerced = SchemaValidator.coerceArguments(raw, against: schema)
        let validation = SchemaValidator.validate(arguments: coerced, against: schema)
        guard validation.isValid, let dict = coerced as? [String: Any] else {
            let base =
                validation.errorMessage
                ?? "Your call did not match the required shape. Provide `script` as one string."
            return .invalid(reason: base)
        }

        guard let script = dict["script"] as? String else {
            return .invalid(reason: "`script` must be a string containing the AppleScript to run.")
        }
        let normalized = stripCodeFences(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .invalid(
                reason: "`script` was empty. Provide the complete AppleScript to run."
            )
        }
        let language = AppleScriptLanguage(callValue: dict["language"] as? String)
        return .script(normalized, language)
    }

    /// Strip a surrounding Markdown code fence (```applescript … ```), which
    /// small models sometimes wrap around the script despite the instruction.
    /// Pure formatting cleanup — never alters the script body itself, only
    /// removes a leading fence line and a trailing fence line when both are
    /// present, so a fenced script still compiles.
    static func stripCodeFences(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard lines.count >= 2 else { return source }
        let firstTrimmed = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let lastTrimmed = lines.last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard firstTrimmed.hasPrefix("```"), lastTrimmed == "```" else { return source }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }
}
