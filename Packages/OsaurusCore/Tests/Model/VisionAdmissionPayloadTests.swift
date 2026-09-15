import Foundation
import MLXVLM
import Testing
@testable import OsaurusCore

@Suite("Vision admission processor and payload validation")
struct VisionAdmissionPayloadTests {
    @Test("an unknown configured processor cannot advertise image input")
    func unknownProcessor() throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try VisionBundleFixture.writeJSON(["processor_class": "NotAnInstalledProcessor"],
            to: root.appendingPathComponent("processor_config.json"))
        let evidence = LocalVisionEvidence.inspect(root, refresh: true)
        #expect(!evidence.hasVision)
        #expect(evidence.reason.contains("registered local processor"))
    }

    @Test("a later processor registration invalidates the cached negative verdict")
    func registrationRefreshesEvidence() async throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = "AdmissionProbe_" + UUID().uuidString
        try VisionBundleFixture.writeJSON(["processor_class": processor],
            to: root.appendingPathComponent("processor_config.json"))
        #expect(!LocalVisionEvidence.inspect(root).hasVision)
        await VLMProcessorTypeRegistry.shared.registerProcessorType(processor) { _, _ in
            throw NSError(domain: "AdmissionMustNotConstructTheProcessor", code: 1)
        }
        // No explicit refresh/model notification: registration changed the evidence.
        #expect(LocalVisionEvidence.inspect(root).hasVision)
    }

    @Test("invalid storage metadata is rejected before image admission",
        arguments: ["invalid-dtype", "wrong-byte-count", "overflow"])
    func invalidPayload(kind: String) throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = Array(LocalVisionEvidence.inspect(root).tensorNames)
        let shape = kind == "overflow" ? [Int.max, Int.max]
            : kind == "wrong-byte-count" ? [1048576] : [1]
        try VisionBundleFixture.writeWeights(names,
            dtype: kind == "invalid-dtype" ? "NOT_A_DTYPE" : "F32", shape: shape,
            to: root.appendingPathComponent("model.safetensors"))
        let evidence = LocalVisionEvidence.inspect(root, refresh: true)
        #expect(!evidence.hasVision)
        #expect(evidence.reason.contains("invalid tensor metadata"))
    }

    @Test("packed integer and floating payloads retain their stored byte sizes",
        arguments: ["BOOL", "I8", "U8", "F8_E4M3", "F8_E8M0", "I16", "U16",
                    "F16", "BF16", "I32", "U32", "F32", "I64", "U64", "C64"])
    func validPayload(dtype: String) throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = Array(LocalVisionEvidence.inspect(root).tensorNames)
        let bytes = ["BOOL": 1, "I8": 1, "U8": 1, "F8_E4M3": 1, "F8_E8M0": 1,
            "I16": 2, "U16": 2, "F16": 2, "BF16": 2, "I32": 4, "U32": 4,
            "F32": 4, "I64": 8, "U64": 8, "C64": 8][dtype]!
        try VisionBundleFixture.writeWeights(names, dtype: dtype, shape: [2, 3],
            payloadBytesPerTensor: 6 * bytes, to: root.appendingPathComponent("model.safetensors"))
        #expect(LocalVisionEvidence.inspect(root, refresh: true).hasVision)
    }

    @Test("payload arithmetic handles scalars, empty shapes and overflow without allocation")
    func payloadArithmetic() {
        #expect(SafetensorsPayloadSize.matches(dtype: "F32", shape: [], byteCount: 4))
        #expect(SafetensorsPayloadSize.matches(dtype: "F32", shape: [0], byteCount: 0))
        #expect(!SafetensorsPayloadSize.matches(dtype: "F32", shape: [-1], byteCount: 4))
        #expect(!SafetensorsPayloadSize.matches(dtype: "U64", shape: [Int.max, 2], byteCount: 8))
        #expect(!SafetensorsPayloadSize.matches(dtype: "F32", shape: [1], byteCount: 3))
    }
}
