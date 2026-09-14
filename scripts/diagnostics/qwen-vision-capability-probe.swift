// Run with the production ModelFamilyNames.swift and ModelMediaCapabilities.swift.
// This records detector behavior only. It never loads a model or proves inference.
import Foundation

@main
struct QwenVisionCapabilityProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-vision-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var rows: [[String: Any]] = []

        func record(_ name: String, _ caps: ModelMediaCapabilities.Capabilities) {
            rows.append([
                "case": name, "image": caps.supportsImage,
                "video": caps.supportsVideo, "audio": caps.supportsAudio,
            ])
        }
        for name in ["Qwen3.6-27B-4bit", "Qwen3.8-27B-4bit", "Qwen3-VL-4B-4bit"] {
            record("name_only:\(name)", ModelMediaCapabilities.from(modelId: name))
        }
        for (label, config) in [
            ("no_vision", #"{"model_type":"qwen3_5"}"#),
            ("null_vision", #"{"model_type":"qwen3_5","vision_config":null}"#),
            ("empty_vision", #"{"model_type":"qwen3_5","vision_config":{}}"#),
            ("vision_without_weights", #"{"model_type":"qwen3_5","vision_config":{"hidden_size":1152}}"#),
        ] {
            let dir = root.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
            record(label, ModelMediaCapabilities.from(directory: dir, modelId: "renamed-local-model"))
        }
        let missing = root.appendingPathComponent("missing")
        record("missing_bundle_with_vl_name", ModelMediaCapabilities.from(
            directory: missing, modelId: "Qwen3-VL-4B-4bit"))
        record("composer_name_overrides_negative_vision_fact", ModelMediaCapabilities.composerCapabilities(
            modelId: "Qwen3-VL-4B-4bit", fallbackSupportsImages: false, localModelType: "qwen3_5"))
        for path in CommandLine.arguments.dropFirst() {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            record("actual_bundle:\(path)", ModelMediaCapabilities.from(
                directory: dir, modelId: dir.lastPathComponent))
            record("same_bundle_neutral_alias:\(path)", ModelMediaCapabilities.from(
                directory: dir, modelId: "neutral-local-model"))
            record("same_bundle_nemotron_alias:\(path)", ModelMediaCapabilities.from(
                directory: dir, modelId: "Nemotron-3-Ultra-Local"))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "scope": "Executed production capability functions; no model inference",
            "rows": rows,
        ], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
