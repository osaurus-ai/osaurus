import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelRuntime.resolveLocalModelDirectory — symlink resolution")
struct ModelRuntimeFindDirectoryTests {

    @Test("Plain org/repo directory with valid weights resolves")
    func plainLayoutResolves() throws {
        let (root, realModel) = try makeRoot()
        try populateValidModel(at: realModel)

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved != nil)
        // Path resolution normalizes `/private/var/...` ↔ `/var/...` etc, so
        // compare realpath form to avoid false negatives on macOS where
        // `NSTemporaryDirectory` lives under a symlinked mount point.
        #expect(resolved?.resolvingSymlinksInPath().path == realModel.resolvingSymlinksInPath().path)
    }

    @Test("Symlinked model directory resolves (regression for ENOTDIR bug)")
    func symlinkLayoutResolves() throws {
        let (root, realModel) = try makeRoot(layout: .symlinked)
        try populateValidModel(at: realModel)

        // `root/OsaurusAI/TestModel` is a symlink → realModel.
        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved != nil)
        // Post-resolution we should be pointing at the real target, not the link path.
        #expect(resolved?.resolvingSymlinksInPath().path == realModel.resolvingSymlinksInPath().path)
    }

    @Test("Missing config.json returns nil even when safetensors exist")
    func missingConfigRejects() throws {
        let (root, realModel) = try makeRoot()
        // Populate only safetensors, no config.json.
        try FileManager.default.createDirectory(at: realModel, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: realModel.appendingPathComponent("model.safetensors"))

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved == nil)
    }

    @Test("Missing safetensors returns nil even with config.json")
    func missingSafetensorsRejects() throws {
        let (root, realModel) = try makeRoot()
        try FileManager.default.createDirectory(at: realModel, withIntermediateDirectories: true)
        try Data(#"{"model_type":"test"}"#.utf8).write(to: realModel.appendingPathComponent("config.json"))

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved == nil)
    }

    // MARK: - JANGTQ sidecar preflight
    //
    // vmlx's LLMModelFactory dispatches to the JANGTQ class purely on
    // `jang_config.json.weight_format == "mxtq"`, and then
    // `TurboQuantSwitchLinear.callAsFunction` `fatalError`s on the first
    // forward pass when the `jangtq_runtime.safetensors` sidecar isn't in
    // the runtime cache. `validateJANGTQSidecarIfRequired` closes that gap
    // with a clear Swift error *before* vmlx aborts the whole process.

    @Test("Missing sidecar on mxtq model throws a clear error")
    func jangtq_missingSidecar_throws() throws {
        let dir = try makeIsolatedDir()
        try writeJangConfig(weightFormat: "mxtq", at: dir)
        // Deliberately DO NOT create jangtq_runtime.safetensors.
        #expect(throws: Error.self) {
            try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "MiniMax-JANGTQ")
        }
    }

    @Test("Sidecar present on mxtq model passes")
    func jangtq_sidecarPresent_passes() throws {
        let dir = try makeIsolatedDir()
        try writeJangConfig(weightFormat: "mxtq", at: dir)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("jangtq_runtime.safetensors"))
        // Should not throw.
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "MiniMax-JANGTQ-OK")
    }

    @Test("Non-JANGTQ jang_config is passed through (no sidecar required)")
    func jangtq_nonMxtqFormat_passes() throws {
        let dir = try makeIsolatedDir()
        try writeJangConfig(weightFormat: "jang_v2", at: dir)
        // No sidecar; should not throw because this isn't a JANGTQ/mxtq variant.
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "MiniMax-JANG")
    }

    @Test("Model with no jang_config.json is passed through")
    func jangtq_noJangConfig_passes() throws {
        let dir = try makeIsolatedDir()
        // Plain HF model directory — no jang_config.json at all.
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "Gemma-vanilla")
    }

    // MARK: - Regression guard: pure-filesystem helpers must not pull in MLX
    //
    // PR #878 surfaced a CI launch hang where the `OsaurusCoreTests` xctest
    // bundle launched, ran silently for 70+ minutes, then was cancelled —
    // root caused to file-level `let _vlmFactory = MLXVLM.VLMModelFactory.shared`
    // / `let _llmFactory = MLXLLM.LLMModelFactory.shared` declarations in
    // `ModelRuntime.swift` that, on first reference of *any* symbol from
    // that file, transitively materialized vmlx-swift-lm c101739's new
    // `Qwen35JANGTQ.swift` file-level `qwen35JANGTQCompiledSigmoidGate`
    // (which calls `MLX.compile(shapeless: true, body)` — a Metal JIT step
    // that doesn't return on the GitHub Actions `macos-latest` runner).
    //
    // The fix moved factory force-link off file scope and onto an explicit
    // `_ = ModelRuntime._registerFactoriesOnce` reference inside
    // `loadContainer` only. This test pins that invariant: calling the two
    // static helpers must NOT increment `_factoriesRegisteredHookCount`,
    // because the helpers are pure filesystem operations that have no
    // business loading MLX.
    //
    // If a future change re-introduces an eager MLX touch in the helpers
    // (or adds a new file-level `let` in ModelRuntime.swift that pulls in
    // a heavy MLX symbol), this test will start failing locally and the
    // CI launch hang will be caught BEFORE it burns a 15-minute job
    // timeout on `main`.

    @Test("resolveLocalModelDirectory does not force-link MLX factories")
    func resolveLocalModelDirectory_doesNotPullInMLX() throws {
        let before = ModelRuntime._factoriesRegisteredHookCount
        let (root, realModel) = try makeRoot()
        try populateValidModel(at: realModel)
        _ = ModelRuntime.resolveLocalModelDirectory(forModelId: "OsaurusAI/TestModel", in: root)
        let after = ModelRuntime._factoriesRegisteredHookCount
        #expect(before == after, .init(rawValue: regressionMessage))
    }

    @Test("validateJANGTQSidecarIfRequired does not force-link MLX factories")
    func validateJANGTQSidecarIfRequired_doesNotPullInMLX() throws {
        let before = ModelRuntime._factoriesRegisteredHookCount
        let dir = try makeIsolatedDir()
        try writeJangConfig(weightFormat: "jang_v2", at: dir)
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "regression-probe")
        let after = ModelRuntime._factoriesRegisteredHookCount
        #expect(before == after, .init(rawValue: regressionMessage))
    }

    /// Pulled out as a stored constant because Swift Testing's `#expect(_, _)`
    /// expects a `Comment?` and the long inline string was tripping the
    /// compiler's type-checker time budget.
    private var regressionMessage: String {
        "Static helper transitively triggered _registerFactoriesOnce — MLX factories "
            + "are being eagerly initialized from a path that doesn't need them, which is "
            + "the regression class that caused PR #878's 70-minute CI launch hang. "
            + "Inspect any new file-level `let` in ModelRuntime.swift that references "
            + "MLX*Factory.shared, or any new MLX touch in resolveLocalModelDirectory / "
            + "validateJANGTQSidecarIfRequired."
    }

    // MARK: - Existing resolveLocalModelDirectory tests (below)

    @Test("Nonexistent path returns nil")
    func nonexistentReturnsNil() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-test-\(UUID().uuidString)", isDirectory: true)
        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "Nobody/Nothing",
            in: tmp
        )
        #expect(resolved == nil)
    }

    // MARK: - Fixtures

    private enum Layout {
        /// `<root>/OsaurusAI/TestModel/` is a real directory.
        case plain
        /// `<root>/OsaurusAI/TestModel` is a symlink → an out-of-tree real directory.
        /// This exercises the actual ENOTDIR bug fix path.
        case symlinked
    }

    /// Builds a fresh root dir under `NSTemporaryDirectory()`. Returns the
    /// root plus the real directory where model files should be written
    /// (either the repo dir directly, or the symlink target).
    private func makeRoot(layout: Layout = .plain) throws -> (root: URL, realModel: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-modelruntime-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let orgDir = root.appendingPathComponent("OsaurusAI", isDirectory: true)
        try fm.createDirectory(at: orgDir, withIntermediateDirectories: true)

        switch layout {
        case .plain:
            let repoDir = orgDir.appendingPathComponent("TestModel", isDirectory: true)
            try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
            return (root, repoDir)

        case .symlinked:
            // Put the real weights outside the "picker root" so we're
            // actually resolving across a symlink boundary.
            let externalBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("osaurus-modelruntime-external-\(UUID().uuidString)", isDirectory: true)
            let realRepo = externalBase.appendingPathComponent("TestModel-real", isDirectory: true)
            try fm.createDirectory(at: realRepo, withIntermediateDirectories: true)
            let linkAt = orgDir.appendingPathComponent("TestModel")
            try fm.createSymbolicLink(at: linkAt, withDestinationURL: realRepo)
            return (root, realRepo)
        }
    }

    /// Writes minimum files so `resolveLocalModelDirectory` considers the
    /// directory a valid model (config.json + any `*.safetensors`).
    private func populateValidModel(at dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(#"{"model_type":"test"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
    }

    /// Ad-hoc isolated tmp directory for JANGTQ preflight tests — kept
    /// separate from `makeRoot` because those tests also create an inner
    /// `ORG/REPO` layout we don't need here.
    private func makeIsolatedDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-jangtq-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a minimal `jang_config.json` with a chosen `weight_format`.
    private func writeJangConfig(weightFormat: String, at dir: URL) throws {
        let json = #"{"weight_format":"\#(weightFormat)"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("jang_config.json"))
    }
}
