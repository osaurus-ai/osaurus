//
//  LocalGrammarTokenizerProbe.swift
//  osaurus
//
//  Whether an installed MLX bundle's tokenizer can drive vmlx's grammar-
//  constrained decoding (`GrammarTokenVocabulary.fromTokenizerJSON`). The
//  engine admits BPE with a plain ByteLevel decoder, no continuing-subword
//  prefix or end-of-word suffix, and `clean_up_tokenization_spaces: false`.
//
//  The runtime check decodes the whole `tokenizer.json` (10 MB+ for current
//  vocabularies, 100–250 ms) and walks every piece. That is far too slow for
//  the model pickers and setup checks that ask this question on the main
//  thread for every installed model, so this probe reads only the declaring
//  metadata: it scans the file's top-level members and stops inside `model`
//  at `vocab`/`merges`, never materialising the vocabulary. Results are
//  cached per bundle path. The engine's own validation at request
//  preparation remains authoritative; a bundle this probe admits but the
//  engine rejects fails with the engine's typed error.
//

import Foundation

enum LocalGrammarTokenizerProbe {

    /// Why a bundle cannot drive constrained decoding, in user words.
    static let unsupportedReason =
        "its tokenizer isn't supported by local constrained decoding (a byte-level BPE tokenizer is needed), so the schema could only be requested in the prompt."

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// Whether the bundle at `directory` declares a tokenizer the engine's
    /// grammar adapter accepts. Cached by path.
    static func supports(bundle directory: URL) -> Bool {
        let key = directory.standardizedFileURL.path
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let value = declaresSupportedTokenizer(in: directory)
        lock.lock()
        cache[key] = value
        lock.unlock()
        return value
    }

    /// Test hook: forget every cached answer.
    static func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Uncached read of the bundle's `tokenizer.json` and
    /// `tokenizer_config.json`.
    static func declaresSupportedTokenizer(in directory: URL) -> Bool {
        guard
            let tokenizer = try? Data(contentsOf: directory.appendingPathComponent("tokenizer.json")),
            let config = try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))
        else { return false }
        return declaresSupportedTokenizer(tokenizerJSON: tokenizer, tokenizerConfig: config)
    }

    /// Pure form over file contents.
    static func declaresSupportedTokenizer(tokenizerJSON: Data, tokenizerConfig: Data) -> Bool {
        // The engine requires the key to be present and false; a missing key
        // fails its decode and is unsupported.
        guard let config = try? JSONSerialization.jsonObject(with: tokenizerConfig) as? [String: Any],
            let cleanup = config["clean_up_tokenization_spaces"] as? NSNumber,
            CFGetTypeID(cleanup) == CFBooleanGetTypeID(), !cleanup.boolValue
        else { return false }
        guard let metadata = TokenizerMetadata(scanning: tokenizerJSON) else { return false }
        return metadata.modelType == "BPE"
            && metadata.decoderType == "ByteLevel"
            && metadata.continuingSubwordPrefix?.isEmpty != false
            && metadata.endOfWordSuffix?.isEmpty != false
    }

    /// The declaring fields of a `tokenizer.json`, read without parsing the
    /// vocabulary.
    struct TokenizerMetadata: Equatable {
        var modelType: String?
        var decoderType: String?
        var continuingSubwordPrefix: String?
        var endOfWordSuffix: String?

        init(
            modelType: String? = nil, decoderType: String? = nil,
            continuingSubwordPrefix: String? = nil, endOfWordSuffix: String? = nil
        ) {
            self.modelType = modelType
            self.decoderType = decoderType
            self.continuingSubwordPrefix = continuingSubwordPrefix
            self.endOfWordSuffix = endOfWordSuffix
        }

        /// Nil when the document is not a JSON object.
        init?(scanning data: Data) {
            var scanner = JSONMemberScanner(bytes: [UInt8](data))
            guard scanner.enterObject() else { return nil }
            while let key = scanner.nextKey() {
                switch key {
                case "decoder":
                    guard let slice = scanner.valueSlice() else { return nil }
                    let decoder = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any]
                    decoderType = decoder?["type"] as? String
                case "model":
                    guard scanner.enterObject() else { return nil }
                    var stoppedAtVocabulary = false
                    scan: while let modelKey = scanner.nextKey() {
                        switch modelKey {
                        case "type":
                            modelType = scanner.stringValue()
                        case "continuing_subword_prefix":
                            continuingSubwordPrefix = scanner.stringValue()
                        case "end_of_word_suffix":
                            endOfWordSuffix = scanner.stringValue()
                        case "vocab", "merges":
                            // Serialised after the declaring fields; stop
                            // before the expensive part. Remaining fields are
                            // read as absent.
                            stoppedAtVocabulary = true
                            break scan
                        default:
                            guard scanner.skipValue() else { return nil }
                        }
                    }
                    // `decoder` normally precedes `model`; with both read
                    // there is nothing left to learn, so the vocabulary is
                    // never walked. Otherwise skip past it and keep looking.
                    if decoderType != nil { return }
                    if stoppedAtVocabulary { scanner.leaveObjectAfterBreak() }
                default:
                    guard scanner.skipValue() else { return nil }
                }
            }
        }
    }
}

/// Forward-only member scanner over UTF-8 JSON bytes. It validates only as
/// much structure as it needs to find keys and value spans; it is not a
/// general parser.
struct JSONMemberScanner {
    let bytes: [UInt8]
    private var index = 0
    /// True just after `enterObject`, so `nextKey` does not expect a comma
    /// before the first member.
    private var expectingFirstMember = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipSpace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    /// Consume `{`; false when the next value is not an object.
    mutating func enterObject() -> Bool {
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return false }
        index += 1
        expectingFirstMember = true
        return true
    }

    /// The next member key in the current object, positioned before its
    /// value; nil at the object's end or on malformed input.
    mutating func nextKey() -> String? {
        skipSpace()
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "}") {
            index += 1
            expectingFirstMember = false
            return nil
        }
        if !expectingFirstMember {
            guard bytes[index] == UInt8(ascii: ",") else { return nil }
            index += 1
            skipSpace()
        }
        expectingFirstMember = false
        guard let keyEnd = stringEnd(from: index) else { return nil }
        let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index ..< keyEnd]))
        index = keyEnd
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
        index += 1
        return key
    }

    /// The current value as a string, consumed; nil when it is not a JSON
    /// string (`null`, a number, …), which is consumed as well.
    mutating func stringValue() -> String? {
        skipSpace()
        guard let end = stringEnd(from: index) else {
            _ = skipValue()
            return nil
        }
        let value = try? JSONDecoder().decode(String.self, from: Data(bytes[index ..< end]))
        index = end
        return value
    }

    /// The raw bytes of the current value, consumed.
    mutating func valueSlice() -> ArraySlice<UInt8>? {
        skipSpace()
        let start = index
        guard let end = valueEnd(from: start) else { return nil }
        index = end
        return bytes[start ..< end]
    }

    /// Skip the current value.
    mutating func skipValue() -> Bool {
        valueSlice() != nil
    }

    /// After breaking out of an object's member loop, skip to just past its
    /// close brace. Only valid immediately after `nextKey` returned a key
    /// whose value has not been consumed.
    mutating func leaveObjectAfterBreak() {
        // Consume the pending value, then members until the close brace.
        guard skipValue() else {
            index = bytes.count
            return
        }
        while true {
            skipSpace()
            guard index < bytes.count else { return }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return
            }
            guard bytes[index] == UInt8(ascii: ",") else {
                index = bytes.count
                return
            }
            index += 1
            skipSpace()
            guard let keyEnd = stringEnd(from: index) else {
                index = bytes.count
                return
            }
            index = keyEnd
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                index = bytes.count
                return
            }
            index += 1
            guard skipValue() else {
                index = bytes.count
                return
            }
        }
    }

    private func stringEnd(from start: Int) -> Int? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
            if bytes[i] == UInt8(ascii: "\\") { i += 1 }
            i += 1
        }
        return nil
    }

    private func valueEnd(from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return stringEnd(from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard let next = stringEnd(from: i) else { return nil }
                    i = next
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == UInt8(ascii: ",")
                    || b == UInt8(ascii: "}") || b == UInt8(ascii: "]")
                {
                    break
                }
                i += 1
            }
            return i > start ? i : nil
        }
    }
}
