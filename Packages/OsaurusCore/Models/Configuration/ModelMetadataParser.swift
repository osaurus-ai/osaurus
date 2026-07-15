//
//  ModelMetadataParser.swift
//  osaurus
//
//  Single source of truth for extracting metadata from model repo IDs:
//  parameter count, quantization level, and display-friendly names.
//

import Foundation

enum ModelMetadataParser {
    // MARK: - Memoization

    // `parameterCount` / `quantization` are read from `ModelRowView.metadataBadges`
    // on every SwiftUI body evaluation, for every row. Both are pure functions of an
    // immutable repo ID, so the regex work is cached the first time an ID is seen and
    // returned for free thereafter. Lock-guarded because the parser is nonisolated and
    // can be reached from background discovery tasks as well as the main actor.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var parameterCountCache: [String: String?] = [:]
    private nonisolated(unsafe) static var quantizationCache: [String: String?] = [:]

    private static let parameterCountRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(\d+\.?\d*)[bm](?:-|$|\s|[^a-z])"#,
            #"(\d+\.?\d*)b-"#,
            #"-(\d+\.?\d*)[bm]-"#,
            #"[- ](\d+\.?\d*)[bm]$"#,
            #"e(\d+)[bm]"#,
            #"a(\d+)[bm]"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Extracts parameter count from a repo ID (e.g., "1.7B", "7B", "270M")
    static func parameterCount(from repoId: String) -> String? {
        cacheLock.lock()
        if let cached = parameterCountCache[repoId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = computeParameterCount(from: repoId)

        cacheLock.lock()
        parameterCountCache[repoId] = result
        cacheLock.unlock()
        return result
    }

    /// Parameter count in billions parsed from a repo ID (e.g. "7B" -> 7.0,
    /// "270M" -> 0.27). Returns `nil` when no size token is present. Pure
    /// function of the (immutable) repo ID, so it inherits `parameterCount`'s
    /// memoization.
    static func parameterCountBillions(from repoId: String) -> Double? {
        guard let params = parameterCount(from: repoId) else { return nil }
        let text = params.uppercased()
        guard let num = Double(text.dropLast()) else { return nil }
        return text.hasSuffix("M") ? num / 1000.0 : num
    }

    private static func computeParameterCount(from repoId: String) -> String? {
        let text = repoId.lowercased()
        for regex in parameterCountRegexes {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
                let numRange = Range(match.range(at: 1), in: text)
            {
                let number = String(text[numRange])
                let fullMatch = String(text[Range(match.range, in: text)!]).uppercased()
                return "\(number)\(fullMatch.contains("M") ? "M" : "B")"
            }
        }
        return nil
    }

    /// Extracts quantization level from a repo ID (e.g., "4-bit", "8-bit", "FP16")
    static func quantization(from repoId: String) -> String? {
        cacheLock.lock()
        if let cached = quantizationCache[repoId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result: String?
        if let bits = extractBitWidth(from: repoId) {
            result = "\(bits)-bit"
        } else {
            result = precisionFormat(from: repoId)
        }

        cacheLock.lock()
        quantizationCache[repoId] = result
        cacheLock.unlock()
        return result
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

    /// Strips developer-oriented tokens (quantization, MoE active-param notation,
    /// MLX/instruction-tuned suffixes, TurboQuant labels) from a friendly name
    static func simpleName(from name: String) -> String {
        var text = name

        // whole word patterns to drop entirely (case insensitive)
        let dropPatterns: [String] = [
            #"(?i)\bmxfp\d+\b"#,  // mxfp4
            #"(?i)\bfp(16|32)\b"#,  // fp16 / fp32
            #"(?i)\bbf16\b"#,
            #"(?i)\bq\d+(_[a-z0-9]+)*\b"#,  // q4_0, q8_k_m
            #"(?i)\b\d+-?bit\b"#,  // 4bit, 4-bit, 8-bit
            #"(?i)\bmlx\b"#,
            #"(?i)\bit\b"#,  // "it" = instruction tuned
            #"(?i)\binstruct\b"#,
            #"(?i)\bchat\b"#,
            #"(?i)\bjangtq[_0-9a-z]*\b"#,  // TurboQuant variants (JANGTQ4, JANGTQ_K)
            #"(?i)\ba\d+(\.\d+)?b\b"#,  // A3B / A2.5B active param count
        ]
        for pat in dropPatterns {
            if let re = try? NSRegularExpression(pattern: pat) {
                let r = NSRange(text.startIndex..., in: text)
                text = re.stringByReplacingMatches(in: text, range: r, withTemplate: "")
            }
        }

        // "Qwen3.6" -> "Qwen 3.6": insert a space between known family
        // names and the version digit that follows
        if let re = try? NSRegularExpression(
            pattern: #"(?i)(qwen|gemma|llama|phi|mistral|deepseek|granite)(\d)"#
        ) {
            let r = NSRange(text.startIndex..., in: text)
            text = re.stringByReplacingMatches(in: text, range: r, withTemplate: "$1 $2")
        }

        // collapse repeated whitespace and trim
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        return text.isEmpty ? name : text
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

    // MARK: - Family grouping

    /// Hyphen-delimited repo-id segments that encode precision, quantization,
    /// or delivery format rather than model identity. Stripping them from a
    /// repo id yields the "family" the catalog groups by: precision variants
    /// of the same model (MXFP4 vs MXFP8 vs QAT vs JANGTQ…) collapse into one
    /// card, while genuinely different sizes (9B vs 35B, E2B vs E4B) keep
    /// their size tokens and stay separate.
    private static let variantSegmentRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^mxfp\d+$"#,  // MXFP4 / MXFP8
            #"^qat$"#,  // quantization-aware-training marker
            #"^jangtq[_0-9a-z]*$"#,  // JANGTQ / JANGTQ4 / JANGTQ_K TurboQuant
            #"^jang_?\d+[a-z]?$"#,  // JANG_4M / JANG_2S mixed precision
            #"^\d+-?bit$"#,  // 4bit / 8bit / 4-bit
            #"^(fp16|bf16|fp32)$"#,
            #"^q\d+(_[a-z0-9]+)*$"#,  // GGUF-style q4_0 / q8_k_m
            #"^mtp$"#,  // multi-token-prediction speculative decode build
            #"^mlx$"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
        }
    }()

    private nonisolated(unsafe) static var familyKeyCache: [String: String] = [:]

    /// Lowercased grouping key for collapsing precision/quant variants of the
    /// same model into a single catalog card. Keeps the org prefix so families
    /// never merge across publishers. Falls back to the full lowercased id
    /// when stripping would leave nothing.
    static func familyKey(from repoId: String) -> String {
        cacheLock.lock()
        if let cached = familyKeyCache[repoId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let kept = familySegments(from: repoId)
        let org = repoId.split(separator: "/").dropLast().joined(separator: "/")
        let tail =
            kept.isEmpty
            ? (repoId.split(separator: "/").last.map(String.init) ?? repoId)
            : kept.joined(separator: "-")
        let result = (org.isEmpty ? tail : "\(org)/\(tail)").lowercased()

        cacheLock.lock()
        familyKeyCache[repoId] = result
        cacheLock.unlock()
        return result
    }

    /// Display title for a family card: the repo tail with variant segments
    /// removed, run through the friendly-name capitalization and the
    /// developer-token stripper (drops "it"/"instruct"/active-param notation).
    static func familyDisplayName(from repoId: String) -> String {
        let kept = familySegments(from: repoId)
        guard !kept.isEmpty else { return simpleName(from: friendlyName(from: repoId)) }
        let joined = kept.joined(separator: "-")
        let name = simpleName(from: friendlyName(from: joined))
        return name.isEmpty ? friendlyName(from: repoId) : name
    }

    /// Repo-tail segments with precision/quant/delivery tokens removed,
    /// original casing preserved.
    private static func familySegments(from repoId: String) -> [String] {
        let tail = repoId.split(separator: "/").last.map(String.init) ?? repoId
        return tail.split(separator: "-").map(String.init).filter { segment in
            let range = NSRange(segment.startIndex..., in: segment)
            return !variantSegmentRegexes.contains {
                $0.firstMatch(in: segment, options: [], range: range) != nil
            }
        }
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
        if let match = text.range(
            of: #"mxfp(\d+)"#,
            options: .regularExpression
        ) {
            return String(text[match]).uppercased()
        }
        if let match = text.range(
            of: #"jangtq[_0-9a-z]*"#,
            options: .regularExpression
        ) {
            // Underscore suffixes (`JANGTQ_K`) read as "JANGTQ K" in the UI,
            // matching the JANG mixed-precision label treatment below.
            return String(text[match]).uppercased().replacingOccurrences(of: "_", with: " ")
        }
        // JANG mixed-precision labels (`JANG_4M`/`4K`/`2L`/`2S`): the leading
        // digit encodes the dominant bit-class (4 ≈ 4-bit, 2 ≈ 2-bit). Surface
        // the label (e.g. "JANG 4M") so the Quant column reflects precision
        // instead of showing "—" for these rows. Checked after `jangtq` so the
        // TurboQuant variants keep their own label.
        if let match = text.range(
            of: #"jang_?\d+[a-z]?"#,
            options: .regularExpression
        ) {
            return String(text[match]).uppercased().replacingOccurrences(of: "_", with: " ")
        }
        if text.contains("fp16") { return "FP16" }
        if text.contains("bf16") { return "BF16" }
        if text.contains("fp32") { return "FP32" }
        return nil
    }
}
