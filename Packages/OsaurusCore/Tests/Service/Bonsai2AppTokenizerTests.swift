import Foundation
import MLXLMCommon
import MLXVLM
import Testing

@testable import OsaurusCore

/// Opt-in actual artifacts, app-owned loader and option-to-request transport.
/// No model weights are opened. This is not app UI/persistence/model proof.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BONSAI2_PROTOCOL_BUNDLE_ROOT"] != nil))
struct Bonsai2AppTokenizerTests {
    private static let bundles = ["Bonsai-2-27B-Ternary-JANG", "Bonsai-2-27B-1.75bit-JANG"]

    private static let tools: [ToolSpec] = {
        let path: ToolSpec = ["type": "string"]
        let parameters: ToolSpec = [
            "type": "object", "properties": ["path": path],
            "required": ["path"], "additionalProperties": false,
        ]
        let function: ToolSpec = ["name": "read_note", "parameters": parameters]
        return [["type": "function", "function": function]]
    }()

    private func context(
        modelID: String,
        declaration: DeclaredReasoningEffort.Declaration,
        effort: String?,
        preserveThinking: Bool? = nil
    ) throws -> [String: any Sendable] {
        // This intentionally isolates disk discovery from option wiring. The
        // declaration is decoded from the real artifact by the caller, not
        // invented in the fixture. Live cold discovery is a separate gate.
        DeclaredReasoningEffort.testDeclarationOverride = { $0 == modelID ? declaration : nil }
        defer { DeclaredReasoningEffort.testDeclarationOverride = nil }
        let capabilities = try #require(ModelProfileRegistry.reasoningCapabilities(for: modelID))
        #expect(capabilities.levels.map(\.id) == ["none", "low", "medium", "xhigh"])
        #expect(capabilities.defaultLevelId == "xhigh")
        var persisted: [String: ModelOptionValue] = [:]
        if let effort { persisted["reasoningEffort"] = .string(effort) }
        // Codable round-trip covers storage representation, NOT UI persistence.
        let decoded = try JSONDecoder().decode(
            [String: ModelOptionValue].self,
            from: JSONEncoder().encode(persisted)
        )
        var normalized = ModelProfileRegistry.normalizedOptions(for: modelID, persisted: decoded)
        #expect(normalized == persisted)
        if let preserveThinking { normalized["preserveThinking"] = .bool(preserveThinking) }
        let generation = GenerationParameters(temperature: nil, maxTokens: 256, modelOptions: normalized)
        let context = MLXBatchAdapter.additionalContext(for: generation, modelName: modelID)
        if effort == nil {
            #expect(context["enable_thinking"] == nil && context["reasoning_effort"] == nil)
        } else if effort == "none" {
            #expect(context["enable_thinking"] as? Bool == false)
            #expect(context["reasoning_effort"] == nil)
        } else {
            #expect(context["enable_thinking"] as? Bool == true)
            #expect(context["reasoning_effort"] as? String == effort)
        }
        return context
    }

    private func toolJSON(_ rendered: String) throws -> MLXLMCommon.JSONValue {
        let open = try #require(rendered.range(of: "<tools>"))
        let close = try #require(rendered.range(of: "</tools>", range: open.upperBound ..< rendered.endIndex))
        return try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(rendered[open.upperBound ..< close.lowerBound].utf8))
    }

    @Test(arguments: Self.bundles)
    func actualNativeControlsSchemasAndHistory(bundle: String) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["BONSAI2_PROTOCOL_BUNDLE_ROOT"])
        let directory = URL(fileURLWithPath: root).appendingPathComponent(bundle)
        let data = try Data(contentsOf: directory.appendingPathComponent("jang_config.json"))
        let declaration = try #require(DeclaredReasoningEffort.parseJangDeclaration(data: data))
        let modelID = "OsaurusAI/" + bundle
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(
            from: JangLoader.resolveChatTemplateSidecarSubstitution(for: directory)
        )
        let controllable = try #require(tokenizer as? any GenerationPromptControllableTokenizer)
        let history: [MLXLMCommon.Chat.Message] = [
            .system("Keep note values unchanged."), .user("Read note.md"),
            .init(
                role: .assistant,
                content: "",
                reasoningContent: "Check the saved value.",
                toolCalls: [
                    MLXLMCommon.ToolCall(
                        id: "call-007",
                        function: .init(name: "read_note", arguments: ["path": MLXLMCommon.JSONValue.string("note.md")])
                    )
                ]
            ),
            .tool("NOTE_CODE=007", toolCallId: "call-007"), .user("What code was read?"),
        ]
        let expected = try JSONDecoder().decode(
            MLXLMCommon.JSONValue.self,
            from: JSONSerialization.data(withJSONObject: Self.tools[0])
        )
        for effort: String? in [nil, "none", "low", "medium", "xhigh"] {
            let context = try context(modelID: modelID, declaration: declaration, effort: effort)
            // Both the text generator and the VLM generator must preserve the
            // same tool-history metadata through the actual app tokenizer.
            for messages in [
                DefaultMessageGenerator().generate(messages: history),
                Qwen3VLMessageGenerator().generate(messages: history),
            ] {
                let ids = try tokenizer.applyChatTemplate(
                    messages: messages,
                    tools: Self.tools,
                    additionalContext: context
                )
                let rendered = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                let observed = try toolJSON(rendered)
                #expect(observed == expected)
                #expect(rendered.contains("<function=read_note>"))
                #expect(rendered.contains("Check the saved value."))
                #expect(rendered.contains("NOTE_CODE=007"))
                #expect(rendered.hasSuffix(effort == "none" ? "<think>\n\n</think>\n\n" : "<think>\n"))
                if effort == "low" { #expect(rendered.contains("Reasoning effort is set to low.")) }
                if effort == "xhigh" || effort == nil {
                    #expect(rendered.contains("Reasoning effort is set to xhigh."))
                }
                if effort == "medium" || effort == "none" { #expect(!rendered.contains("Reasoning effort is set to")) }
                for generationPrompt in [false, true] {
                    let controlled = try controllable.applyChatTemplate(
                        messages: messages,
                        tools: Self.tools,
                        additionalContext: context,
                        addGenerationPrompt: generationPrompt
                    )
                    #expect(ids.starts(with: controlled))
                    #expect(generationPrompt ? controlled == ids : controlled.count < ids.count)
                    let observed = try toolJSON(tokenizer.decode(tokenIds: controlled, skipSpecialTokens: false))
                    #expect(observed == expected)
                }
            }
            print("BONSAI2_APP_TOKENIZER bundle=\(bundle) effort=\(effort ?? "native-default") weights_loaded=false")
        }
        let strippedContext = try context(
            modelID: modelID,
            declaration: declaration,
            effort: "medium",
            preserveThinking: false
        )
        let strippedIDs = try tokenizer.applyChatTemplate(
            messages: DefaultMessageGenerator().generate(messages: history),
            tools: Self.tools,
            additionalContext: strippedContext
        )
        #expect(!tokenizer.decode(tokenIds: strippedIDs, skipSpecialTokens: false).contains("Check the saved value."))
        for generationPrompt in [false, true] {
            #expect(throws: (any Error).self) {
                _ = try controllable.applyChatTemplate(
                    messages: [["role": "user", "content": "Read note.md"]],
                    tools: Self.tools,
                    additionalContext: ["reasoning_effort": "unsupported", "enable_thinking": true],
                    addGenerationPrompt: generationPrompt
                )
            }
            #expect(throws: (any Error).self) {
                _ = try controllable.applyChatTemplate(
                    messages: [],
                    tools: nil,
                    additionalContext: nil,
                    addGenerationPrompt: generationPrompt
                )
            }
        }
    }
}
