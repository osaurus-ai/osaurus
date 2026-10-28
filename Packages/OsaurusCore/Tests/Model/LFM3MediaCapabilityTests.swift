//
//  LFM3MediaCapabilityTests.swift
//  osaurusTests
//
//  LiquidAI LFM3 bundles report exactly the media lanes their weights carry.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("LFM3 media capabilities")
struct LFM3MediaCapabilityTests {
    /// LFM3 keeps LFM2's short-conv layers, so its cache carries recurrent state.
    @Test func lfm3BundleNamesAreHybrid() {
        for name in [
            "LiquidAI/LFM3-1.7B-MLX-4bit", "lfm3-vl-2b-mlx-bf16", "LFM3-Omni-2B-MLX-8bit",
            "liquidai/lfm3-audio-2b-mlx-4bit",
        ] {
            #expect(ModelRuntime.isKnownHybridModel(name: name), "\(name)")
        }
        #expect(!ModelRuntime.isKnownHybridModel(name: "lfm30-test"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "someorg/notlfm3"))
    }

    /// `OSAURUS_LFM3_BUNDLES_DIR`: a folder of released LFM3 MLX bundles (`LFM3-*`).
    /// Text bundles (which carry an empty `vision_config`) stay text-only; VL reads images and
    /// video; Audio hears; Omni does both. Every quant of a family must agree.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OSAURUS_LFM3_BUNDLES_DIR"] != nil))
    func installedBundlesReportTheirLanes() throws {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["OSAURUS_LFM3_BUNDLES_DIR"]!,
            isDirectory: true)
        let bundles = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("LFM3-") }.sorted()
        #expect(!bundles.isEmpty, "no LFM3 bundles under \(root.path)")
        for name in bundles {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let caps = ModelMediaCapabilities.from(directory: directory, modelId: name)
            let evidence = LocalVisionEvidence.inspect(directory, refresh: true)
            let family = name.contains("-Omni-") ? "omni" : name.contains("-Audio-") ? "audio"
                : name.contains("-VL-") ? "vl" : "text"
            let expected: (image: Bool, video: Bool, audio: Bool) =
                switch family {
                case "omni": (true, true, true)
                case "audio": (false, false, true)
                case "vl": (true, true, false)
                default: (false, false, false)
                }
            print("[LFM3] \(name): image=\(caps.supportsImage) video=\(caps.supportsVideo) audio=\(caps.supportsAudio) (\(evidence.reason))")
            #expect(caps.supportsImage == expected.image, "\(name) image: \(evidence.reason)")
            #expect(caps.supportsVideo == expected.video, "\(name) video")
            #expect(caps.supportsAudio == expected.audio, "\(name) audio")
        }
    }
}
