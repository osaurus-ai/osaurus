//
//  WorkflowFormPrompt.swift
//  osaurus
//
//  Answers a workflow form (`pending_dialog` from `GET /workflows/runs/{id}`)
//  in the terminal, one field at a time. Secret fields are read without echo.
//

import Darwin
import Foundation

enum WorkflowFormPrompt {
    struct IO: Sendable {
        var write: @Sendable (String) -> Void
        var readLine: @Sendable () -> String?
        var readSecret: @Sendable (String) -> String?

        static let terminal = IO(
            write: { fputs($0, stderr) },
            readLine: { Swift.readLine(strippingNewline: true) },
            readSecret: { prompt in
                var buffer = [CChar](repeating: 0, count: 4096)
                guard let line = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
                return String(cString: line)
            }
        )
    }

    /// The answers, keyed by field. A blank answer keeps the prefilled or
    /// default value; an optional field left blank is omitted.
    static func ask(_ dialog: [String: Any], issues: [String] = [], io: IO = .terminal) -> [String: Any] {
        let title = dialog["title"] as? String ?? "Input needed"
        io.write("\n\(title)\n")
        if let message = dialog["message"] as? String, !message.isEmpty { io.write("\(message)\n") }
        for issue in issues { io.write("  ! \(issue)\n") }
        let prefill = dialog["prefill"] as? [String: Any] ?? [:]
        var values: [String: Any] = [:]
        for field in dialog["fields"] as? [[String: Any]] ?? [] {
            guard let key = field["key"] as? String else { continue }
            let fallback = prefill[key] ?? field["default"]
            if let value = askField(field, fallback: fallback.flatMap { $0 is NSNull ? nil : $0 }, io: io) {
                values[key] = value
            }
        }
        return values
    }

    private static func askField(_ field: [String: Any], fallback: Any?, io: IO) -> Any? {
        let key = field["key"] as? String ?? ""
        let label = field["label"] as? String ?? key
        let type = field["type"] as? String ?? "text"
        let required = field["required"] as? Bool ?? true
        let options = field["options"] as? [String] ?? []
        if let help = field["help"] as? String, !help.isEmpty { io.write("  \(help)\n") }

        var hint = ""
        switch type {
        case "bool": hint = " [y/n]"
        case "number": hint = " (number)"
        case "date": hint = " (YYYY-MM-DD)"
        case "file", "folder": hint = " (path)"
        case "choice":
            for (index, option) in options.enumerated() { io.write("    \(index + 1)) \(option)\n") }
        default: break
        }
        if let fallback, type != "secret" { hint += " [\(display(fallback))]" }
        if !required { hint += " (optional)" }

        while true {
            let prompt = "\(label)\(hint): "
            let answer: String?
            if type == "secret" {
                answer = io.readSecret(prompt)
            } else {
                io.write(prompt)
                answer = io.readLine()
            }
            let text = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                if let fallback { return fallback }
                if !required { return nil }
                if answer == nil { return nil }
                io.write("  This field is required.\n")
                continue
            }
            switch parse(text, type: type, options: options) {
            case .success(let value): return value
            case .failure(let problem): io.write("  \(problem.message)\n")
            }
        }
    }

    struct Problem: Error { let message: String }

    static func parse(_ text: String, type: String, options: [String]) -> Result<Any, Problem> {
        switch type {
        case "number":
            guard let number = Double(text) else { return .failure(Problem(message: "Enter a number.")) }
            return .success(number)
        case "bool":
            switch text.lowercased() {
            case "y", "yes", "true", "1": return .success(true)
            case "n", "no", "false", "0": return .success(false)
            default: return .failure(Problem(message: "Enter y or n."))
            }
        case "choice":
            if let index = Int(text), options.indices.contains(index - 1) { return .success(options[index - 1]) }
            if let match = options.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                return .success(match)
            }
            return .failure(Problem(message: "Pick one of the numbers above."))
        case "file", "folder":
            return .success((text as NSString).expandingTildeInPath)
        default:
            return .success(text)
        }
    }

    private static func display(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "y" : "n" }
        if let number = value as? NSNumber { return number.stringValue }
        return "\(value)"
    }
}
