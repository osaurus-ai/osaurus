//
//  TranscriptionTextNormalizer.swift
//  osaurus
//
//  Normalizes voice transcription text before insertion or send.
//

import Foundation

public enum TranscriptionTextNormalizer {
    private static let noiseScalars = CharacterSet(charactersIn: "\u{00AD}\u{034F}\u{180E}\u{200B}\u{2060}\u{2061}\u{2062}\u{2063}\u{2064}\u{FEFF}\u{FFFE}")
    private static let formatOnlyScalars = CharacterSet(charactersIn: "\u{061C}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    public static func visibleText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            if noiseScalars.contains(scalar) { return false }
            if formatOnlyScalars.contains(scalar) { return true }
            if CharacterSet.controlCharacters.contains(scalar),
                scalar != "\n",
                scalar != "\t"
            {
                return false
            }
            return true
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsVisibleScalar(cleaned) else { return "" }
        return cleaned
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

    private static func containsVisibleScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if noiseScalars.contains(scalar) || formatOnlyScalars.contains(scalar) { return false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            return true
        }
    }
}
