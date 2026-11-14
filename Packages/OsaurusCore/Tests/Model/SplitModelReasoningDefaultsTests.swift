import Foundation
import Testing
import MLXLMCommon
@testable import MLXLLM
@testable import MLXVLM
@testable import OsaurusCore

@Suite("Bundle effort vocabulary and effective processor defaults", .serialized)
struct SplitModelReasoningDefaultsTests {
    private func fixture(_ enabled: Bool = true) -> [String: Any] {
        [
            "format": "jang", "capabilities": ["supports_thinking": true],
            "chat": [
                "thinking": ["supported": true, "template_flag": "enable_thinking", "default": enabled],
                "reasoning_effort": ["values": ["low", "high", "max"], "default": "high"],
            ],
        ]
    }

    @Test(arguments: [true, false])
    func pickerAndRuntimeAgreeOnThePublishedDefaults(_ enabled: Bool) throws {
        let root = fixture(enabled)
        let declaration = try #require(
            DeclaredReasoningEffort.parseJangDeclaration(
                data: JSONSerialization.data(withJSONObject: root)
            )
        )
        #expect(declaration.control == .levels(["low", "high", "max"], defaultLevel: enabled ? "high" : "none"))
        let config = try JangLoader.parseConfig(from: root)
        let llm = try #require(
            llmDefaultAdditionalContext(
                modelType: "deepseek_v41",
                capabilities: config.capabilities,
                generationConfig: nil,
                chatConfig: config.chat
            )
        )
        let vlm = try #require(
            VLMDefaultContextUserInputProcessor.defaultContext(
                capabilities: config.capabilities,
                chatConfig: config.chat
            )
        )
        for context in [llm, vlm] {
            #expect(context["enable_thinking"] as? Bool == enabled)
            #expect(context["reasoning_effort"] as? String == (enabled ? "high" : nil))
        }
        if enabled { #expect(DeepseekV4ChatEncoder.reasoningBudget(from: llm) == 75) }
    }

    @Test
    func existingDeclarationAndExplicitOffRemainAuthoritative() throws {
        var root = fixture()
        root["reasoning"] = ["supported_reasoning_efforts": ["medium"], "default_reasoning_effort": "medium"]
        let declared = try #require(
            DeclaredReasoningEffort.parseJangDeclaration(
                data: JSONSerialization.data(withJSONObject: root)
            )
        )
        #expect(declared.control == .levels(["medium"], defaultLevel: "medium"))

        root.removeValue(forKey: "reasoning")
        var chat = try #require(root["chat"] as? [String: Any])
        chat["template_kwargs_defaults"] = ["enable_thinking": false]
        root["chat"] = chat
        let off = try #require(
            DeclaredReasoningEffort.parseJangDeclaration(
                data: JSONSerialization.data(withJSONObject: root)
            )
        )
        #expect(off.control == .levels(["low", "high", "max"], defaultLevel: "none"))
    }

    @Test(arguments: ["unsupportedFlag", "missingDefault", "duplicates", "empty"])
    func partialContractsDoNotExposeAnInventedLadder(_ kind: String) throws {
        var root = fixture()
        var chat = try #require(root["chat"] as? [String: Any])
        var thinking = try #require(chat["thinking"] as? [String: Any])
        var effort = try #require(chat["reasoning_effort"] as? [String: Any])
        switch kind {
        case "unsupportedFlag": thinking["template_flag"] = "unsupported_flag"
        case "missingDefault": thinking.removeValue(forKey: "default")
        case "duplicates": effort["values"] = ["low", " LOW "]
        default: effort["values"] = [String]()
        }
        chat["thinking"] = thinking
        chat["reasoning_effort"] = effort
        root["chat"] = chat
        #expect(
            DeclaredReasoningEffort.parseJangDeclaration(
                data: try JSONSerialization.data(withJSONObject: root)
            ) == nil
        )
    }
}
