import CryptoKit
import Foundation

/// Shared helpers for the optional agent description. A description is free
/// text: it is never required, never blocks a save, and never gates
/// delegation. These helpers only normalize it for display/routing and quote
/// it as data when it reaches a model.
public enum AgentDescriptionPolicy {
    /// Soft cap applied to background-generated summaries so a roster row
    /// stays one line. User text is never truncated.
    public static let generatedMaximumCharacters = 160

    /// Trims and collapses the text to a single line.
    public static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isNewline }) else { return trimmed }
        return trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Stable identity of the system prompt a generated description came
    /// from. A prompt edit changes the hash and invalidates the summary.
    public static func promptHash(_ systemPrompt: String) -> String {
        let data = Data(normalized(systemPrompt).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Quotes user text as data, including delimiters and control characters
    /// in names. Descriptions never change authorization or execution policy.
    /// The `description` key is omitted when there is nothing to say.
    public static func routingJSON(id: String, name: String, description: String) -> String {
        var object: [String: String] = ["id": id, "name": name]
        let text = normalized(description)
        if !text.isEmpty { object["description"] = text }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            // Only reachable if Foundation cannot serialize plain strings.
            return "{\"id\":\"\(id)\",\"name\":\"\(name)\"}"
        }
        return json
    }
}
