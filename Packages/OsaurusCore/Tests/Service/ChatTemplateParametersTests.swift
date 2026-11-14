import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct ChatTemplateParametersTests {
    private let kwargs: [String: OsaurusCore.JSONValue] = [
        "template": .object(["name": .string("string"), "optional": .null]),
        "examples": .array([.object(["input": .string("Ada"), "output": .null]), .null]),
        "strict": .bool(false), "threshold": .number(0), "label": .string("extract")
    ]

    private func chat(_ kwargs: [String: OsaurusCore.JSONValue]) throws -> ChatCompletionRequest {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "extractor", "messages": [["role": "user", "content": "Ada"]],
            "chat_template_kwargs": kwargs.mapValues(\.anyValue)
        ])
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
    }

    @Test func dictionarySurvivesChatCopiesEncodingAndResponsesCompatibility() throws {
        let original = try chat(kwargs)
        #expect(original.chat_template_kwargs == kwargs)
        #expect(original.withModel("renamed").chat_template_kwargs == kwargs)
        #expect(original.withContext(messages: [], tools: nil, toolChoice: nil).chat_template_kwargs == kwargs)
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ChatCompletionRequest.self, from: encoded).chat_template_kwargs == kwargs)
        let typed = ResponsesInferenceRequest(chatCompletion: original)
        #expect(typed.generation.templateKwargs == kwargs)
        #expect(typed.chatCompletionsCompatibilityRequest().chat_template_kwargs == kwargs)
    }

    @Test func responsesExtensionsRetainZerosAndTemplateValues() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "extractor", "input": "Ada", "temperature": 0, "top_p": 0,
            "top_k": 0, "min_p": 0, "enable_thinking": false,
            "reasoning": ["effort": "low"], "chat_template_kwargs": kwargs.mapValues(\.anyValue)
        ])
        let wire = try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        let request = try wire.toResponsesInferenceRequest()
        #expect(request.generation.temperature == 0)
        #expect(request.generation.topP == 0)
        #expect(request.generation.topK == 0)
        #expect(request.generation.minP == 0)
        #expect(request.generation.enableThinking == false)
        #expect(request.generation.reasoningEffort == "low")
        #expect(request.generation.templateKwargs == kwargs)
        #expect(wire.toChatCompletionRequest().chat_template_kwargs == kwargs)
        #expect(wire.toChatCompletionRequest().top_k == 0)
    }

    @Test func absentVariablesStayAbsent() throws {
        let wire = try JSONDecoder().decode(OpenResponsesRequest.self,
            from: Data(#"{"model":"extractor","input":"Ada"}"#.utf8))
        let generation = try wire.toResponsesInferenceRequest().generation
        #expect(generation.templateKwargs == nil)
        #expect(generation.temperature == nil && generation.topP == nil && generation.topK == nil)
        #expect(generation.enableThinking == nil && generation.reasoningEffort == nil)
    }

    @Test func recursiveContextPreservesNullAndExplicitFalse() throws {
        let context = kwargs.mapValues(\.templateContextValue)
        let template = try #require(context["template"] as? [String: any Sendable])
        #expect(template["optional"] is NSNull)
        let examples = try #require(context["examples"] as? [any Sendable])
        #expect(examples[1] is NSNull)
        #expect(context["strict"] as? Bool == false)
        #expect(context["threshold"] as? Int == 0)
        #expect(OsaurusCore.JSONValue.number(2).templateContextValue as? Int == 2)
        #expect(OsaurusCore.JSONValue.number(2.5).templateContextValue as? Double == 2.5)
        #expect(OsaurusCore.JSONValue.number(Double.greatestFiniteMagnitude).templateContextValue as? Double
            == Double.greatestFiniteMagnitude)
    }

    @Test func realAdapterContextKeepsExtractionVariablesAndTypedControlsWin() throws {
        var values = kwargs
        values["enable_thinking"] = .bool(false)
        values["tool_choice"] = .string("none")
        let generation = GenerationParameters(temperature: nil, maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)], templateKwargs: values)
        let context = MLXBatchAdapter.additionalContext(for: generation, modelName: "extractor", toolChoice: .required)
        #expect(context["label"] as? String == "extract")
        #expect(context["enable_thinking"] as? Bool == true)
        #expect(context["tool_choice"] as? String == "required")
        #expect((context["template"] as? [String: any Sendable])?["optional"] is NSNull)
    }

    @Test(arguments: ["messages", "tools", "add_generation_prompt"])
    func structuralKeysCannotReplaceCanonicalRequestInputs(key: String) throws {
        #expect(throws: ChatTemplateParameters.InvalidParameter.self) {
            try ChatTemplateParameters.validate([key: .string("replacement")])
        }
        #expect(throws: ChatTemplateParameters.InvalidParameter.self) { try chat([key: .null]) }
    }

    @Test func compatibleRemoteWiresPreserveArbitraryVariablesAndSampling() async throws {
        let service = RemoteProviderService(provider: RemoteProvider(
            name: "fixture", host: "localhost", providerProtocol: .http, port: 8000,
            basePath: "/v1", authType: .none, providerType: .openaiLegacy),
            models: ["extractor"], resolvedHeaders: [:])
        let request = await service.buildChatRequest(messages: [ChatMessage(role: "user", content: "Ada")],
            parameters: GenerationParameters(temperature: 0, maxTokens: 16, topPOverride: 0.9,
                topKOverride: 0, minPOverride: 0, templateKwargs: kwargs), model: "extractor", stream: true,
            tools: nil, toolChoice: nil)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(wire["top_k"] as? Int == 0)
        #expect(wire["min_p"] as? Double == 0)
        let rendered = try #require(wire["chat_template_kwargs"] as? [String: Any])
        #expect((rendered["template"] as? [String: Any])?["optional"] is NSNull)
        let responses = try request.toOpenResponsesRequest()
        #expect(responses.chat_template_kwargs == kwargs)
        #expect(responses.top_k == 0 && responses.min_p == 0)
        #expect(throws: RemoteProviderServiceError.self) { try request.toCodexOpenResponsesRequest() }
    }
    @Test func appTokenizerRendersExtractionContextAndReplaysExactTokens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte); scalars.append(256 + extra); extra += 1
        }
        var vocab: [String: Int] = [:]
        for (byte, scalar) in zip(bytes, scalars) { vocab[String(Unicode.Scalar(scalar)!)] = byte }
        let config: [String: Any] = ["tokenizer_class": "GPT2Tokenizer", "clean_up_tokenization_spaces": false,
            "chat_template": "{{ template | tojson }}|{{ examples | tojson }}|{{ messages[-1]['content'] }}|{{ enable_thinking | default(false) }}|{{ tools | default([]) | length }}"]
        let data: [String: Any] = ["model": ["type": "BPE", "vocab": vocab, "merges": []],
            "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false], "decoder": ["type": "ByteLevel"]]
        for (name, value) in [("tokenizer_config.json", config), ("tokenizer.json", data)] {
            try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent(name))
        }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: directory)
        let messages: [[String: any Sendable]] = [["role": "user", "content": "Ada"]]
        func render(_ values: [String: OsaurusCore.JSONValue], thinking: Bool, offeredTools: Bool) throws -> [Int] {
            var context = values.mapValues(\.templateContextValue)
            context["enable_thinking"] = thinking
            let tools: [[String: any Sendable]]? = offeredTools
                ? [["type": "function", "function": ["name": "lookup"] as [String: any Sendable]]] : nil
            return try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: context)
        }
        let first = try render(kwargs, thinking: true, offeredTools: false)
        let firstText = tokenizer.decode(tokenIds: first)
        #expect(firstText.contains("Ada"))
        #expect(firstText.contains("optional") && firstText.contains("null"))
        #expect(firstText.contains("name") && firstText.contains("string"))
        var different = kwargs; different["template"] = .object(["city": .string("string")])
        let changed = try render(different, thinking: false, offeredTools: true)
        #expect(changed != first)
        #expect(tokenizer.decode(tokenIds: changed).contains("city"))
        #expect(try render(kwargs, thinking: true, offeredTools: false) == first)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OSAURUS_NUEXTRACT3_TOKENIZER_DIR"] != nil))
    func actualNuExtractTemplateChangesAcrossExtractionTurnsAndReplaysExactly() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["OSAURUS_NUEXTRACT3_TOKENIZER_DIR"])
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: URL(fileURLWithPath: path))
        let messages: [[String: any Sendable]] = [["role": "user", "content": "Ada Lovelace was born in 1815."]]
        func tokens(template: String, instruction: String, thinking: Bool) throws -> [Int] {
            let parameters = GenerationParameters(temperature: nil, maxTokens: 64,
                templateKwargs: ["template": .string(template), "mode": .string("structured"),
                    "instructions": .string(instruction), "enable_thinking": .bool(thinking)])
            return try tokenizer.applyChatTemplate(messages: messages, tools: nil,
                additionalContext: MLXBatchAdapter.additionalContext(for: parameters, modelName: "numind/NuExtract3"))
        }
        let schema = #"{"name":"verbatim-string","born":"integer"}"#
        let first = try tokens(template: schema, instruction: "Use the full name.", thinking: true)
        let visible = tokenizer.decode(tokenIds: first)
        #expect(visible.contains("【task】structured"))
        #expect(visible.contains("【template_start】" + schema + "【template_end】"))
        #expect(visible.contains("【instructions_start】Use the full name.【instructions_end】"))
        let second = try tokens(template: #"{"birth_year":"integer"}"#, instruction: "Only the year.", thinking: false)
        #expect(second != first)
        #expect(tokenizer.decode(tokenIds: second).contains("birth_year"))
        #expect(try tokens(template: schema, instruction: "Use the full name.", thinking: true) == first)
        let invalid = GenerationParameters(temperature: nil, maxTokens: 64,
            templateKwargs: ["mode": .string("structured")])
        #expect(throws: (any Error).self) {
            try tokenizer.applyChatTemplate(messages: messages, tools: nil,
                additionalContext: MLXBatchAdapter.additionalContext(for: invalid, modelName: "numind/NuExtract3"))
        }
    }

}
