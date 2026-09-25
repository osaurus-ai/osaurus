import Foundation
import Testing

@testable import OsaurusCore

struct ModelMetadataCacheTests {
    @Test("An invalidated background lookup cannot publish or clear its replacement")
    func staleBackgroundCompletionCannotOwnNewRead() throws {
        let cache = ModelMetadataCache<String>()
        let old = try #require(cache.begin("model", background: true))
        #expect(cache.begin("model", background: true) == nil)
        cache.invalidate()
        let current = try #require(cache.begin("model", background: true))
        #expect(!cache.finish("model", generation: old, value: "old", background: true))
        #expect(cache.lookup("model") == nil)
        #expect(cache.begin("model", background: true) == nil, "New lookup must retain ownership")
        #expect(cache.finish("model", generation: current, value: "current", background: true))
        #expect(cache.lookup("model") == "current")
    }

    @Test("Synchronous stale reads are rejected and a declared absence can be cached")
    func synchronousInvalidationAndOptionalAbsence() throws {
        let cache = ModelMetadataCache<String?>()
        let old = try #require(cache.begin("model", background: false))
        cache.invalidate()
        #expect(!cache.finish("model", generation: old, value: .some("old"), background: false))
        let current = try #require(cache.begin("model", background: false))
        #expect(cache.finish("model", generation: current, value: .some(nil), background: false))
        #expect(cache.lookup("model") != nil, "Known absence differs from an uncomputed lookup")
        #expect(cache.lookup("model")! == nil)
    }

    @Test("A provisional miss releases only its own reservation without caching")
    func provisionalMissCanRetry() throws {
        let cache = ModelMetadataCache<String>()
        let token = try #require(cache.begin("model", background: true))
        #expect(cache.finish("model", generation: token, value: nil, background: true))
        #expect(cache.lookup("model") == nil)
        #expect(cache.begin("model", background: true) != nil)
    }
}
