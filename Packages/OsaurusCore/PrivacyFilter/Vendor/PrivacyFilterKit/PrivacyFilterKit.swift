//
//  PrivacyFilterKit.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5.
//

import Foundation

public enum ModelSource: Sendable {
    case bundle(Bundle, subdirectory: String?)
    case directory(URL)
}

public struct Entity: Sendable, Equatable {
    public let type: EntityType
    public let text: String
    public let range: Range<String.Index>

    public init(type: EntityType, text: String, range: Range<String.Index>) {
        self.type = type
        self.text = text
        self.range = range
    }
}

/// Debug-build-only diagnostics. Off by default; flip
/// `PrivacyFilterKitDiagnostics.traceInference = true` from a unit test
/// or `lldb` session to dump the per-token argmax + viterbi summary on
/// every `extractEntities` call.
#if DEBUG
    public enum PrivacyFilterKitDiagnostics {
        /// Whether `extractEntities` should print per-token logit summaries
        /// + decoder traces to stdout. Reads racily from many tasks — that's
        /// acceptable for a developer-only knob.
        public nonisolated(unsafe) static var traceInference: Bool = false
    }
#endif

public actor PrivacyFilterKit {
    private let tokenizer: TokenizerWrapper
    private let model: PrivacyFilterModel
    private let decoder: BIOESDecoder
    private let labels: BIOESLabelTable

    /// Bounded LRU of (text → Encoded). `OffsetMapper.map` does an
    /// `O(tokens × text)` reconstruction of UTF-8 spans because
    /// swift-transformers doesn't expose offsets natively, so the
    /// encode path is the largest pre-forward cost on the hot
    /// segment loop. Caching pays off for:
    ///   * tool args that repeat verbatim across turns,
    ///   * system / persona prompts the chat layer re-sends, and
    ///   * the latest-user-turn rescans that happen when the user
    ///     edits a single character and re-submits.
    /// Segments larger than `cacheMaxKeyBytes` skip the cache so
    /// one giant paste can't blow memory.
    private var encodeCache: [String: Encoded] = [:]
    private var encodeCacheOrder: [String] = []
    private static let encodeCacheCapacity: Int = 32
    private static let cacheMaxKeyBytes: Int = 4_096

    public init(source: ModelSource) async throws {
        let bundle = try ModelLoader.resolve(source: source)
        self.labels = bundle.labels
        self.tokenizer = try await TokenizerWrapper(directory: bundle.directory)
        self.model = try PrivacyFilterModel(directory: bundle.directory, config: bundle.modelConfig)
        self.decoder = BIOESDecoder(labels: bundle.labels, transitions: bundle.transitions)
    }

    private func cachedEncode(_ text: String) throws -> Encoded {
        let cacheable = text.utf8.count <= Self.cacheMaxKeyBytes
        if cacheable, let hit = encodeCache[text] {
            if let idx = encodeCacheOrder.firstIndex(of: text) {
                encodeCacheOrder.remove(at: idx)
            }
            encodeCacheOrder.append(text)
            return hit
        }
        let encoded = try tokenizer.encode(text)
        guard cacheable else { return encoded }
        encodeCache[text] = encoded
        encodeCacheOrder.append(text)
        if encodeCacheOrder.count > Self.encodeCacheCapacity {
            let evict = encodeCacheOrder.removeFirst()
            encodeCache.removeValue(forKey: evict)
        }
        return encoded
    }

    public func extractNames(from text: String) async throws -> [String] {
        let entities = try await extractEntities(from: text)
        var seen = Set<String>()
        var ordered: [String] = []
        for entity in entities where entity.type == .person {
            if seen.insert(entity.text).inserted {
                ordered.append(entity.text)
            }
        }
        return ordered
    }

    public func extractEntities(from text: String) async throws -> [Entity] {
        let encoded = try cachedEncode(text)
        let logits = try model.forward(inputIds: encoded.ids)

        // Diagnostic dump: argmax-per-token + viterbi summary. Gated
        // behind `#if DEBUG` because each call walks the entire
        // [tokens × labels] logit matrix and prints to stdout, and
        // `extractEntities` runs once per scrubbable segment per send.
        // Release builds skip the work entirely.
        #if DEBUG
            if PrivacyFilterKitDiagnostics.traceInference {
                Self.dumpInferenceTrace(
                    text: text,
                    ids: encoded.ids,
                    logits: logits,
                    labels: labels
                )
            }
        #endif

        let labelIds = decoder.decode(logits: logits)
        #if DEBUG
            if PrivacyFilterKitDiagnostics.traceInference {
                Self.dumpDecoderTrace(labelIds: labelIds, labels: labels)
            }
        #endif
        return SpanBuilder.entities(
            labelIds: labelIds,
            labels: labels,
            offsets: encoded.offsets,
            text: text
        )
    }

    private static func dumpInferenceTrace(
        text: String,
        ids: [Int],
        logits: [[Float]],
        labels: BIOESLabelTable
    ) {
        print("[PrivacyFilter Inference] text=\(text.prefix(80))…  tokens=\(ids.count)")
        guard let first = logits.first else {
            print("[PrivacyFilter Inference] (no logits produced)")
            return
        }
        let numLabels = first.count
        var argmaxPerToken: [Int] = []
        var maxLogitPerToken: [Float] = []
        for row in logits {
            var bestIdx = 0
            var bestVal = -Float.infinity
            for j in 0 ..< row.count where row[j] > bestVal {
                bestVal = row[j]
                bestIdx = j
            }
            argmaxPerToken.append(bestIdx)
            maxLogitPerToken.append(bestVal)
        }
        let sampleCount = min(30, argmaxPerToken.count)
        let pairs = (0 ..< sampleCount).map { i -> String in
            let id = argmaxPerToken[i]
            let raw = labels.labels.first(where: { $0.id == id })?.raw ?? "?"
            return "\(i):\(raw)(\(String(format: "%.2f", maxLogitPerToken[i])))"
        }
        print(
            "[PrivacyFilter Inference] numLabels=\(numLabels) argmax(0..<\(sampleCount))="
                + pairs.joined(separator: " ")
        )
        let nonO = argmaxPerToken.filter { $0 != labels.outsideId }.count
        print("[PrivacyFilter Inference] non-O argmax tokens: \(nonO) / \(argmaxPerToken.count)")
    }

    private static func dumpDecoderTrace(labelIds: [Int], labels: BIOESLabelTable) {
        let nonO = labelIds.filter { $0 != labels.outsideId }.count
        let sample = labelIds.prefix(30).map { id -> String in
            labels.labels.first(where: { $0.id == id })?.raw ?? "?"
        }
        print("[PrivacyFilter Inference] viterbi non-O: \(nonO) / \(labelIds.count); first30=\(sample)")
    }
}
