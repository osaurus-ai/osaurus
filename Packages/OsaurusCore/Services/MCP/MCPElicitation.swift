//
//  MCPElicitation.swift
//  osaurus
//
//  `elicitation/create` (MCP 2025-11-25): a connected server asks the user for
//  input in the middle of a tool call. Form mode renders a flat primitive
//  schema; URL mode sends the user to a page in their browser. This file holds
//  the UI-independent pieces: schema parsing, input validation, URL safety,
//  and the per-client bookkeeping that decides whether anyone can answer.
//

import Foundation
import MCP

// MARK: - Form schema

struct MCPElicitationField: Equatable, Sendable, Identifiable {
    enum StringFormat: String, Sendable {
        case email, uri, date
        case dateTime = "date-time"
    }

    struct Choice: Equatable, Sendable {
        let value: String
        let label: String
    }

    enum Kind: Equatable, Sendable {
        case text(format: StringFormat?, minLength: Int?, maxLength: Int?)
        case number(integer: Bool, minimum: Double?, maximum: Double?)
        case boolean
        case choice([Choice])
    }

    let key: String
    let title: String
    let description: String?
    let required: Bool
    let kind: Kind
    let defaultValue: MCPElicitationInput?

    var id: String { key }
}

/// What the user typed or picked, before it is converted to the schema's type.
enum MCPElicitationInput: Equatable, Sendable {
    case text(String)
    case flag(Bool)
}

struct MCPElicitationSchemaError: Error, Equatable, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

struct MCPElicitationForm: Equatable, Sendable {
    let title: String?
    let fields: [MCPElicitationField]

    /// The spec restricts form mode to a flat object of primitive properties.
    /// Anything else (nested objects, multi-select arrays) is rejected rather
    /// than half-rendered, so the server gets an error it can act on.
    static func parse(_ schema: Elicitation.RequestSchema) throws -> MCPElicitationForm {
        let required = schema.required ?? []
        let orderedKeys =
            required.filter { schema.properties[$0] != nil }
            + schema.properties.keys.filter { !required.contains($0) }.sorted()
        var fields: [MCPElicitationField] = []
        for key in orderedKeys {
            guard case .object(let property)? = schema.properties[key] else {
                throw MCPElicitationSchemaError(reason: "Property '\(key)' is not a schema object")
            }
            fields.append(try field(key: key, property: property, required: required.contains(key)))
        }
        return MCPElicitationForm(title: schema.title, fields: fields)
    }

    private static func field(key: String, property: [String: Value], required: Bool) throws
        -> MCPElicitationField
    {
        let title = property["title"]?.stringValue ?? key
        let description = property["description"]?.stringValue
        let type = property["type"]?.stringValue

        func make(_ kind: MCPElicitationField.Kind, _ defaultValue: MCPElicitationInput?) -> MCPElicitationField {
            MCPElicitationField(
                key: key, title: title, description: description, required: required, kind: kind,
                defaultValue: defaultValue)
        }

        switch type {
        case "string":
            if let choices = choices(property) {
                guard !choices.isEmpty else {
                    throw MCPElicitationSchemaError(reason: "Property '\(key)' has an empty enum")
                }
                return make(.choice(choices), property["default"]?.stringValue.map { .text($0) })
            }
            var format: MCPElicitationField.StringFormat?
            if let raw = property["format"]?.stringValue {
                format = MCPElicitationField.StringFormat(rawValue: raw)
                if format == nil {
                    throw MCPElicitationSchemaError(reason: "Property '\(key)' uses unsupported format '\(raw)'")
                }
            }
            return make(
                .text(format: format, minLength: property["minLength"]?.intValue, maxLength: property["maxLength"]?.intValue),
                property["default"]?.stringValue.map { .text($0) })
        case "number", "integer":
            let defaultText = property["default"].flatMap(numberText)
            return make(
                .number(
                    integer: type == "integer",
                    minimum: property["minimum"].flatMap(number),
                    maximum: property["maximum"].flatMap(number)),
                defaultText.map { .text($0) })
        case "boolean":
            return make(.boolean, property["default"]?.boolValue.map { .flag($0) })
        default:
            throw MCPElicitationSchemaError(
                reason: "Property '\(key)' has unsupported type '\(type ?? "missing")'")
        }
    }

    /// `enum` (+ legacy `enumNames`) or titled `oneOf: [{const, title}]`.
    private static func choices(_ property: [String: Value]) -> [MCPElicitationField.Choice]? {
        if case .array(let values)? = property["enum"] {
            let names: [String]? = {
                guard case .array(let raw)? = property["enumNames"] else { return nil }
                return raw.compactMap(\.stringValue)
            }()
            let options = values.compactMap(\.stringValue)
            return options.enumerated().map { index, value in
                let label = names.flatMap { index < $0.count ? $0[index] : nil } ?? value
                return .init(value: value, label: label)
            }
        }
        if case .array(let options)? = property["oneOf"] {
            return options.compactMap { option in
                guard case .object(let entry) = option, let value = entry["const"]?.stringValue else { return nil }
                return .init(value: value, label: entry["title"]?.stringValue ?? value)
            }
        }
        return nil
    }

    private static func number(_ value: Value) -> Double? {
        if let d = value.doubleValue { return d }
        return value.intValue.map(Double.init)
    }

    private static func numberText(_ value: Value) -> String? {
        if let i = value.intValue { return String(i) }
        return value.doubleValue.map { String($0) }
    }

    // MARK: Validation

    /// Convert the user's inputs into typed `content`, or return a message per
    /// invalid field. Empty optional fields are omitted.
    func content(from inputs: [String: MCPElicitationInput]) -> Result<[String: Value], FieldErrors> {
        var content: [String: Value] = [:]
        var errors: [String: String] = [:]
        for field in fields {
            switch Self.convert(inputs[field.key] ?? field.defaultValue, for: field) {
            case .success(let value?): content[field.key] = value
            case .success(nil): break
            case .failure(let invalid): errors[field.key] = invalid.message
            }
        }
        return errors.isEmpty ? .success(content) : .failure(FieldErrors(messages: errors))
    }

    struct FieldErrors: Error, Equatable {
        let messages: [String: String]
    }

    private struct Invalid: Error {
        let message: String
    }

    private static func invalid(_ message: String) -> Result<Value?, Invalid> {
        .failure(Invalid(message: message))
    }

    private static func convert(_ input: MCPElicitationInput?, for field: MCPElicitationField)
        -> Result<Value?, Invalid>
    {
        if case .boolean = field.kind {
            if case .flag(let on)? = input { return .success(.bool(on)) }
            return field.required ? invalid(L("Choose yes or no.")) : .success(nil)
        }
        let text: String = {
            if case .text(let raw)? = input { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }()
        if text.isEmpty {
            return field.required ? invalid(L("This field is required.")) : .success(nil)
        }

        switch field.kind {
        case .boolean:
            return .success(nil)
        case .choice(let choices):
            guard choices.contains(where: { $0.value == text }) else { return invalid(L("Pick one of the options.")) }
            return .success(.string(text))
        case .number(let integer, let minimum, let maximum):
            let parsed: Double?
            if integer {
                parsed = Int(text).map(Double.init)
            } else {
                parsed = Double(text)
            }
            guard let value = parsed, value.isFinite else {
                return invalid(integer ? L("Enter a whole number.") : L("Enter a number."))
            }
            if let minimum, value < minimum { return invalid(L("Must be at least \(Self.display(minimum)).")) }
            if let maximum, value > maximum { return invalid(L("Must be at most \(Self.display(maximum)).")) }
            return .success(integer ? .int(Int(value)) : .double(value))
        case .text(let format, let minLength, let maxLength):
            if let minLength, text.count < minLength {
                return invalid(L("Must be at least \(minLength) characters."))
            }
            if let maxLength, text.count > maxLength {
                return invalid(L("Must be at most \(maxLength) characters."))
            }
            if let format, !Self.matches(text, format: format) {
                switch format {
                case .email: return invalid(L("Enter a valid email address."))
                case .uri: return invalid(L("Enter a full web address, including https://."))
                case .date: return invalid(L("Enter a date as YYYY-MM-DD."))
                case .dateTime: return invalid(L("Enter a date and time as YYYY-MM-DDTHH:MM:SSZ."))
                }
            }
            return .success(.string(text))
        }
    }

    private static func display(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func matches(_ text: String, format: MCPElicitationField.StringFormat) -> Bool {
        switch format {
        case .email:
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
        case .uri:
            guard let url = URL(string: text), let scheme = url.scheme else { return false }
            return !scheme.isEmpty && (url.host?.isEmpty == false || scheme == "mailto")
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: text) != nil
        case .dateTime:
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: text) != nil { return true }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) != nil
        }
    }
}

// MARK: - Requests and outcomes

struct MCPElicitationRequest: Sendable {
    enum Mode: Sendable {
        case form(MCPElicitationForm)
        case url(URL, elicitationId: String)
    }

    let id = UUID()
    let providerName: String
    let message: String
    let mode: Mode
    /// Which MCP client asked, so the prompt can be dismissed when that
    /// client's last tool call ends.
    let clientKey: ObjectIdentifier
}

enum MCPElicitationOutcome: Equatable, Sendable {
    case accept([String: Value])
    case decline
    case cancel

    var result: CreateElicitation.Result {
        switch self {
        case .accept(let content): return .init(action: .accept, content: content)
        case .decline: return .init(action: .decline)
        case .cancel: return .init(action: .cancel)
        }
    }
}

enum MCPElicitationURLPolicy {
    /// Only web pages may be opened: `https`, or `http` on loopback for local
    /// servers. Custom schemes could launch arbitrary apps.
    static func openableURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
            let host = url.host, !host.isEmpty
        else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) { return url }
        return nil
    }
}

// MARK: - Coordinator

/// Server→client requests arrive on the SDK's message loop, outside the tool
/// call's task, so task-local context (headless eval, external caller,
/// unattended run) is captured when the call starts and looked up here.
final class MCPElicitationCoordinator: @unchecked Sendable {
    static let shared = MCPElicitationCoordinator()

    private struct ActiveCall {
        let clientKey: ObjectIdentifier
        let interactive: Bool
        let clock: MCPActivityClock
    }

    private let lock = NSLock()
    private var calls: [UUID: ActiveCall] = [:]

    /// Whether the current task can show a prompt to a person. Mirrors the
    /// approval gate's headless/external/unattended denials; a paired phone
    /// cannot answer an elicitation form, so external runs always cancel.
    static var currentTaskCanPrompt: Bool {
        !ChatExecutionContext.denyUnapprovedToolPrompts
            && !ChatExecutionContext.isExternalSurface
            && !ChatExecutionContext.isUnattendedDispatch
    }

    func beginCall(client: MCP.Client, interactive: Bool, clock: MCPActivityClock) -> UUID {
        let token = UUID()
        lock.withLock {
            calls[token] = ActiveCall(clientKey: ObjectIdentifier(client), interactive: interactive, clock: clock)
        }
        return token
    }

    func endCall(_ token: UUID) {
        let orphaned: ObjectIdentifier? = lock.withLock {
            guard let call = calls.removeValue(forKey: token) else { return nil }
            return calls.values.contains { $0.clientKey == call.clientKey } ? nil : call.clientKey
        }
        if let orphaned {
            Task { @MainActor in MCPElicitationPromptService.cancel(clientKey: orphaned) }
        }
    }

    func handle(
        _ params: CreateElicitation.Parameters,
        clientKey: ObjectIdentifier,
        providerName: String
    ) async throws -> CreateElicitation.Result {
        let (interactive, clocks) = lock.withLock { () -> (Bool, [MCPActivityClock]) in
            let active = calls.values.filter { $0.clientKey == clientKey }
            return (active.contains { $0.interactive }, active.map(\.clock))
        }
        guard interactive else { return MCPElicitationOutcome.cancel.result }

        let request: MCPElicitationRequest
        switch params {
        case .form(let form):
            let parsed: MCPElicitationForm
            do {
                parsed = try MCPElicitationForm.parse(form.requestedSchema)
            } catch let error as MCPElicitationSchemaError {
                throw MCPError.invalidParams("Unsupported elicitation schema: \(error.reason)")
            }
            request = MCPElicitationRequest(
                providerName: providerName, message: form.message, mode: .form(parsed), clientKey: clientKey)
        case .url(let url):
            guard let target = MCPElicitationURLPolicy.openableURL(url.url) else {
                throw MCPError.invalidParams("Elicitation URL must be https")
            }
            request = MCPElicitationRequest(
                providerName: providerName, message: url.message,
                mode: .url(target, elicitationId: url.elicitationId), clientKey: clientKey)
        }

        // The user filling in a form is not the server going quiet.
        clocks.forEach { $0.hold() }
        defer { clocks.forEach { $0.release() } }

        return await MCPElicitationPromptService.present(request).result
    }

    func complete(elicitationId: String) {
        Task { @MainActor in MCPElicitationPromptService.markCompleted(elicitationId: elicitationId) }
    }
}
