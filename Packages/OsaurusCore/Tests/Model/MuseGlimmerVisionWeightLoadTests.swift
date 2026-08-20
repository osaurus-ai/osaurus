import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@testable import OsaurusCore

/// The model names a solid red field "green" and answers the same colour for
/// opposite images, while the patch tensor, the channel order and the tower's
/// own separation all check out. The remaining way to get informative-looking
/// but meaningless embeddings is for the vision weights never to reach the
/// module — a tower left at random init still produces plausible-shaped output.
///
/// Weight loading verifies with `.noUnusedKeys`, which catches checkpoint keys
/// that match nothing but NOT module parameters that received nothing. So this
/// compares the loaded tensors against the safetensors on disk directly.
@Suite("Muse Glimmer vision weight load")
struct MuseGlimmerVisionWeightLoadTests {

    static let bundle: URL = {
        let name = ProcessInfo.processInfo.environment["MUSE_VL_BUNDLE"]
            ?? "Muse-Glimmer-30B-JANG_4M"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("models/JANGQ-AI/\(name)")
    }()

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MUSE_VL_LIVE"] == "1"
            && FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("config.json").path)
    }

    @Test("vision tower weights match the checkpoint", .enabled(if: enabled))
    func visionWeightsAreLoaded() async throws {
        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())

        // Flatten the live module tree.
        let live = context.model.parameters().flattened()
        let visionKeys = live.map(\.0).filter { $0.contains("vision") }
        print("[weights] live vision parameter count: \(visionKeys.count)")
        for k in visionKeys.prefix(6) { print("[weights]   \(k)") }
        #expect(!visionKeys.isEmpty, "no vision parameters in the loaded model")

        // Load the checkpoint tensors straight off disk.
        var disk: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.bundle, includingPropertiesForKeys: nil)
        for f in files where f.pathExtension == "safetensors" {
            guard let arrays = try? MLX.loadArrays(url: f) else { continue }
            for (k, v) in arrays where k.contains("vision") { disk[k] = v }
        }
        print("[weights] checkpoint vision tensors: \(disk.count)")
        try #require(!disk.isEmpty, "no vision tensors found in the bundle")

        // Compare every live vision parameter against its checkpoint tensor.
        // `sanitize` only drops the leading `model.`, so the live key is the
        // checkpoint key minus that prefix.
        var compared = 0, mismatched: [String] = []
        for (liveKey, liveValue) in live where liveKey.contains("vision") {
            guard let diskValue = disk["model." + liveKey] ?? disk[liveKey] else { continue }
            guard liveValue.shape == diskValue.shape else {
                mismatched.append("\(liveKey) shape \(liveValue.shape) vs \(diskValue.shape)")
                continue
            }
            let delta = MLX.abs(liveValue.asType(.float32) - diskValue.asType(.float32)).max()
            delta.eval()
            let d = delta.item(Float.self)
            compared += 1
            if d > 1e-3 { mismatched.append("\(liveKey) max|Δ|=\(d)") }
        }
        print("[weights] compared \(compared) vision tensors, \(mismatched.count) mismatched")
        for m in mismatched.prefix(10) { print("[weights]   MISMATCH \(m)") }

        #expect(compared > 0, "no live vision parameter matched a checkpoint tensor by name")
        #expect(mismatched.isEmpty,
            "vision weights differ from the checkpoint — the tower is not running trained weights")
    }
}
