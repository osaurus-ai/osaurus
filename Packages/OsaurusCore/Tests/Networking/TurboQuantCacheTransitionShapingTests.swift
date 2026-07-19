import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("TurboQuant cache transition admin telemetry")
struct TurboQuantCacheTransitionShapingTests {
    @Test("admin JSON reports exact mixed Gemma before and after topology")
    func mixedGemmaTransition() throws {
        let transition = TurboQuantCacheTransitionSnapshot(
            before: ModelCacheTopologySnapshot(
                layerCount: 48,
                kvLayerCount: 8,
                rotatingKVLayerCount: 40
            ),
            after: ModelCacheTopologySnapshot(
                layerCount: 48,
                turboQuantKVLayerCount: 8,
                rotatingKVLayerCount: 40
            )
        )

        let object = HTTPHandler.turboQuantCacheTransitionJSONObject(transition)
        let before = try #require(object["before"] as? [String: Any])
        let after = try #require(object["after"] as? [String: Any])

        #expect(object["converted_turbo_quant_kv_layer_count"] as? Int == 8)
        #expect(before["layer_count"] as? Int == 48)
        #expect(before["kv_layer_count"] as? Int == 8)
        #expect(before["turbo_quant_kv_layer_count"] as? Int == 0)
        #expect(before["rotating_kv_layer_count"] as? Int == 40)
        #expect(after["layer_count"] as? Int == 48)
        #expect(after["kv_layer_count"] as? Int == 0)
        #expect(after["turbo_quant_kv_layer_count"] as? Int == 8)
        #expect(after["rotating_kv_layer_count"] as? Int == 40)
    }
}
