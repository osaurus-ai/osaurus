//
// Coverage for `ModelRuntime.ensureJANGTQSidecar` — the async wrapper that
// only auto-fetches `jangtq_runtime.safetensors` when the user actually
// hits the missing-sidecar error and never speculatively otherwise.
//

import Foundation
import Testing

@testable import OsaurusCore

struct EnsureJANGTQSidecarTests {

    private func makeBundle(
        weightFormat: String?,
        withSidecar: Bool
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-jangtq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let wf = weightFormat {
            let payload: [String: Any] = ["version": 2, "weight_format": wf]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: dir.appendingPathComponent("jang_config.json"))
        }
        if withSidecar {
            try Data("dummy".utf8).write(
                to: dir.appendingPathComponent("jangtq_runtime.safetensors")
            )
        }
        return dir
    }

    private actor FetchTracker {
        var calls: [(URL, URL)] = []
        var count: Int { calls.count }
        func record(_ url: URL, _ dest: URL) { calls.append((url, dest)) }
    }

    /// Sidecar already present → fetcher MUST NOT fire.
    @Test func noFetchWhenSidecarPresent() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = FetchTracker()
        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, dest in
            await tracker.record(url, dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }
        let count = await tracker.count
        #expect(count == 0)
    }

    /// Non-mxtq stamp → fetcher MUST NOT fire (no forward mismatch).
    @Test func noFetchForNonMxtqStamp() async throws {
        let dir = try makeBundle(weightFormat: "bf16", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = FetchTracker()
        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, dest in
            await tracker.record(url, dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }
        let count = await tracker.count
        #expect(count == 0)
    }

    /// No jang_config.json at all (vanilla model) → fetcher MUST NOT fire.
    @Test func noFetchForVanillaModel() async throws {
        let dir = try makeBundle(weightFormat: nil, withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = FetchTracker()
        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, dest in
            await tracker.record(url, dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }
        let count = await tracker.count
        #expect(count == 0)
    }

    /// Inverse mismatch (sidecar present, stamp says non-mxtq) → fetcher
    /// MUST NOT fire AND original error must surface (code 3).
    @Test func noFetchOnInverseMismatch() async throws {
        let dir = try makeBundle(weightFormat: "bf16", withSidecar: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = FetchTracker()
        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, dest in
            await tracker.record(url, dest)
        }

        var threw: NSError?
        do {
            try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
                try await ModelRuntime.ensureJANGTQSidecar(
                    at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
                )
            }
        } catch let e as NSError {
            threw = e
        }
        let count = await tracker.count
        #expect(count == 0)
        #expect(threw?.code == 3)
    }

    /// Forward mismatch + flat-layout id (no slash) → fetcher walks the
    /// known-org fallback list (JANGQ-AI, OsaurusAI, mlx-community); when
    /// every candidate fails it surfaces code 4, NOT code 2.
    @Test func flatLayoutIdTriesOrgFallbacks() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracker = FetchTracker()
        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, dest in
            await tracker.record(url, dest)
            // Every candidate "404s" — sidecar never written.
            throw NSError(domain: "ModelRuntime", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 404"])
        }

        var threw: NSError?
        do {
            try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
                try await ModelRuntime.ensureJANGTQSidecar(
                    at: dir, modelId: "Some-Flat-Model", name: "Flat"
                )
            }
        } catch let e as NSError {
            threw = e
        }
        let calls = await tracker.calls
        #expect(calls.count == 3)
        #expect(threw?.code == 4)
    }

    /// Forward mismatch + canonical HF id → fetcher fires ONCE, with the
    /// dynamic URL built from the model id, and validation passes after.
    @Test func fetchesOnceWithDynamicURL() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelId = "JANGQ-AI/Laguna-XS.2-JANGTQ"
        let tracker = FetchTracker()
        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, dest in
            await tracker.record(url, dest)
            try Data("real-sidecar-bytes".utf8).write(to: dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: modelId, name: "Laguna"
            )
        }

        let calls = await tracker.calls
        #expect(calls.count == 1)
        #expect(
            calls.first?.0.absoluteString
                == "https://huggingface.co/JANGQ-AI/Laguna-XS.2-JANGTQ/resolve/main/jangtq_runtime.safetensors"
        )
        #expect(
            calls.first?.1.lastPathComponent == "jangtq_runtime.safetensors"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("jangtq_runtime.safetensors").path
            )
        )
    }

    /// If the fetcher throws (network down, 404, etc.), the original missing-
    /// sidecar error gets wrapped as code 4 — caller can show "we tried, here's
    /// why it didn't work".
    @Test func wrapsFetchErrorAsCodeFour() async throws {
        let dir = try makeBundle(weightFormat: "mxtq", withSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        struct StubError: Error, Sendable { let what: String }
        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            throw StubError(what: "no network")
        }

        var threw: NSError?
        do {
            try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
                try await ModelRuntime.ensureJANGTQSidecar(
                    at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
                )
            }
        } catch let e as NSError {
            threw = e
        }
        #expect(threw?.code == 4)
        #expect(threw?.domain == "ModelRuntime")
    }
}
