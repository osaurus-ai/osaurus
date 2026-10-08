import Foundation
import MLXLMCommon
import Testing
@testable import OsaurusCore

@Suite("Selected bundle native MTP detection without loading")
struct NativeMTPPreloadDetectionTests {
    @Test("affine 27B and affine/JANGH Flash Next are detected before residency")
    func selectedBundleLayouts() throws {
        for (modelType, format) in [("qwen3_5", "affine"), ("qwen4_exp", "affine"), ("qwen4_exp", "jangh")] {
            let directory = try fixture(modelType: modelType, format: format)
            defer { try? FileManager.default.removeItem(at: directory) }
            // This name intentionally has no catalog entry. The selected URL is authoritative.
            let status = try #require(
                ModelRuntime.inspectLoadingModelMTP(name: "selected-local-alias", directory: directory)
            )
            #expect(status.name == "selected-local-alias")
            #expect(status.bundleHasMTP)
            #expect(status.isTargetMTPFamily)
            #expect(!status.isBlocked)
        }
    }

    @Test("MiMo and N2 aliases cannot suppress another architecture's native head")
    func misleadingTextRuntimeAliases() throws {
        let aliases = ["MiMo-V2.5-JANG_4M", "Nex-N2-Pro-JANGH2"]
        for (modelType, format) in [("qwen3_5", "affine"), ("qwen4_exp", "affine"), ("qwen4_exp", "jangh")] {
            let directory = try fixture(modelType: modelType, format: format)
            defer { try? FileManager.default.removeItem(at: directory) }
            let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let status = try MTPBundleInspector.inspect(modelDirectory: directory, jangConfig: nil)
            for alias in aliases {
                // Exercise the same exception predicate used before launch inspection.
                #expect(ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(alias))
                #expect(!ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(alias, configData: configData))
                let capability = try #require(ModelRuntime.inspectLoadingModelMTP(name: alias, directory: directory))
                #expect(capability.bundleHasMTP)
                #expect(capability.isTargetMTPFamily)
                var settings = VMLXServerRuntimeSettings()
                settings.mtp.mode = .off
                #expect(
                    settings.resolvedMTPDraftStrategy(
                        configData: configData, jangConfig: nil, status: status, bundleDirectory: directory
                    ) == nil
                )
            }
        }
    }

    @Test("MiMo and N2 launch exception requires matching config architecture")
    func textRuntimeExceptionRequiresConfig() throws {
        for alias in ["MiMo-V2.5-JANG_4M", "Nex-N2-Pro-JANGH2"] {
            for type in ["mimo_v2", "mimo_v2_flash"] {
                let config = try JSONSerialization.data(withJSONObject: ["model_type": type])
                #expect(ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(alias, configData: config))
            }
            for config in [nil, Data("{broken".utf8), Data("{}".utf8),
                Data(#"{"model_type":"mimo_v2","text_config":{"model_type":"qwen4_exp"}}"#.utf8)]
            {
                #expect(!ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(alias, configData: config))
            }
        }
        #expect(!ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(
            "MiMo-V2.5", configData: Data(#"{"model_type":"mimo_v2"}"#.utf8)))
    }

    @Test("head tensors omitted from index remain visible in its referenced shard")
    func incompleteTensorIndex() throws {
        let directory = try fixture(modelType: "qwen4_exp", indexedHead: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = try #require(ModelRuntime.inspectLoadingModelMTP(name: "Flash Next", directory: directory))
        #expect(status.bundleHasMTP)
        #expect(status.isTargetMTPFamily)
    }

    @Test("tuning refusal is separate from head availability")
    func blockedTuningDoesNotEraseAvailability() throws {
        let directory = try fixture(modelType: "qwen3_5")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"native_mtp":{"blocked":true,"manual_blocked":true}}"#.utf8)
            .write(to: directory.appendingPathComponent("vmlx_mtp_tuning.json"))
        let status = try #require(ModelRuntime.inspectLoadingModelMTP(name: "27B", directory: directory))
        #expect(status.bundleHasMTP)
        #expect(status.isTargetMTPFamily)
        #expect(status.isBlocked)
    }

    @Test("config claims alone and unrelated architectures do not imply usable native MTP")
    func negativeLayouts() throws {
        let headless = try fixture(modelType: "qwen3_5", includeHead: false)
        defer { try? FileManager.default.removeItem(at: headless) }
        let missing = try #require(ModelRuntime.inspectLoadingModelMTP(name: "Qwen", directory: headless))
        #expect(!missing.bundleHasMTP)
        let unrelated = try fixture(modelType: "llama")
        defer { try? FileManager.default.removeItem(at: unrelated) }
        let unsupported = try #require(ModelRuntime.inspectLoadingModelMTP(name: "qwen4_exp", directory: unrelated))
        #expect(unsupported.bundleHasMTP)
        #expect(!unsupported.isTargetMTPFamily)
    }

    @Test("malformed config fails inspection without loading a model")
    func malformedConfig() throws {
        let directory = try fixture(modelType: "qwen3_5")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("config.json"))
        #expect(ModelRuntime.inspectLoadingModelMTP(name: "Qwen", directory: directory) == nil)
    }

    @Test("opt-in installed bundle inspection uses the real engine without loading")
    func installedBundleInventory() throws {
        guard ProcessInfo.processInfo.environment["OSAURUS_MTP_PRELOAD_LOCAL_PROBE"] == "1" else { return }
        struct InventoryRow: Decodable {
            let name: String
            let path: String
            let hasHead: Bool
        }
        let manifest = try #require(ProcessInfo.processInfo.environment["OSAURUS_MTP_PRELOAD_LOCAL_INVENTORY"])
        let rows = try JSONDecoder().decode([InventoryRow].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        #expect(!rows.isEmpty)
        for row in rows {
            let directory = URL(fileURLWithPath: row.path, isDirectory: true)
            let status = try #require(ModelRuntime.inspectLoadingModelMTP(name: row.name, directory: directory))
            let hasHead = row.hasHead
            #expect(status.bundleHasMTP == hasHead)
            #expect(status.isTargetMTPFamily)
            print(
                "MTP-PRELOAD-LOCAL path=\(directory.path) head=\(status.bundleHasMTP) blocked=\(status.isBlocked) status=\(status.statusLine) model_loaded=false"
            )
        }
    }

    @Test("bundled drafter enables default control without inventing a native head")
    func bundledDrafterCapabilityBeforeLoad() throws {
        let directory = try fixture(modelType: "qwen3_5", includeHead: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config =
            #"{"model_type":"qwen3_5","text_config":{"model_type":"qwen3_5_text","hidden_size":5120,"vocab_size":248320,"num_hidden_layers":64}}"#
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        let drafter = directory.appendingPathComponent("dflash2")
        try FileManager.default.createDirectory(at: drafter, withIntermediateDirectories: true)
        try Data(
            #"{"hidden_size":5120,"vocab_size":248320,"num_target_layers":64,"num_hidden_layers":1,"num_attention_heads":40,"num_key_value_heads":8,"head_dim":128,"intermediate_size":64,"dflash_config":{"selector_top_k":16,"selector_rank":256,"conv_kernel_size":2,"conv_group_size":16,"mask_token_id":248070,"target_layer_ids":[5,19,33,47,61]}}"#
                .utf8
        )
        .write(to: drafter.appendingPathComponent("config.json"))
        let before = try #require(ModelRuntime.inspectLoadingModelMTP(name: "27B", directory: directory))
        #expect(!before.speculationAvailable)
        let shapes = try DFlash2ArtifactMetadata.requiredShapes(
            configData: Data(contentsOf: drafter.appendingPathComponent("config.json"))
        )
        var offset = 0
        var header: [String: Any] = [:]
        for (name, shape) in shapes {
            let end = offset + shape.reduce(2, *)
            header[name] = ["dtype": "BF16", "shape": shape, "data_offsets": [offset, end]]
            offset = end
        }
        let bytes = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(bytes.count).littleEndian
        var prefix = withUnsafeBytes(of: &length) { Data($0) }
        prefix.append(bytes)
        let file = drafter.appendingPathComponent("model.safetensors")
        try prefix.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(prefix.count + offset))
        try handle.close()
        let after = try #require(ModelRuntime.inspectLoadingModelMTP(name: "27B", directory: directory))
        #expect(!after.bundleHasMTP)
        #expect(after.bundledDFlash2)
        #expect(after.speculationAvailable)
        #expect(after.familyDefaultOn)
        #expect(!after.speculationBlocked)
    }

    @Test("selected drafter capability and labels agree before loading")
    func selectedDrafterPresentationPolicy() {
        let selected = ModelRuntime.LoadingModelMTPStatus(
            name: "27B",
            bundleHasMTP: false,
            isTargetMTPFamily: true,
            isBlocked: true,
            measuredFamilyAutoDepth: nil,
            selectedDFlash2: true,
            statusLine: "fixture"
        )
        #expect(selected.speculationAvailable)
        #expect(selected.familyDefaultOn)
        #expect(!selected.speculationBlocked)
        #expect(selected.speculationCapabilityDescription == "Compatible selected DFlash 2 drafter detected")
        let bundled = ModelRuntime.LoadingModelMTPStatus(
            name: "27B",
            bundleHasMTP: false,
            isTargetMTPFamily: true,
            isBlocked: false,
            measuredFamilyAutoDepth: nil,
            bundledDFlash2: true,
            statusLine: "fixture"
        )
        #expect(bundled.speculationCapabilityDescription == "Compatible bundled DFlash 2 drafter detected")
    }

    private func fixture(
        modelType: String,
        format: String = "affine",
        indexedHead: Bool = true,
        includeHead: Bool = true
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-mtp-preload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "model_type": modelType,
            "text_config": ["model_type": modelType + "_text", "mtp_num_hidden_layers": 1],
            "quantization": ["mode": format, "bits": format == "jangh" ? 2 : 4, "group_size": 64],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        let head = "mtp.fc.weight", trunk = "model.embed_tokens.weight"
        var header: [String: Any] = [trunk: ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]]
        if includeHead { header[head] = ["dtype": "F32", "shape": [1], "data_offsets": [4, 8]] }
        let json = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(json.count).littleEndian
        var file = Data()
        withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
        file.append(json)
        file.append(Data(repeating: 0, count: includeHead ? 8 : 4))
        try file.write(to: directory.appendingPathComponent("model.safetensors"))
        var weightMap = [trunk: "model.safetensors"]
        if includeHead && indexedHead { weightMap[head] = "model.safetensors" }
        try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        return directory
    }
}
