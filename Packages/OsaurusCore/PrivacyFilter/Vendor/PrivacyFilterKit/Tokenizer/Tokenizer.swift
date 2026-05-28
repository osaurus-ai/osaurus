//
//  Tokenizer.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5.
//
//  Osaurus-local rewires:
//    • `import Tokenizers` → `import VMLXTokenizers` (the
//      vendored swift-transformers Tokenizers module shipped
//      by osaurus-ai/vmlx-swift). Avoids dragging a second
//      copy of huggingface/swift-transformers into the graph
//      next to vmlx-swift's vendored fork. The public Tokenizer
//      protocol surface is identical.
//

import Foundation
import VMLXTokenizers

public struct TokenOffset: Sendable, Equatable {
    public let utf8Start: Int
    public let utf8End: Int
}

public struct Encoded: Sendable {
    public let ids: [Int]
    public let offsets: [TokenOffset]
}

/// Wraps swift-transformers' Tokenizer with offset mapping back to UTF-8 byte ranges.
struct TokenizerWrapper {
    private let tokenizer: any Tokenizer

    init(directory: URL) async throws {
        self.tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    }

    func encode(_ text: String) throws -> Encoded {
        let ids = tokenizer.encode(text: text)
        let offsets = OffsetMapper.map(text: text, ids: ids, tokenizer: tokenizer)
        return Encoded(ids: ids, offsets: offsets)
    }
}

enum TokenizerError: Error, Equatable {
    case missingConfig
    case offsetMappingFailed
}

/// Best-effort offset mapper. swift-transformers does not expose offset mapping directly,
/// so we reconstruct it by decoding each token and locating it in the source text.
enum OffsetMapper {
    static func map(text: String, ids: [Int], tokenizer: any Tokenizer) -> [TokenOffset] {
        let utf8 = Array(text.utf8)
        var offsets: [TokenOffset] = []
        var cursor = 0
        for id in ids {
            let piece = tokenizer.decode(tokens: [id])
            let pieceBytes = Array(piece.utf8)
            if pieceBytes.isEmpty {
                offsets.append(TokenOffset(utf8Start: cursor, utf8End: cursor))
                continue
            }
            if let found = locate(needle: pieceBytes, in: utf8, from: cursor) {
                offsets.append(TokenOffset(utf8Start: found, utf8End: found + pieceBytes.count))
                cursor = found + pieceBytes.count
            } else {
                offsets.append(TokenOffset(utf8Start: cursor, utf8End: cursor))
            }
        }
        return offsets
    }

    private static func locate(needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= haystack.count else { return nil }
        let limit = haystack.count - needle.count
        if limit < start { return nil }
        var i = start
        while i <= limit {
            if Array(haystack[i ..< (i + needle.count)]) == needle {
                return i
            }
            i += 1
        }
        return nil
    }
}
