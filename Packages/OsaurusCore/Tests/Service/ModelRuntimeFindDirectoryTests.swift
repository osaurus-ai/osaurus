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

    @Test("Sharded symlinked model resolves from bounded sentinel")
    func shardedSymlinkLayoutResolvesFromBoundedSentinel() throws {
        let (root, realModel) = try makeRoot(layout: .symlinked)
        try FileManager.default.createDirectory(at: realModel, withIntermediateDirectories: true)
        try Data(#"{"model_type":"step3"}"#.utf8).write(
            to: realModel.appendingPathComponent("config.json")
        )
        try Data("dummy".utf8).write(
            to: realModel.appendingPathComponent("model-00001-of-00045.safetensors")
        )

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "OsaurusAI/TestModel",
            in: root
        )
        #expect(resolved?.resolvingSymlinksInPath().path == realModel.resolvingSymlinksInPath().path)
    }

    @Test("Friendly non-CRACK id resolves to local CRACK bundle")
    func friendlyNonCrackIdResolvesToLocalCrackBundle() throws {
        let root = try makeIsolatedDir()
        let repo = root.appendingPathComponent("dealign.ai", isDirectory: true)
            .appendingPathComponent("Gemma-4-12B-it-MXFP8-CRACK", isDirectory: true)
        try populateValidModel(at: repo)

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "gemma-4-12b-it-mxfp8",
            in: root
        )
        #expect(resolved?.resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path)
    }

    @Test("Friendly CRACK id resolves by basename under arbitrary publisher org")
    func friendlyCrackIdResolvesByBasenameUnderPublisherOrg() throws {
        let root = try makeIsolatedDir()
        let repo = root.appendingPathComponent("dealign.ai", isDirectory: true)
            .appendingPathComponent("Gemma-4-12B-it-MXFP4-CRACK", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gemma4_unified"}"#.utf8).write(
            to: repo.appendingPathComponent("config.json")
        )
        try Data("dummy".utf8).write(
            to: repo.appendingPathComponent("model-00001-of-00010.safetensors")
        )

        let resolved = ModelRuntime.resolveLocalModelDirectory(
            forModelId: "gemma-4-12b-it-mxfp4-crack",
            in: root
        )
        #expect(resolved?.resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path)
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

    @Test("Hybrid JANGTQ RAM headroom is derived from attention topology, not disk bytes")
    func hybridJANGTQHeadroomUsesConfigTopology() throws {
        let dir = try makeIsolatedDir()
        let config = """
            {
              "model_type": "nemotron_h",
              "num_hidden_layers": 8,
              "layers_block_type": ["mamba", "moe", "mamba", "attention", "moe", "mamba", "moe", "attention"],
              "num_attention_heads": 64,
              "num_key_value_heads": 2,
              "head_dim": 128,
              "max_position_embeddings": 262144,
              "mamba_num_heads": 128,
              "mamba_head_dim": 128,
              "ssm_state_size": 128,
              "conv_kernel": 4,
              "mamba_ssm_cache_dtype": "float32",
              "weight_format": "mxtq"
            }
            """
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))

        let weights: Int64 = 100 * 1024 * 1024 * 1024
        let fallback = ModelRuntime.estimatedKVHeadroomBytes(forWeights: weights)
        let topology = ModelRuntime.estimatedKVHeadroomBytes(
            forWeights: weights,
            modelDirectory: dir
        )

        #expect(fallback == 20 * 1024 * 1024 * 1024)
        #expect(topology < 2 * 1024 * 1024 * 1024)
        #expect(topology >= 512 * 1024 * 1024)
    }

    @Test("Routed JANGTQ pre-load RAM gate uses MLXPress hot working set")
    func routedJANGTQLoadFootprintUsesCompressionHotSet() throws {
        let dir = try makeIsolatedDir()
        let config = """
            {
              "model_type": "nemotron_h",
              "weight_format": "mxtq",
              "n_routed_experts": 512,
              "num_experts_per_tok": 22
            }
            """
        let jang = """
            {
              "weight_format": "mxtq",
              "quantization": {
                "profile": "JANGTQ_1L",
                "actions": { "routed_tq": 49152 }
              },
              "mxtq_bits": {
                "routed_expert": { "up_proj": 1, "down_proj": 1 }
              }
            }
            """
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(jang.utf8).write(to: dir.appendingPathComponent("jang_config.json"))
        try Data([0]).write(to: dir.appendingPathComponent("jangtq_runtime.safetensors"))

        let raw: Int64 = 100 * 1024 * 1024 * 1024
        let effective = ModelRuntime.effectiveLoadFootprintBytes(
            rawWeightsBytes: raw,
            modelDirectory: dir,
            modelName: "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L"
        )

        #expect(effective == 30 * 1024 * 1024 * 1024)
    }

    @Test("Non-JANGTQ and missing-sidecar models keep raw pre-load RAM budget")
    func nonJANGTQLoadFootprintKeepsRawBudget() throws {
        let plain = try makeIsolatedDir()
        try Data(#"{"model_type":"gemma4","num_hidden_layers":48}"#.utf8)
            .write(to: plain.appendingPathComponent("config.json"))

        let missingSidecar = try makeIsolatedDir()
        try Data(#"{"model_type":"nemotron_h","weight_format":"mxtq","n_routed_experts":512}"#.utf8)
            .write(to: missingSidecar.appendingPathComponent("config.json"))
        try Data(#"{"weight_format":"mxtq","quantization":{"profile":"JANGTQ_1L"}}"#.utf8)
            .write(to: missingSidecar.appendingPathComponent("jang_config.json"))

        let raw: Int64 = 100 * 1024 * 1024 * 1024

        #expect(
            ModelRuntime.effectiveLoadFootprintBytes(
                rawWeightsBytes: raw,
                modelDirectory: plain,
                modelName: "gemma-4-12b-it-mxfp8"
            ) == raw
        )
        #expect(
            ModelRuntime.effectiveLoadFootprintBytes(
                rawWeightsBytes: raw,
                modelDirectory: missingSidecar,
                modelName: "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L"
            ) == raw
        )
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

    /// Inverse mismatch (the live-repro from 2026-04-25): bundle ships the
    /// JANGTQ sidecar but jang_config.json was stamped as `bf16`. vmlx's
    /// factory then dispatches to the BASE DeepSeekV4 / MiniMax / etc. class,
    /// hits `tq_norms` / `tq_packed` tensors in the safetensors, and the
    /// parameter loader throws `Unhandled keys [...]`. The preflight catches
    /// it before any shards load and tells the user how to fix it.
    @Test("Mislabeled bundle (bf16 stamp + sidecar present) throws inverse-mismatch error")
    func jangtq_mislabeledBundle_bf16WithSidecar_throws() throws {
        let dir = try makeIsolatedDir()
        try writeJangConfig(weightFormat: "bf16", at: dir)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("jangtq_runtime.safetensors"))
        #expect(throws: Error.self) {
            try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "DSV4-mislabeled")
        }
    }

    /// Inverse mismatch with no `weight_format` field at all. Same failure
    /// shape — bundle ships the sidecar so the safetensors carry TurboQuant
    /// tensors, but no stamp tells vmlx's factory to dispatch JANGTQ.
    @Test("Mislabeled bundle (absent weight_format + sidecar present) throws inverse-mismatch error")
    func jangtq_mislabeledBundle_absentStampWithSidecar_throws() throws {
        let dir = try makeIsolatedDir()
        // jang_config exists but omits weight_format entirely.
        let json = #"{"profile":"unknown"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("jang_config.json"))
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("jangtq_runtime.safetensors"))
        #expect(throws: Error.self) {
            try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "Generic-mislabeled")
        }
    }

    @Test("JANGTQ format stamp with sidecar passes even when weight_format is absent")
    func jangtq_formatStampWithSidecar_passes() throws {
        let dir = try makeIsolatedDir()
        // Step 3.7 JANGTQ_K bundles can declare the runtime via
        // `format: "jangtq"` while omitting the older top-level
        // `weight_format` key. vmlx infers the JANGTQ route from the
        // sidecar/codebook; Osaurus preflight must not block that valid
        // bundle shape.
        let json = #"{"format":"jangtq"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("jang_config.json"))
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("jangtq_runtime.safetensors"))
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "Step-3.7-JANGTQ_K")
    }

    /// Genuine bf16 dense bundle: stamp says bf16 AND no sidecar. This is
    /// the common case for non-quantized JANG bundles (DSV4-Flash-JANG_2L,
    /// Mistral-Small-4-JANG_2L, etc.) — must pass through cleanly.
    @Test("Genuine bf16 bundle (no sidecar) passes through")
    func jangtq_bf16NoSidecar_passes() throws {
        let dir = try makeIsolatedDir()
        try writeJangConfig(weightFormat: "bf16", at: dir)
        // No sidecar — this is a real dense bf16 bundle, must not throw.
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "DSV4-bf16-dense")
    }

    @Test("Plain affine DeepSeek V4 JANG is blocked before shard load")
    func dsv4_plainAffineJANG_throwsBeforeLoad() throws {
        let dir = try makeIsolatedDir()
        try writeConfig(modelType: "deepseek_v4", routedExperts: 256, at: dir)
        try writeJangConfig(weightFormat: "affine", at: dir)

        #expect(throws: MLXService.RuntimePolicyError.self) {
            try ModelRuntime.validateUnsupportedPlainDSV4AffineJANG(
                at: dir,
                name: "DeepSeek-V4-Flash-JANG"
            )
        }
    }

    @Test("DeepSeek V4 JANGTQ sidecar is not blocked by plain-affine guard")
    func dsv4_jangtqSidecar_passesPlainAffineGuard() throws {
        let dir = try makeIsolatedDir()
        try writeConfig(modelType: "deepseek_v4", routedExperts: 256, at: dir)
        try writeJangConfig(weightFormat: "mxtq", at: dir)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("jangtq_runtime.safetensors"))

        try ModelRuntime.validateUnsupportedPlainDSV4AffineJANG(
            at: dir,
            name: "DeepSeek-V4-Flash-JANGTQ2"
        )
    }

    @Test("Small affine fixtures are not blocked by DeepSeek V4 JANG guard")
    func dsv4_smallAffineFixture_passesPlainAffineGuard() throws {
        let dir = try makeIsolatedDir()
        try writeConfig(modelType: "deepseek_v4", routedExperts: 8, at: dir)
        try writeJangConfig(weightFormat: "affine", at: dir)

        try ModelRuntime.validateUnsupportedPlainDSV4AffineJANG(
            at: dir,
            name: "Tiny-DSV4-fixture"
        )
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

    private func writeConfig(modelType: String, routedExperts: Int, at dir: URL) throws {
        let json = #"{"model_type":"\#(modelType)","n_routed_experts":\#(routedExperts)}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("config.json"))
    }
}
