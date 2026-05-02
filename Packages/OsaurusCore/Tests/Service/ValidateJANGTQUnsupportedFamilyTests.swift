// Copyright © 2026 osaurus.
//
// MC/DC tests for the third branch of `validateJANGTQSidecarIfRequired`:
// JANGTQ-quantized bundles whose model_type family doesn't yet have a
// JANGTQ-aware Linear shim ported into vmlx-swift-lm. Currently the
// pending families are mistral3, ministral3 (Mistral 3 family inner),
// and laguna.
//
// The check fires only when ALL of:
//   - jang_config.json present
//   - weight_format == "mxtq"
//   - config.json model_type (or text_config.model_type for VLM
//     wrappers) ∈ {mistral3, ministral3, laguna}
//
// Decision: D1 ∧ D2 ∧ (D3_outer ∨ D3_inner)
//
// MC/DC requires each D_i to independently flip the decision. Plus
// boundary rows for non-pending families (nemotron_h, qwen3_5_moe,
// minimax_m2) which DO have JANGTQ shims and must NOT trigger the
// new check.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("validateJANGTQSidecarIfRequired — pending JANGTQ family check")
struct ValidateJANGTQUnsupportedFamilyTests {

    // MARK: - Helpers

    private func makeBundle(
        weightFormat: String?,
        modelType: String?,
        textInner: String? = nil,
        sidecarPresent: Bool,
        visionConfigPresent: Bool = false
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate-jangtq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let weightFormat {
            let jc = ["weight_format": weightFormat]
            try JSONSerialization.data(withJSONObject: jc).write(
                to: dir.appendingPathComponent("jang_config.json")
            )
        }
        if let modelType {
            var c: [String: Any] = ["model_type": modelType]
            if let textInner {
                c["text_config"] = ["model_type": textInner] as [String: Any]
            }
            if visionConfigPresent {
                c["vision_config"] = ["model_type": "pixtral"] as [String: Any]
            }
            try JSONSerialization.data(withJSONObject: c).write(
                to: dir.appendingPathComponent("config.json")
            )
        }
        if sidecarPresent {
            try Data([0x00, 0x01]).write(
                to: dir.appendingPathComponent("jangtq_runtime.safetensors")
            )
        }
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - D1, D2: existing branches still fire (regression guard)

    @Test("D1 F: no jang_config → preflight returns silently")
    func d1_noJangConfig_silent() throws {
        let dir = try makeBundle(
            weightFormat: nil,
            modelType: "mistral3",
            sidecarPresent: false
        )
        defer { cleanup(dir) }
        // No throw expected — non-JANG bundles bypass all checks.
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "test")
    }

    @Test("D2 F: weight_format != mxtq → no pending-family check")
    func d2_nonMxtq_passesNewCheck() throws {
        // Mistral 3.5 MXFP4 bundle should NOT trigger the new pending-family
        // gate because weight_format is "mxfp4", not "mxtq". MXFP4 path
        // works via standard mlx_lm dequant for Mistral 3 family.
        let dir = try makeBundle(
            weightFormat: "mxfp4",
            modelType: "mistral3",
            sidecarPresent: false
        )
        defer { cleanup(dir) }
        try ModelRuntime.validateJANGTQSidecarIfRequired(at: dir, name: "test")
    }

    // MARK: - D3 branches: pending JANGTQ families

    /// Post vmlx@cb829b6 (Mistral 3 LLM JANGTQ port complete):
    /// LLM-only mistral3 (no vision_config) bundles should PASS the
    /// preflight — the engine handles them via Mistral3TextJANGTQModel.
    @Test("D3.mistral3 outer JANGTQ + no vision → PASSES (LLM port complete)")
    func d3_mistral3OuterNoVision_passes() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "mistral3",
            sidecarPresent: true
        )
        defer { cleanup(dir) }
        // No throw expected — Mistral 3 LLM JANGTQ now supported.
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Mistral-7B-JANGTQ2"
        )
    }

    /// Post vmlx@7fa4940 (Mistral 3 family VLM JANGTQ port complete):
    /// VLM-shaped bundles (vision_config present) now PASS — the
    /// engine handles them via Mistral3VLMJANGTQ.
    @Test("D3.mistral3 + vision_config JANGTQ → PASSES (VLM port complete)")
    func d3_mistral3VLM_passes() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "mistral3",
            sidecarPresent: true,
            visionConfigPresent: true
        )
        defer { cleanup(dir) }
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Mistral-Medium-3.5-128B-JANGTQ2"
        )
    }

    @Test("D3.ministral3 inner LLM-only → PASSES (LLM port complete)")
    func d3_ministral3InnerNoVision_passes() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "mistral3",
            textInner: "ministral3",
            sidecarPresent: true
        )
        defer { cleanup(dir) }
        // No vision_config → LLM path → JANGTQ supported.
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Ministral-3-Inner-LLM-JANGTQ2"
        )
    }

    @Test("D3.ministral3 inner + vision_config → PASSES (VLM port complete)")
    func d3_ministral3InnerVLM_passes() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "mistral3",
            textInner: "ministral3",
            sidecarPresent: true,
            visionConfigPresent: true
        )
        defer { cleanup(dir) }
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Mistral-Medium-3.5-128B-JANGTQ2"
        )
    }

    /// Post vmlx@344dda0 (Laguna LLM engine class shipped):
    /// Laguna JANGTQ no longer hits the host-side family gate. The
    /// existing forward/inverse sidecar checks still catch mislabeled
    /// bundles. JANGTQ Linear shim port for Laguna is the next piece;
    /// until then, JANGTQ bundles will surface a vmlx-side error if
    /// the runtime hits an unhandled tq_packed key — same as any
    /// half-quantized bundle. MXFP4 path loads cleanly today.
    @Test("D3.laguna outer JANGTQ → no longer family-gated (engine class shipped)")
    func d3_laguna_unblocked() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "laguna",
            sidecarPresent: true
        )
        defer { cleanup(dir) }
        // No throw expected — gate dropped.
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Laguna-XS.2-JANGTQ2"
        )
    }

    // MARK: - Boundary: supported JANGTQ families must NOT trigger the new check

    @Test("nemotron_h JANGTQ does NOT trigger pending-family error (shim ported)")
    func boundary_nemotronH_passes() throws {
        // NemotronHJANGTQModel exists; this must NOT throw the new code-4 error.
        // Sidecar IS present, weight_format IS mxtq, but model_type is supported.
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "nemotron_h",
            sidecarPresent: true
        )
        defer { cleanup(dir) }
        // No throw expected — preflight passes through to vmlx loader.
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4"
        )
    }

    @Test("qwen3_5_moe JANGTQ does NOT trigger pending-family error")
    func boundary_qwen35moe_passes() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "qwen3_5_moe",
            sidecarPresent: true
        )
        defer { cleanup(dir) }
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Qwen3.6-35B-A3B-JANGTQ"
        )
    }

    @Test("minimax_m2 JANGTQ does NOT trigger pending-family error")
    func boundary_minimax_passes() throws {
        let dir = try makeBundle(
            weightFormat: "mxtq",
            modelType: "minimax_m2",
            sidecarPresent: true
        )
        defer { cleanup(dir) }
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "MiniMax-M2.7-JANGTQ"
        )
    }

    @Test("Mistral 3 family MXFP4 does NOT trigger (only mxtq fires the new check)")
    func boundary_mistral3MXFP4_passes() throws {
        // The friendly path for Mistral 3 family — load via MXFP4 instead of
        // JANGTQ. Must pass cleanly.
        let dir = try makeBundle(
            weightFormat: "mxfp4",
            modelType: "mistral3",
            sidecarPresent: false
        )
        defer { cleanup(dir) }
        try ModelRuntime.validateJANGTQSidecarIfRequired(
            at: dir,
            name: "Mistral-Medium-3.5-128B-mxfp4"
        )
    }

    // Note: the prior `laguna_mxfp4_blocked` + `laguna_jangtq_passes` tests
    // were removed when vmlx-swift-lm `4699d3a` made `LagunaMoE.experts`
    // polymorphic — it now dispatches to `SwitchGLU` (affine, mxfp4) or
    // `TurboQuantSwitchGLU` (codebook, mxtq) at construction time. The
    // preflight code-5 gate they covered is gone; both Laguna variants
    // load natively.
}
