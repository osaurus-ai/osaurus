import Foundation
import Testing
@testable import OsaurusCore

@Suite("Independent hosted reasoning-off wire audit")
struct HostedReasoningOffAuditTests {
    @Test(arguments: ["api.fireworks.ai", "openrouter.ai"])
    func hostedPresetUsesItsDocumentedWireContract(host: String) async throws {
        let service = RemoteProviderService(
            provider: RemoteProvider(
                name: "audit", host: host, providerProtocol: .https, port: 443,
                basePath: "/v1", authType: .none, providerType: .openaiLegacy),
            models: ["Qwen3.8-Flash-Next"], resolvedHeaders: [:])
        let request = await service.buildChatRequest(
            messages: [ChatMessage(role: "user", content: "Synthetic audit only")],
            parameters: GenerationParameters(
                temperature: 0.2, maxTokens: 1024,
                modelOptions: ["disableThinking": .bool(true)]),
            model: "Qwen3.8-Flash-Next", stream: false, tools: nil, toolChoice: nil)
        let data = try JSONEncoder().encode(request)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        print("HOSTED_WIRE_AUDIT host=\(host) body=\(String(decoding: data, as: UTF8.self))")
        #expect(body["chat_template_kwargs"] == nil,
            "Known hosted presets must not receive undocumented self-hosted template fields")
    }
}
