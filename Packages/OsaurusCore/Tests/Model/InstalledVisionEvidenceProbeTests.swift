import Foundation
import Testing
@testable import OsaurusCore

@Suite("Installed vision evidence probe")
struct InstalledVisionEvidenceProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OSAURUS_VISION_PROOF_BUNDLES"] != nil))
    func inspectInstalledBundles() throws {
        let paths = (ProcessInfo.processInfo.environment["OSAURUS_VISION_PROOF_BUNDLES"] ?? "")
            .split(separator: "\n").map(String.init)
        var rows: [[String: Any]] = []
        for path in paths {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let start = Date()
            let result = LocalVisionEvidence.inspect(directory, refresh: true)
            let caps = ModelMediaCapabilities.from(directory: directory, modelId: "neutral")
            rows.append(["directory": path, "model_type": result.modelType,
                         "vision": result.hasVision, "video": caps.supportsVideo,
                         "audio": caps.supportsAudio, "reason": result.reason,
                         "tensor_count": result.tensorNames.count,
                         "inspection_seconds": Date().timeIntervalSince(start)])
            #expect(result.hasVision, "\(path): \(result.reason)")
            for alias in ["neutral", "Step-3.7", "Nemotron-3-Ultra"] {
                #expect(ModelMediaCapabilities.from(directory: directory, modelId: alias) == caps)
            }
        }
        if let output = ProcessInfo.processInfo.environment["OSAURUS_VISION_PROOF_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }
}
