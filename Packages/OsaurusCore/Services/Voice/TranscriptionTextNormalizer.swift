//
//  TranscriptionTextNormalizer.swift
//  osaurus
//
//  Normalizes voice transcription text before insertion or send.
//

import Foundation

public enum TranscriptionTextNormalizer {
    private static let invisibleScalars = CharacterSet(charactersIn: "\u{00AD}\u{034F}\u{061C}\u{180E}\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2060}\u{2061}\u{2062}\u{2063}\u{2064}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}\u{FFFE}")

    public static func visibleText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            if invisibleScalars.contains(scalar) { return false }
            if CharacterSet.controlCharacters.contains(scalar),
                scalar != "\n",
                scalar != "\t"
            {
                return false
            }
            return true
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func hasVisibleText(_ text: String) -> Bool {
        !visibleText(text).isEmpty
    }

    public static func combined(_ parts: [String]) -> String {
        parts
            .map(visibleText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func merged(existing: String, transcript: String) -> String {
        let existing = visibleText(existing)
        let transcript = visibleText(transcript)
        if existing.isEmpty { return transcript }
        if transcript.isEmpty { return existing }
        return "\(existing) \(transcript)"
    }
}
