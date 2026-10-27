import Foundation
import Testing
@testable import OsaurusCore

@Suite("Reserved chat-template token parameters")
struct ChatTemplateReservedTokenTests {
    @Test(arguments: [
        "bos_token", "eos_token", "unk_token", "sep_token", "pad_token",
        "cls_token", "mask_token", "additional_special_tokens",
    ])
    func tokenizerOwnedTokenKeysRejectExplicitOverrides(_ key: String) throws {
        // Reject explicit null as well as string/array forms. A configured
        // token would otherwise win silently; an absent token could be invented.
        let values: [JSONValue] = [.string("replacement"), .null, .array([.string("replacement")])]
        for value in values {
            do {
                try ChatTemplateParameters.validate([key: value])
                Issue.record("Tokenizer-owned parameter was accepted: \(key)")
            } catch let error as ChatTemplateParameters.InvalidParameter {
                #expect(error.key == key)
                #expect(error.localizedDescription.contains("chat_template_kwargs.\(key)"))
            }
        }
    }

    @Test func requestOwnedStructureAndInternalSignalRemainReserved() {
        for key in ["messages", "tools", "add_generation_prompt", ChatTemplateParameters.explicitContextKey] {
            #expect(throws: ChatTemplateParameters.InvalidParameter.self) {
                try ChatTemplateParameters.validate([key: .null])
            }
        }
    }

    @Test func nestedTokenNamesAndArbitraryModelParametersKeepTheirJSONValues() throws {
        let values: [String: JSONValue] = [
            "template": .object([
                "bos_token": .null,
                "eos_token": .object(["type": .string("string")]),
                "tools": .array([.null, .bool(false), .number(0)]),
            ]),
            "enable_thinking": .bool(false),
            "reasoning_effort": .string("high"),
            "tools_in_user_message": .bool(true),
            "image_token_index": .number(42),
            "json_schema": .object(["title": .string("Extraction")]),
            "user_custom_flag": .null,
        ]
        try ChatTemplateParameters.validate(values)
        let restored = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(values))
        #expect(restored == values)
        try ChatTurnOverrides(templateKwargs: values).validate()
    }

    @Test func composerUsesTheSameExplicitTokenValidation() {
        #expect(throws: ChatTemplateParameters.InvalidParameter.self) {
            try ChatTurnOverrides(templateKwargs: ["bos_token": .string("replacement")]).validate()
        }
        #expect(throws: ChatTemplateParameters.InvalidParameter.self) {
            try ChatTurnOverrides(templateKwargs: ["additional_special_tokens": .array([])]).validate()
        }
    }

    @Test func absentAndEmptyParametersStillInherit() throws {
        try ChatTemplateParameters.validate(nil)
        try ChatTemplateParameters.validate([:])
        try ChatTurnOverrides().validate()
    }
}
