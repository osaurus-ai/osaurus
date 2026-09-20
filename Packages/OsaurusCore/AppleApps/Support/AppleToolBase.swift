//
//  AppleToolBase.swift
//  osaurus
//
//  Shared base for every built-in Apple app tool. Subclasses declare the
//  schema and implement `run(args:)`, which returns a JSON-serialisable
//  payload (dictionary / array / scalar / `Encodable`) or throws an
//  `AppleToolError`. The base handles:
//
//    - argument parsing (malformed JSON → `invalid_args` envelope),
//    - the `PermissionedTool` contract (requirements default to the owning
//      app's `SystemPermission`s; reads are `.auto`, writes `.ask`),
//    - the canonical `ToolEnvelope` success/failure shapes with typed kinds
//      (`invalid_args`, `not_found`, `permission_denied`, `unavailable`,
//      `timeout`, `execution_error`), and
//    - `Encodable` → JSON bridging so tools never hand-build JSON strings.
//

import Foundation

// MARK: - Errors

/// Typed failures Apple tools throw from `run(args:)`. Each maps to one
/// `ToolEnvelope.Kind` so the model gets a structured signal.
enum AppleToolError: Error, Sendable, Equatable {
    /// Missing / malformed argument. `field` + `expected` help the model
    /// self-correct on the next attempt.
    case invalidArgs(String, field: String? = nil, expected: String? = nil)
    /// A referenced item (event, contact, note, mailbox, …) does not exist.
    case notFound(String)
    /// A macOS privacy permission is not granted.
    case permissionDenied(SystemPermission, detail: String? = nil)
    /// The backing app / framework cannot serve the request right now
    /// (app not running, entitlement missing, database unreadable).
    case unavailable(String, retryable: Bool = false)
    /// The request exceeded its time budget.
    case timeout(String)
    /// Anything else that went wrong at runtime.
    case execution(String)

    var kind: ToolEnvelope.Kind {
        switch self {
        case .invalidArgs: return .invalidArgs
        case .notFound: return .notFound
        case .permissionDenied: return .permissionDenied
        case .unavailable: return .unavailable
        case .timeout: return .timeout
        case .execution: return .executionError
        }
    }

    var message: String {
        switch self {
        case .invalidArgs(let m, _, _): return m
        case .notFound(let m): return m
        case .permissionDenied(let permission, let detail):
            var text =
                "\(permission.displayName) access is not granted to Osaurus. "
                + "Ask the user to allow it in System Settings → Privacy & Security → \(permission.displayName)"
            if let pane = permission.systemSettingsURL?.absoluteString { text += " (\(pane))" }
            text += ", then try again."
            if let detail, !detail.isEmpty { text += " \(detail)" }
            return text
        case .unavailable(let m, _): return m
        case .timeout(let m): return m
        case .execution(let m): return m
        }
    }

    /// Render as the canonical failure envelope for `tool`.
    func envelope(tool: String) -> String {
        switch self {
        case .invalidArgs(_, let field, let expected):
            return ToolEnvelope.failure(
                kind: kind, message: message, field: field, expected: expected, tool: tool
            )
        case .permissionDenied(let permission, _):
            return ToolEnvelope.failure(
                kind: kind,
                message: message,
                tool: tool,
                retryable: false,
                metadata: [
                    "permission": permission.rawValue,
                    "system_settings_url": permission.systemSettingsURL?.absoluteString ?? "",
                ]
            )
        case .unavailable(_, let retryable):
            return ToolEnvelope.failure(kind: kind, message: message, tool: tool, retryable: retryable)
        default:
            return ToolEnvelope.failure(kind: kind, message: message, tool: tool)
        }
    }
}

// MARK: - Base class

/// Base class for Apple app tools. `@unchecked Sendable` because subclasses
/// hold only immutable configuration and service references that are
/// themselves thread-safe.
class AppleToolBase: OsaurusTool, PermissionedTool, @unchecked Sendable {
    /// Which app family this tool belongs to (drives per-agent gating).
    let app: AppleApp
    let name: String
    let description: String
    let parameters: JSONValue?
    /// Whether this tool mutates user data. Drives the default permission
    /// policy (`.auto` for reads, `.ask` for writes).
    let isWrite: Bool
    /// Per-tool permission override. `nil` → the app's full permission set.
    private let requirementOverride: [SystemPermission]?

    init(
        app: AppleApp,
        name: String,
        description: String,
        parameters: JSONValue?,
        isWrite: Bool,
        requirements: [SystemPermission]? = nil
    ) {
        precondition(app.toolNames.contains(name), "\(name) is not declared in AppleApp.\(app.rawValue).toolNames")
        self.app = app
        self.name = name
        self.description = description
        self.parameters = parameters
        self.isWrite = isWrite
        self.requirementOverride = requirements
    }

    /// The `SystemPermission`s this tool needs at execution time.
    var systemPermissions: [SystemPermission] { requirementOverride ?? app.systemPermissions }

    // MARK: PermissionedTool

    var requirements: [String] { systemPermissions.map(\.rawValue) }
    var defaultPermissionPolicy: ToolPermissionPolicy { isWrite ? .ask : .auto }

    // MARK: OsaurusTool

    final func execute(argumentsJSON: String) async throws -> String {
        let req = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = req else { return req.failureEnvelope ?? "" }
        do {
            let payload = try await run(args: args)
            return ToolEnvelope.success(tool: name, result: AppleJSON.serializable(payload.result), warnings: payload.warnings)
        } catch let error as AppleToolError {
            return error.envelope(tool: name)
        } catch is CancellationError {
            return ToolEnvelope.failure(
                kind: .executionError, message: "\(name) was cancelled.", tool: name, retryable: false
            )
        } catch {
            return ToolEnvelope.failure(kind: .executionError, message: error.localizedDescription, tool: name)
        }
    }

    /// Subclass hook. Return the JSON-serialisable result payload.
    func run(args: [String: Any]) async throws -> AppleToolPayload {
        throw AppleToolError.execution("\(name) has no implementation.")
    }
}

/// Result of one Apple tool run: the payload plus optional warnings the
/// envelope surfaces to the model.
struct AppleToolPayload {
    let result: Any?
    let warnings: [String]?

    init(_ result: Any?, warnings: [String]? = nil) {
        self.result = result
        self.warnings = (warnings?.isEmpty ?? true) ? nil : warnings
    }
}

// MARK: - Argument helpers

/// Argument accessors that throw `AppleToolError.invalidArgs` with
/// field-precise messages. Kept free-standing so services/tests can reuse
/// them without a tool instance.
enum AppleArgs {
    static func string(_ args: [String: Any], _ key: String, required: Bool = false, expected: String? = nil)
        throws -> String?
    {
        guard let raw = args[key], !(raw is NSNull) else {
            if required {
                let hint = expected.map { " (\($0))" } ?? ""
                throw AppleToolError.invalidArgs(
                    "Missing required argument `\(key)`\(hint).",
                    field: key, expected: expected
                )
            }
            return nil
        }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if required, trimmed.isEmpty {
                throw AppleToolError.invalidArgs(
                    "Argument `\(key)` must not be empty.", field: key, expected: expected
                )
            }
            return trimmed.isEmpty && !required ? nil : s
        }
        // Weak-caller tolerance: numbers/bools arrive as strings.
        if let n = raw as? NSNumber { return n.stringValue }
        throw AppleToolError.invalidArgs(
            "Argument `\(key)` must be a string.", field: key, expected: expected ?? "a JSON string"
        )
    }

    static func requiredString(_ args: [String: Any], _ key: String, expected: String? = nil) throws -> String {
        try string(args, key, required: true, expected: expected) ?? ""
    }

    static func int(_ args: [String: Any], _ key: String, expected: String? = nil) throws -> Int? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        if let n = ArgumentCoercion.int(raw) { return n }
        if let d = raw as? Double, d.rounded() == d { return Int(d) }
        throw AppleToolError.invalidArgs(
            "Argument `\(key)` must be an integer.", field: key, expected: expected ?? "an integer"
        )
    }

    static func double(_ args: [String: Any], _ key: String, expected: String? = nil) throws -> Double? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        throw AppleToolError.invalidArgs(
            "Argument `\(key)` must be a number.", field: key, expected: expected ?? "a number"
        )
    }

    static func bool(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        if let b = ArgumentCoercion.bool(raw) { return b }
        throw AppleToolError.invalidArgs(
            "Argument `\(key)` must be a boolean.", field: key, expected: "true or false"
        )
    }

    static func stringArray(_ args: [String: Any], _ key: String) throws -> [String]? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        if let arr = ArgumentCoercion.stringArray(raw) {
            let cleaned = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return cleaned
        }
        if let anyArr = raw as? [Any] {
            return anyArr.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
        }
        throw AppleToolError.invalidArgs(
            "Argument `\(key)` must be an array of strings.", field: key, expected: "an array of strings"
        )
    }

    static func object(_ args: [String: Any], _ key: String) throws -> [String: Any]? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        if let dict = raw as? [String: Any] { return dict }
        if let s = raw as? String, let data = s.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return dict
        }
        throw AppleToolError.invalidArgs(
            "Argument `\(key)` must be an object.", field: key, expected: "a JSON object"
        )
    }

    /// Validate an enum-like string against `allowed` (case-insensitive).
    static func enumeration(
        _ args: [String: Any], _ key: String, allowed: [String], default defaultValue: String? = nil
    ) throws -> String? {
        guard let raw = try string(args, key) else { return defaultValue }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowed.contains(normalized) else {
            throw AppleToolError.invalidArgs(
                "`\(key)` must be one of: \(allowed.joined(separator: ", ")). Got `\(raw)`.",
                field: key, expected: "one of: \(allowed.joined(separator: ", "))"
            )
        }
        return normalized
    }

    /// Clamp `limit` into `1...max`, defaulting when absent.
    static func limit(_ args: [String: Any], default defaultValue: Int, max maxValue: Int = 500) throws -> Int {
        guard let n = try int(args, "limit") else { return defaultValue }
        return Swift.max(1, Swift.min(n, maxValue))
    }

    /// Parse a date argument with `AppleDateParsing`; throws a field-precise
    /// error when present but unparseable.
    static func date(_ args: [String: Any], _ key: String, required: Bool = false) throws -> AppleParsedDate? {
        guard let raw = try string(args, key, required: required) else { return nil }
        guard let parsed = AppleDateParsing.parse(raw) else {
            throw AppleToolError.invalidArgs(
                "`\(key)` could not be parsed as a date. Got `\(raw)`.",
                field: key,
                expected: AppleDateParsing.contractDescription
            )
        }
        return parsed
    }
}

// MARK: - JSON bridging

enum AppleJSON {
    /// Convert any payload into something `JSONSerialization` accepts:
    /// `Encodable` values are round-tripped through `JSONEncoder`; `Date`
    /// becomes an ISO8601 string with local offset; nested containers are
    /// converted recursively.
    static func serializable(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case let s as String: return s
        case let b as Bool: return b
        case let n as NSNumber: return n
        case let i as Int: return i
        case let d as Double: return d.isFinite ? d : NSNull()
        case let date as Date: return AppleDateParsing.format(date)
        case let url as URL: return url.absoluteString
        case is NSNull: return NSNull()
        case let dict as [String: Any?]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = serializable(v) }
            return out
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = serializable(v) }
            return out
        case let arr as [Any?]: return arr.map { serializable($0) }
        case let arr as [Any]: return arr.map { serializable($0) }
        case let encodable as Encodable:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, enc in
                var c = enc.singleValueContainer()
                try c.encode(AppleDateParsing.format(date))
            }
            if let data = try? encoder.encode(AnyEncodable(encodable)),
                let obj = try? JSONSerialization.jsonObject(with: data)
            {
                return obj
            }
            return String(describing: value)
        default:
            return String(describing: value)
        }
    }

    /// Type-erasing wrapper so `Encodable` existentials can be encoded.
    struct AnyEncodable: Encodable {
        let base: Encodable
        init(_ base: Encodable) { self.base = base }
        func encode(to encoder: Encoder) throws { try base.encode(to: encoder) }
    }
}
