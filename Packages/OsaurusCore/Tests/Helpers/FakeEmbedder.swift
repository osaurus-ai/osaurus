//
//  FakeEmbedder.swift
//  osaurus
//
//  Test double conforming to VecturaEmbedder for isolated VecturaKit tests.
//  Returns fixed-dimension vectors without downloading any model.
//

import Foundation
import VecturaKit

struct FakeEmbedder: VecturaEmbedder {
    let fixedDimension: Int

    var dimension: Int {
        get async throws { fixedDimension }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0.0, count: fixedDimension)
            for (i, byte) in text.utf8.prefix(fixedDimension).enumerated() {
                vector[i] = Float(byte) / 255.0
            }
            return vector
        }
    }
}
