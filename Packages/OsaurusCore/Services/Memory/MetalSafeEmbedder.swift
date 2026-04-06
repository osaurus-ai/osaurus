//
//  MetalSafeEmbedder.swift
//  osaurus
//
//  VecturaEmbedder wrapper that coordinates CoreML embedding with MLX
//  generation through MetalGate.  Pass this to VecturaKit instances
//  instead of the raw SwiftEmbedder so all search and indexing
//  operations are automatically Metal-safe.
//

import Foundation
import VecturaKit

public actor MetalSafeEmbedder: VecturaEmbedder {
    private let inner: SwiftEmbedder

    public init(inner: SwiftEmbedder) {
        self.inner = inner
    }

    public var dimension: Int {
        get async throws { try await inner.dimension }
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        await MetalGate.shared.enterEmbedding()
        do {
            let result = try await inner.embed(texts: texts)
            await MetalGate.shared.exitEmbedding()
            return result
        } catch {
            await MetalGate.shared.exitEmbedding()
            throw error
        }
    }

    public func embed(text: String) async throws -> [Float] {
        await MetalGate.shared.enterEmbedding()
        do {
            let result = try await inner.embed(text: text)
            await MetalGate.shared.exitEmbedding()
            return result
        } catch {
            await MetalGate.shared.exitEmbedding()
            throw error
        }
    }
}
