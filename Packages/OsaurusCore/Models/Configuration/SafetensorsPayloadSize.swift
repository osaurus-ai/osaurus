import Foundation

/// Structural payload validation without reading tensor data or allocating MLX arrays.
/// Use the stored dtype/shape, never a model's logical quantization bit count.
enum SafetensorsPayloadSize {
    static func matches(dtype: String, shape: [Int], byteCount: UInt64) -> Bool {
        let elementBytes: UInt64
        switch dtype {
        case "BOOL", "I8", "U8", "F8_E4M3", "F8_E8M0": elementBytes = 1
        case "I16", "U16", "F16", "BF16": elementBytes = 2
        case "I32", "U32", "F32": elementBytes = 4
        case "I64", "U64", "C64": elementBytes = 8
        default: return false
        }
        // These storage spellings match the pinned MLX safetensors reader.
        // Packed JANG/QAT weights retain their actual integer payload dtype.
        var expected = elementBytes
        for dimension in shape {
            guard dimension >= 0 else { return false }
            let (next, overflow) = expected.multipliedReportingOverflow(by: UInt64(dimension))
            guard !overflow else { return false }
            expected = next
        }
        return expected == byteCount
    }
}
