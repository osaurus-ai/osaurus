//
//  RequestValidator.swift
//  OsaurusCore
//
//  Pure helper for accepting/rejecting sampler params before they reach
//  the chat engine. Lives in OsaurusCore at module level (not on
//  HTTPHandler) so external packages — notably OsaurusEvalsKit — can
//  exercise it as a regression suite without taking a dependency on
//  the NIO ChannelHandler. The HTTP layer wraps this helper to keep the
//  reject-with-400 logic in one place.
//

import Foundation
import MLXLMCommon

public enum RequestValidator {
    /// Validate original schema bytes before JSONValue's Double representation
    /// can round numeric const/enum values. Ordinary request numbers are untouched.
    static func rawResponseSchemaReason(_ data: Data, responses: Bool) -> String? {
        // JSONDecoder accepts UTF-16/32 too. Normalize text encoding only,
        // preserving number spelling so those encodings cannot bypass preflight.
        let prefix = Array(data.prefix(4))
        let encoding: String.Encoding
        if prefix.starts(with: [0, 0, 254, 255]) || (prefix.count == 4 && prefix[0...2].allSatisfy({ $0 == 0 })) {
            encoding = .utf32BigEndian
        } else if prefix.starts(with: [255, 254, 0, 0]) || (prefix.count == 4 && prefix[1...3].allSatisfy({ $0 == 0 })) {
            encoding = .utf32LittleEndian
        } else if prefix.starts(with: [254, 255]) || (prefix.count >= 2 && prefix[0] == 0) {
            encoding = .utf16BigEndian
        } else if prefix.starts(with: [255, 254]) || (prefix.count >= 2 && prefix[1] == 0) {
            encoding = .utf16LittleEndian
        } else { encoding = .utf8 }
        guard var text = String(data: data, encoding: encoding) else { return nil } // decoder rejects malformed encoding
        if text.first == "\u{feff}" { text.removeFirst() }
        let source = SchemaJSONSlices(bytes: Array(text.utf8))
        let formatPath = responses ? ["text", "format"] : ["response_format"]
        for format in source.values(at: formatPath) {
            let types = source.members(named: "type", in: format)
            guard types.contains(where: { source.string(in: $0) == "json_schema" }) else { continue }
            let payloads = responses ? [format] : source.members(named: "json_schema", in: format)
            for payload in payloads {
                for schema in source.members(named: "schema", in: payload) {
                    do {
                        try JSONSchemaGrammar.validateSupportedSchema(
                            String(decoding: source.bytes[schema], as: UTF8.self))
                    } catch { return "Unsupported JSON schema: \(error.localizedDescription)" }
                }
            }
        }
        return nil
    }

    static func responseFormatReason(_ format: ResponseFormat?) -> String? {
        guard let format else { return nil }
        guard format.type == "json_schema" else { return nil }
        guard let payload = format.json_schema else {
            return "response_format.json_schema is required for json_schema output."
        }
        guard !payload.name.isEmpty, payload.name.count <= 64,
            payload.name.unicodeScalars.allSatisfy({
                (65...90).contains($0.value) || (97...122).contains($0.value)
                    || (48...57).contains($0.value) || $0 == "_" || $0 == "-"
            }) else { return "json_schema.name must contain 1–64 letters, digits, underscores or hyphens." }
        do {
            try JSONSchemaGrammar.validateSupportedSchema(payload.encodedSchema())
            return nil
        } catch {
            return "Unsupported JSON schema: \(error.localizedDescription)"
        }
    }


    /// Reasons we reject a `ChatCompletionRequest` (or its primitive
    /// equivalents) outright with HTTP 400. We only flag the cases our
    /// docs declare unsupported (`n>1`, unknown response formats,
    /// etc.) — any field we silently ignored historically continues to
    /// be ignored here so we don't regress on existing clients.
    ///
    /// Returns `nil` when the request is acceptable; otherwise a
    /// human-readable explanation suitable for the 400 body.
    public static func unsupportedSamplerReason(
        n: Int?,
        responseFormatType: String?,
        logprobs: Bool? = nil,
        topLogprobs: Int? = nil
    ) -> String? {
        if let n, n > 1 {
            return "Parameter 'n' > 1 is not supported. Submit one request per completion."
        }
        if let type = responseFormatType {
            switch type {
            case "json_object", "text", "json_schema":
                break  // supported / no-op
            default:
                return
                    "response_format type '\(type)' is not supported. Use 'json_object' or a supported 'json_schema' format."
            }
        }
        // Neither local MLX decode nor the remote provider proxy surfaces
        // token log-probabilities; reject explicitly instead of returning a
        // response that silently lacks the requested field.
        if logprobs == true {
            return "Parameter 'logprobs' is not supported."
        }
        if let topLogprobs, topLogprobs > 0 {
            return "Parameter 'top_logprobs' is not supported."
        }
        return nil
    }
}

/// Finds untouched JSON value spans along a short object-key path. It does not
/// replace JSONDecoder's syntax validation. Skipping unrelated values is iterative
/// so deeply nested chat/tool payloads do not add recursive stack use. All matching
/// duplicate keys are checked, rather than choosing a lossy parser's winner.
private struct SchemaJSONSlices {
    let bytes: [UInt8]

    func string(in range: Range<Int>) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(bytes[range]))
    }

    private func skipSpace(_ index: inout Int, end: Int) {
        while index < end && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }

    private func stringEnd(_ start: Int, end: Int) -> Int? {
        guard start < end, bytes[start] == 34 else { return nil }
        var i = start + 1
        while i < end {
            if bytes[i] == 34 { return i + 1 }
            if bytes[i] == 92 { i += 1 }
            i += 1
        }
        return nil
    }

    private func valueEnd(_ start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
        if bytes[start] == 34 { return stringEnd(start, end: end) }
        if bytes[start] == 123 || bytes[start] == 91 {
            var stack: [UInt8] = [], i = start
            while i < end {
                switch bytes[i] {
                case 34:
                    guard let next = stringEnd(i, end: end) else { return nil }
                    i = next
                    continue
                case 123: stack.append(125)
                case 91: stack.append(93)
                case 125, 93:
                    guard stack.popLast() == bytes[i] else { return nil }
                    if stack.isEmpty { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        }
        var i = start
        while i < end && ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[i]) { i += 1 }
        return i > start ? i : nil
    }

    func members(named name: String, in range: Range<Int>) -> [Range<Int>] {
        var i = range.lowerBound
        skipSpace(&i, end: range.upperBound)
        guard i < range.upperBound, bytes[i] == 123 else { return [] }
        i += 1
        var matches: [Range<Int>] = []
        while i < range.upperBound {
            skipSpace(&i, end: range.upperBound)
            if i < range.upperBound, bytes[i] == 125 { return matches }
            guard let keyEnd = stringEnd(i, end: range.upperBound),
                  let key = string(in: i..<keyEnd) else { return [] }
            i = keyEnd
            skipSpace(&i, end: range.upperBound)
            guard i < range.upperBound, bytes[i] == 58 else { return [] }
            i += 1
            skipSpace(&i, end: range.upperBound)
            guard let end = valueEnd(i, end: range.upperBound) else { return [] }
            if key == name { matches.append(i..<end) }
            i = end
            skipSpace(&i, end: range.upperBound)
            guard i < range.upperBound else { return [] }
            if bytes[i] == 125 { return matches }
            guard bytes[i] == 44 else { return [] }
            i += 1
        }
        return []
    }

    func values(at path: [String]) -> [Range<Int>] {
        path.reduce([bytes.startIndex..<bytes.endIndex]) { ranges, key in
            ranges.flatMap { members(named: key, in: $0) }
        }
    }
}
