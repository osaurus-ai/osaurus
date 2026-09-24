import Foundation

/// One contract for user-authored routing metadata. Legacy records remain
/// readable; creation, editing and delegation decide how to surface repair.
public enum AgentDescriptionPolicy {
    public static let maximumCharacters = 160
    public static let maximumUTF8Bytes = 1_024

    public enum Violation: String, Error, LocalizedError, Sendable, Equatable {
        case required
        case tooLong
        case oversizedUnicode
        case controlCharacters

        public var errorDescription: String? { message }

        public var message: String {
            switch self {
            case .required:
                return "Add a description explaining what this agent does and when to use it."
            case .tooLong:
                return "Keep the description to 160 characters or fewer."
            case .oversizedUnicode:
                return "The description exceeds 1,024 UTF-8 bytes. Shorten the combined Unicode characters."
            case .controlCharacters:
                return "Use one line without control or text-direction characters."
            }
        }
    }

    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func violation(in value: String) -> Violation? {
        let text = normalized(value)
        // Combining marks, joiners and whitespace alone are not a description.
        // Keep joiners/variation selectors inside normal emoji and scripts.
        guard text.unicodeScalars.contains(where: {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
                .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation,
                .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return true
            default: return false
            }
        }) else { return .required }
        guard text.count <= maximumCharacters else { return .tooLong }
        guard text.utf8.count <= maximumUTF8Bytes else { return .oversizedUnicode }
        let forbiddenDirection: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B,
            0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        guard !text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
                || CharacterSet.newlines.contains($0)
                || forbiddenDirection.contains($0.value)
        }) else { return .controlCharacters }
        return nil
    }

    public static func validated(_ value: String) throws -> String {
        if let violation = violation(in: value) { throw violation }
        return normalized(value)
    }

    /// Quotes user text as data, including delimiters and control characters
    /// in names. Descriptions never change authorization or execution policy.
    public static func routingJSON(id: String, name: String, description: String) -> String? {
        guard let description = try? validated(description),
            let data = try? JSONSerialization.data(
                withJSONObject: ["id": id, "name": name, "description": description],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
