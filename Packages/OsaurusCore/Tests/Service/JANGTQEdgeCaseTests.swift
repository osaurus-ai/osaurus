//
// Pattern + character edge-case coverage for the JANGTQ preflight + sidecar
// auto-fetch. Goal: prove the auto-fetch CANNOT be triggered "randomly" by
// a malformed id, a casing slip in `weight_format`, or any other spelling
// variation we've seen in shipped bundles.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("isValidHFRepoId — strict org/repo gate")
struct ValidHFRepoIdTests {

    // MARK: - Accepted

    @Test func acceptsCanonicalOrgRepo() {
        #expect(ModelRuntime.isValidHFRepoId("OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4"))
        #expect(ModelRuntime.isValidHFRepoId("JANGQ-AI/Laguna-XS.2-JANGTQ"))
        #expect(ModelRuntime.isValidHFRepoId("mlx-community/Qwen3.5-MoE"))
    }

    @Test func acceptsAllAllowedSpecialChars() {
        #expect(ModelRuntime.isValidHFRepoId("a-b_c.d/e-f_g.h"))
        #expect(ModelRuntime.isValidHFRepoId("A.B-C_D/X-Y_Z.0"))
        #expect(ModelRuntime.isValidHFRepoId("0/0"))
    }

    @Test func acceptsMixedCase() {
        #expect(ModelRuntime.isValidHFRepoId("MixedCase/EvenWeIrDeR"))
    }

    // MARK: - Rejected: structural

    @Test func rejectsEmpty() {
        #expect(!ModelRuntime.isValidHFRepoId(""))
    }

    @Test func rejectsLeadingSlash() {
        #expect(!ModelRuntime.isValidHFRepoId("/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("/org/repo"))
    }

    @Test func rejectsTrailingSlash() {
        #expect(!ModelRuntime.isValidHFRepoId("org/"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo/"))
    }

    @Test func rejectsNoSlashFlatId() {
        #expect(!ModelRuntime.isValidHFRepoId("Nemotron-3-Nano-Omni"))
        #expect(!ModelRuntime.isValidHFRepoId("Foo"))
    }

    @Test func rejectsTooManySlashes() {
        #expect(!ModelRuntime.isValidHFRepoId("org/sub/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("a/b/c/d"))
    }

    @Test func rejectsEmptySegments() {
        #expect(!ModelRuntime.isValidHFRepoId("/"))
        #expect(!ModelRuntime.isValidHFRepoId("//"))
        #expect(!ModelRuntime.isValidHFRepoId("org//repo"))
    }

    // MARK: - Rejected: dangerous characters

    @Test func rejectsWhitespace() {
        #expect(!ModelRuntime.isValidHFRepoId("Org Name/Repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo name"))
        #expect(!ModelRuntime.isValidHFRepoId(" org/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo "))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\n"))
        #expect(!ModelRuntime.isValidHFRepoId("org\t/repo"))
    }

    @Test func rejectsURLMetacharacters() {
        #expect(!ModelRuntime.isValidHFRepoId("org/repo?evil=1"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo#frag"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo&x"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo;x"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo:8080"))
        #expect(!ModelRuntime.isValidHFRepoId("org@host/repo"))
    }

    @Test func rejectsPathTraversal() {
        #expect(!ModelRuntime.isValidHFRepoId("../etc/passwd"))
        #expect(!ModelRuntime.isValidHFRepoId("org/../repo"))
        #expect(!ModelRuntime.isValidHFRepoId("..//.."))
    }

    @Test func rejectsControlAndUnicode() {
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\u{0000}"))
        #expect(!ModelRuntime.isValidHFRepoId("org/répo"))
        #expect(!ModelRuntime.isValidHFRepoId("組織/レポ"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\u{FEFF}"))
    }

    @Test func rejectsBackslashesAndQuotes() {
        #expect(!ModelRuntime.isValidHFRepoId("org\\repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/repo\""))
        #expect(!ModelRuntime.isValidHFRepoId("org/'repo"))
    }

    @Test func rejectsExtremelyLongSegments() {
        let huge = String(repeating: "a", count: 200)
        #expect(!ModelRuntime.isValidHFRepoId("\(huge)/repo"))
        #expect(!ModelRuntime.isValidHFRepoId("org/\(huge)"))
    }
}

/// Helper: build a temp bundle dir whose `jang_config.json` carries the
/// supplied raw `weight_format` value, encoded via `JSONSerialization` so
/// control characters (tabs, newlines) round-trip properly through JSON's
/// escape rules instead of producing invalid JSON.
private func makeBundle(weightFormatRaw: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("osu-jangtq-edge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let raw = weightFormatRaw {
        let payload: [String: Any] = ["weight_format": raw]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent("jang_config.json"))
    }
    return dir
}

@Suite struct WeightFormatNormalizationTests {

    /// All these stamp variants must be treated as JANGTQ — forward
    /// mismatch — fetcher fires (no sidecar present).
    @Test(arguments: [
        "mxtq", "MXTQ", "Mxtq", "mXtQ", " mxtq", "mxtq ", "  mxtq\n", "\tmxtq",
    ])
    func normalizesMxtqStampVariants(_ raw: String) async throws {
        let dir = try makeBundle(weightFormatRaw: raw)
        defer { try? FileManager.default.removeItem(at: dir) }

        actor FetchTracker {
            var fired = false
            func mark() { fired = true }
        }
        let tracker = FetchTracker()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, dest in
            await tracker.mark()
            try Data("ok".utf8).write(to: dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }

        let fired = await tracker.fired
        #expect(fired, "stamp '\(raw)' must be recognised as JANGTQ")
    }

    /// Stamps that look JANGTQ-ish but aren't must NOT fire the fetcher.
    @Test(arguments: [
        "mx_tq", "mxtq2", "mxq", "mxt", "tq", "bf16", "fp16", "int8", "mxfp4",
        "MXFP4", "", " ",
    ])
    func doesNotFetchForNonMxtqStamps(_ raw: String) async throws {
        let dir = try makeBundle(weightFormatRaw: raw)
        defer { try? FileManager.default.removeItem(at: dir) }

        actor FetchTracker {
            var fired = false
            func mark() { fired = true }
        }
        let tracker = FetchTracker()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            await tracker.mark()
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }

        let fired = await tracker.fired
        #expect(!fired, "stamp '\(raw)' must NOT be auto-fetched")
    }
}

@Suite("HF repo candidate resolution — covers all curated orgs")
struct HFRepoCandidatesTests {

    @Test func canonicalIdAlwaysIncludesCanonicalCasedFallbacks() {
        // Canonical id verbatim FIRST, then OsaurusAI / JANGQ-AI /
        // mlx-community variants of the basename — recovery for case-
        // mismatch + wrong-org-guess.
        #expect(
            ModelRuntime.jangtqHFRepoCandidates(for: "OsaurusAI/Foo")
                == [
                    "OsaurusAI/Foo",            // verbatim
                    "JANGQ-AI/Foo",
                    "mlx-community/Foo",
                ]
        )
        #expect(
            ModelRuntime.jangtqHFRepoCandidates(for: "JANGQ-AI/Laguna-XS.2-JANGTQ")
                == [
                    "JANGQ-AI/Laguna-XS.2-JANGTQ",
                    "OsaurusAI/Laguna-XS.2-JANGTQ",
                    "mlx-community/Laguna-XS.2-JANGTQ",
                ]
        )
    }

    /// LOWERCASED org id (osaurus's chat router lowercases ids) must still
    /// resolve to the canonical-cased HF org via the basename fallback.
    /// This is the user-reported regression — `jangq-ai/MiniMax-...` 401s
    /// because HF org names are case-sensitive; the fallback recovers.
    @Test func lowercasedOrgIdRecoveresToCanonicalCasing() {
        let cands = ModelRuntime.jangtqHFRepoCandidates(
            for: "jangq-ai/MiniMax-M2.7-Small-JANGTQ"
        )
        // Verbatim (lowercased) attempt first, then canonical-cased
        // fallbacks for the basename.
        #expect(cands == [
            "jangq-ai/MiniMax-M2.7-Small-JANGTQ",         // verbatim — may 401
            "OsaurusAI/MiniMax-M2.7-Small-JANGTQ",        // recovers!
            "JANGQ-AI/MiniMax-M2.7-Small-JANGTQ",
            "mlx-community/MiniMax-M2.7-Small-JANGTQ",
        ])
    }

    /// Flat-layout dir name → no verbatim try (no slash); fallbacks only.
    @Test func flatIdExpandsToAllKnownOrgs() {
        let cands = ModelRuntime.jangtqHFRepoCandidates(for: "MiniMax-M2.7-Small-JANGTQ")
        // OsaurusAI first (curated, most likely hit), then JANGQ-AI,
        // then mlx-community.
        #expect(cands == [
            "OsaurusAI/MiniMax-M2.7-Small-JANGTQ",
            "JANGQ-AI/MiniMax-M2.7-Small-JANGTQ",
            "mlx-community/MiniMax-M2.7-Small-JANGTQ",
        ])
    }

    /// Real bundle names that ship under OsaurusAI must round-trip through
    /// the fallback: the OsaurusAI candidate is always present and valid.
    @Test(arguments: [
        "Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
        "Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
        "Nemotron-3-Nano-Omni-30B-A3B-Multimodal-Addon",
        "Holo3-35B-A3B-mxfp4",
        "Laguna-XS.2-mxfp4",
        "Laguna-XS.2-JANGTQ",
        "Mistral-Medium-3.5-128B",
        "DeepSeek-V4-Flash-JANGTQ",
        "DeepSeek-V4-Flash-JANGTQ2",
        "Kimi-K2.6-Med-JANGTQ",
        "Kimi-K2.6-Small-JANGTQ",
        "MiniMax-M2.7-JANGTQ4",
        "MiniMax-M2.7-Small-JANGTQ",
        "Qwen3.5-35B-A3B-JANG_4K",
        "Qwen3.6-35B-A3B-JANGTQ4",
    ])
    func realBundleNamesProduceOsaurusAICandidate(_ flatName: String) {
        let cands = ModelRuntime.jangtqHFRepoCandidates(for: flatName)
        #expect(cands.contains("OsaurusAI/\(flatName)"),
            "OsaurusAI/\(flatName) must be in the fallback list")
        #expect(cands.contains("JANGQ-AI/\(flatName)"),
            "JANGQ-AI/\(flatName) must be in the fallback list")
        #expect(cands.contains("mlx-community/\(flatName)"),
            "mlx-community/\(flatName) must be in the fallback list")
        // All candidates must independently pass the strict id gate so
        // the URL builder produces a clean huggingface.co URL.
        for c in cands {
            #expect(ModelRuntime.isValidHFRepoId(c),
                "\(c) must satisfy isValidHFRepoId")
        }
    }

    /// Empty + multi-slash + malformed flat ids never produce candidates.
    @Test(arguments: ["", "/", "a/b/c", "../etc", "foo bar", "foo\nbar"])
    func malformedIdsProduceNoCandidates(_ id: String) {
        #expect(ModelRuntime.jangtqHFRepoCandidates(for: id).isEmpty)
    }

    /// A flat name containing characters the strict id gate would reject
    /// must not produce candidates that try to slip those chars through.
    @Test func flatIdWithIllegalCharsRejected() {
        // Whitespace in the basename → candidates list is empty because
        // every prefixed candidate fails isValidHFRepoId on the basename.
        #expect(ModelRuntime.jangtqHFRepoCandidates(for: "Bad Name").isEmpty)
        #expect(ModelRuntime.jangtqHFRepoCandidates(for: "ä-name").isEmpty)
        #expect(ModelRuntime.jangtqHFRepoCandidates(for: "name?evil").isEmpty)
    }
}

@Suite(.serialized)
struct OsaurusOrgAutoFetchTests {

    private func makeMxtqBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-osaurus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["weight_format": "mxtq"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent("jang_config.json"))
        return dir
    }

    /// User has a flat-layout JANGTQ bundle whose canonical HF repo lives
    /// under OsaurusAI. The fallback must walk through the org list, hit
    /// OsaurusAI/<name>, and recover.
    @Test func flatBundleResolvesViaOsaurusAIFallback() async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        actor URLLog {
            var attempts: [URL] = []
            func record(_ url: URL) { attempts.append(url) }
        }
        let log = URLLog()

        let dest = dir.appendingPathComponent("jangtq_runtime.safetensors")

        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, _ in
            await log.record(url)
            // OsaurusAI is now first in priority order (curated publisher
            // ships the bundles most users will have on disk). Simulate
            // OsaurusAI 200 → first attempt succeeds.
            if url.absoluteString.contains("/OsaurusAI/") {
                try Data("real-osaurus-ai-sidecar".utf8).write(to: dest)
                return
            }
            throw NSError(domain: "ModelRuntime", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 404"])
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4", name: "Nemotron"
            )
        }

        let attempts = await log.attempts
        // OsaurusAI tried first now; succeeds on first attempt.
        #expect(attempts.count == 1)
        #expect(
            attempts.first?.absoluteString
                == "https://huggingface.co/OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4/resolve/main/jangtq_runtime.safetensors"
        )
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    /// Canonical OsaurusAI/<repo> id (nested layout, downloaded normally
    /// through osaurus): fetcher hits exactly that URL once.
    @Test func nestedOsaurusAIFetchesDirectly() async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("jangtq_runtime.safetensors")

        actor URLLog {
            var attempts: [URL] = []
            func record(_ url: URL) { attempts.append(url) }
        }
        let log = URLLog()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { url, _ in
            await log.record(url)
            try Data("ok".utf8).write(to: dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Holo3-35B-A3B-JANGTQ",
                name: "Holo3"
            )
        }

        let attempts = await log.attempts
        #expect(attempts.count == 1)
        #expect(
            attempts.first?.absoluteString
                == "https://huggingface.co/OsaurusAI/Holo3-35B-A3B-JANGTQ/resolve/main/jangtq_runtime.safetensors"
        )
    }

    /// All candidates 404 → user gets a code-4 error listing every URL we
    /// tried, so they know exactly where the sidecar is expected to live.
    @Test func allCandidatesFailedSurfacesEveryTriedURL() async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            throw NSError(domain: "ModelRuntime", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 404"])
        }

        var threw: NSError?
        do {
            try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
                try await ModelRuntime.ensureJANGTQSidecar(
                    at: dir, modelId: "Some-Lost-Bundle", name: "Lost"
                )
            }
        } catch let e as NSError {
            threw = e
        }
        #expect(threw?.code == 4)
        let msg = threw?.localizedDescription ?? ""
        #expect(msg.contains("JANGQ-AI/Some-Lost-Bundle"))
        #expect(msg.contains("OsaurusAI/Some-Lost-Bundle"))
        #expect(msg.contains("mlx-community/Some-Lost-Bundle"))
    }
}

@Suite struct AutoFetchGuardTests {

    private func makeMxtqBundle() throws -> URL {
        try makeBundle(weightFormatRaw: "mxtq")
    }

    /// All these ids must reach the validator's code-2 throw without ever
    /// calling the network fetcher — `jangtqHFRepoCandidates` returns an
    /// empty list for them. (Flat-name ids without illegal chars now go
    /// through the org fallback list — that path is covered separately
    /// in `OsaurusOrgAutoFetchTests`.)
    @Test(arguments: [
        "",            // empty
        "/",           // bare slash
        "/foo",        // leading slash, not flat
        "foo/",        // trailing slash, not flat
        "a/b/c",       // too many slashes
        "a//b",        // empty middle segment
        "a b/c",       // whitespace
        "a/b?evil=1",  // URL meta
        "a/b#frag",    // fragment
        "a/../b",      // path traversal
        "ä/b",         // non-ASCII (slash-form)
        "Bad Name",    // flat with whitespace
        "name?evil",   // flat with URL meta
        "ä-name",      // flat with non-ASCII
    ])
    func malformedIdsDoNotTriggerFetcher(_ id: String) async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        actor FetchTracker {
            var fired = false
            func mark() { fired = true }
        }
        let tracker = FetchTracker()

        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            await tracker.mark()
        }

        var threw: NSError?
        do {
            try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
                try await ModelRuntime.ensureJANGTQSidecar(
                    at: dir, modelId: id, name: "Foo"
                )
            }
        } catch let e as NSError {
            threw = e
        }

        let fired = await tracker.fired
        #expect(!fired, "id '\(id)' must NOT hit the network")
        #expect(threw?.code == 2, "original code-2 error must surface for id '\(id)'")
    }

    /// Race tolerance: if a concurrent writer already produced the sidecar
    /// while our fetcher was running, we accept their copy and validate.
    @Test func raceWithConcurrentWriterIsTolerated() async throws {
        let dir = try makeMxtqBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("jangtq_runtime.safetensors")

        // Simulate "another process" writing the sidecar before our fetcher
        // returns. Our fetcher sees its temp file but the dest already exists
        // — the install path must not throw.
        let fetcher: @Sendable (URL, URL) async throws -> Void = { _, _ in
            try Data("from-other-process".utf8).write(to: dest)
        }

        try await ModelRuntime.$sidecarFetcherForTests.withValue(fetcher) {
            try await ModelRuntime.ensureJANGTQSidecar(
                at: dir, modelId: "OsaurusAI/Foo", name: "Foo"
            )
        }

        let bytes = try Data(contentsOf: dest)
        #expect(String(data: bytes, encoding: .utf8) == "from-other-process")
    }
}
