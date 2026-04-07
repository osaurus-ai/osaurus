//
//  ModelMetadataParser.swift
//  osaurus
//
//  Single source of truth for extracting metadata from model repo IDs:
//  parameter count, quantization level, and display-friendly names.
//

import Foundation

enum ModelMetadataParser {
    /// Extracts parameter count from a repo ID (e.g., "1.7B", "7B", "270M")
    static func parameterCount(from repoId: String) -> String? {
        let text = repoId.lowercased()
        let patterns = [
            #"(\d+\.?\d*)[bm](?:-|$|\s|[^a-z])"#,
            #"(\d+\.?\d*)b-"#,
            #"-(\d+\.?\d*)[bm]-"#,
            #"[- ](\d+\.?\d*)[bm]$"#,
            #"e(\d+)[bm]"#,
            #"a(\d+)[bm]"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range),
                    let numRange = Range(match.range(at: 1), in: text)
                {
                    let number = String(text[numRange])
                    let fullMatch = String(text[Range(match.range, in: text)!]).uppercased()
                    return "\(number)\(fullMatch.contains("M") ? "M" : "B")"
                }
            }
        }
        return nil
    }

    /// Extracts quantization level from a repo ID (e.g., "4-bit", "8-bit", "FP16")
    static func quantization(from repoId: String) -> String? {
        if let bits = extractBitWidth(from: repoId) { return "\(bits)-bit" }
        return precisionFormat(from: repoId)
    }

    /// Extracts quantization in Ollama-compatible format (e.g., "Q4_0", "FP16")
    static func quantizationOllama(from repoId: String) -> String? {
        if let bits = extractBitWidth(from: repoId) { return "Q\(bits)_0" }

        let text = repoId.lowercased()
        let ggufPatterns: [(String, String)] = [
            ("q4_0", "Q4_0"), ("q4_k_m", "Q4_K_M"),
            ("q8_0", "Q8_0"), ("q8_k_m", "Q8_K_M"),
        ]
        for (pattern, result) in ggufPatterns {
            if text.contains(pattern) { return result }
        }
        return precisionFormat(from: repoId)
    }

    /// Converts a Hugging Face repo ID to a display-friendly name.
    static func friendlyName(from repoId: String) -> String {
        let last = repoId.split(separator: "/").last.map(String.init) ?? repoId
        return last.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "llama", with: "Llama", options: .caseInsensitive)
            .replacingOccurrences(of: "qwen", with: "Qwen", options: .caseInsensitive)
            .replacingOccurrences(of: "gemma", with: "Gemma", options: .caseInsensitive)
            .replacingOccurrences(of: "deepseek", with: "DeepSeek", options: .caseInsensitive)
            .replacingOccurrences(of: "granite", with: "Granite", options: .caseInsensitive)
            .replacingOccurrences(of: "mistral", with: "Mistral", options: .caseInsensitive)
            .replacingOccurrences(of: "phi", with: "Phi", options: .caseInsensitive)
    }

    // MARK: - Private

    private static func extractBitWidth(from repoId: String) -> String? {
        let text = repoId.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)-?bit"#, options: .caseInsensitive)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
            let numRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[numRange])
    }

    private static func precisionFormat(from repoId: String) -> String? {
        let text = repoId.lowercased()
        if text.contains("fp16") { return "FP16" }
        if text.contains("bf16") { return "BF16" }
        if text.contains("fp32") { return "FP32" }
        return nil
    }
}
