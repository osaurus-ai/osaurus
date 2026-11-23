import Foundation
import Testing

@testable import OsaurusCore

/// Regression coverage for APPLE-MACOS-324: the shard/index cross-check in
/// `LocalVisionEvidence.tensorPayloadSizes` groups the weight map once
/// instead of re-filtering it per shard.
struct TensorPayloadSizesShardIndexTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tensor-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a shard whose tensors are F32 vectors of the given lengths.
    private func writeShard(_ url: URL, tensors: [(String, Int)]) throws {
        var header: [String: Any] = [:]
        var offset: UInt64 = 0
        for (name, count) in tensors {
            let bytes = UInt64(count * 4)
            header[name] = ["dtype": "F32", "shape": [count], "data_offsets": [offset, offset + bytes]]
            offset += bytes
        }
        let json = try JSONSerialization.data(withJSONObject: header)
        var data = Data()
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(Data(count: Int(offset)))
        try data.write(to: url)
    }

    private func writeIndex(_ directory: URL, _ map: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["weight_map": map])
        try data.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    }

    @Test func multiShardIndexReturnsEveryTensorSize() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var map: [String: String] = [:]
        var expected: [String: UInt64] = [:]
        for shard in 0..<8 {
            let file = "model-\(shard).safetensors"
            let tensors = (0..<16).map { ("layers.\(shard).w\($0)", $0 + 1) }
            try writeShard(dir.appendingPathComponent(file), tensors: tensors)
            for (name, count) in tensors {
                map[name] = file
                expected[name] = UInt64(count * 4)
            }
        }
        try writeIndex(dir, map)
        #expect(try LocalVisionEvidence.tensorPayloadSizes(dir) == expected)
    }

    @Test func indexNamingTensorAbsentFromShardThrows() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeShard(dir.appendingPathComponent("a.safetensors"), tensors: [("x", 2)])
        try writeShard(dir.appendingPathComponent("b.safetensors"), tensors: [("y", 2)])
        try writeIndex(dir, ["x": "a.safetensors", "y": "b.safetensors", "z": "b.safetensors"])
        #expect(throws: (any Error).self) { try LocalVisionEvidence.tensorPayloadSizes(dir) }
    }
}
