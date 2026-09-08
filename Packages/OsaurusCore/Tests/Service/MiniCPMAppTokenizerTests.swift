import Foundation
import MLXLMCommon
import Testing

#if canImport(OsaurusCore)
    @testable import OsaurusCore
#endif

/// Exercises the app-owned bridge, not the engine's separate macro bridge.
/// A byte-level tokenizer fixture requires no model bundle or weights on CI.
@Suite(.serialized)
struct MiniCPMAppTokenizerTests {
    private static let nativeTemplate = #"""
        {% if tools %}{{ '<function name="example"><param name="value"><![CDATA[x]]></param></function>\n' }}{% endif %}
        {% for m in messages %}{{ '<|im_start|>' + m.role + '\n' + m.content + '<|im_end|>\n' }}{% endfor %}
        {% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% if enable_thinking is defined %}{% if enable_thinking %}{{ '<think>\n' }}{% else %}{{ '<think>\n\n</think>\n\n' }}{% endif %}{% endif %}{% endif %}
        """#

    private func fixture(template: Any) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minicpm-app-tokenizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // GPT byte-to-Unicode alphabet: lossless text round-trip without merges.
        let visible = Array(33 ... 126) + Array(161 ... 172) + Array(174 ... 255)
        var codepoints = Dictionary(uniqueKeysWithValues: visible.map { ($0, $0) })
        var next = 256
        for byte in 0 ... 255 where codepoints[byte] == nil {
            codepoints[byte] = next
            next += 1
        }
        var vocab: [String: Int] = [:]
        for byte in 0 ... 255 { vocab[String(UnicodeScalar(codepoints[byte]!)!)] = byte }
        let special = ["<s>", "<|im_start|>", "<|im_end|>", "<think>", "</think>"]
        let added: [[String: Any]] = special.enumerated().map { index, token in
            vocab[token] = 256 + index
            return [
                "id": 256 + index, "content": token, "special": true,
                "single_word": false, "lstrip": false, "rstrip": false, "normalized": false,
            ]
        }
        let tokenizer: [String: Any] = [
            "version": "1.0", "added_tokens": added,
            "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true],
            "decoder": ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true],
            "model": ["type": "BPE", "vocab": vocab, "merges": [] as [String]],
        ]
        let config: [String: Any] = [
            "tokenizer_class": "PreTrainedTokenizerFast", "bos_token": "<s>",
            "eos_token": "<|im_end|>", "chat_template": template,
            "clean_up_tokenization_spaces": false,
        ]
        for (name, object) in [
            ("tokenizer.json", tokenizer), ("tokenizer_config.json", config),
            ("config.json", ["model_type": "llama"] as [String: Any]),
        ] {
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test(arguments: [false, true])
    func appPreservesNativeTemplateForBothConfiguredShapes(named: Bool) async throws {
        let template: Any =
            named
            ? [
                ["name": "default", "template": Self.nativeTemplate],
                ["name": "tool_use", "template": Self.nativeTemplate],
            ]
            : Self.nativeTemplate
        let directory = try fixture(template: template)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: directory)
        let controllable = try #require(tokenizer as? any GenerationPromptControllableTokenizer)
        let parameters: [String: any Sendable] = [
            "type": "object", "properties": ["path": ["type": "string"]], "required": ["path"],
        ]
        let function: [String: any Sendable] = ["name": "read_file", "parameters": parameters]
        let tools: [[String: any Sendable]] = [["type": "function", "function": function]]
        for thinking: Bool? in [nil, true, false] {
            let context: [String: any Sendable]? = thinking.map { ["enable_thinking": $0] }
            let messages: [[String: any Sendable]] = [["role": "user", "content": "Read note.md"]]
            let tokens = try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: context)
            let text = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
            let tail =
                "<|im_start|>assistant\n"
                + (thinking == true ? "<think>\n" : thinking == false ? "<think>\n\n</think>\n\n" : "")
            #expect(text.contains("<function name=\"example\">"))
            #expect(!text.contains("<function="))
            #expect(text.hasSuffix(tail), "Native tail changed: \(text.suffix(100).debugDescription)")
            let history = try controllable.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: context,
                addGenerationPrompt: false
            )
            #expect(tokens.prefix(history.count).elementsEqual(history))
            #expect(tokenizer.decode(tokenIds: history, skipSpecialTokens: false).hasSuffix("<|im_end|>\n"))
        }
    }

    @Test func nativeRenderErrorsDoNotFallBackToForeignGrammar() async throws {
        let directory = try fixture(template: "{{ raise_exception('native-sentinel') }}" + Self.nativeTemplate)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: directory)
        let function: [String: any Sendable] = ["name": "read_file", "parameters": ["type": "object"]]
        #expect(throws: (any Error).self) {
            try tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Read note.md"]],
                tools: [["type": "function", "function": function]],
                additionalContext: nil
            )
        }
    }

    @Test(
        .enabled(
            if: FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("models/OsaurusAI/MiniCPM5-2B-JANG_8M/tokenizer.json").path
            )
        )
    )
    func actualBundleUsesAppLoaderWithNativeToolsAndTails() async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models/OsaurusAI/MiniCPM5-2B-JANG_8M")
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(
            from: JangLoader.resolveChatTemplateSidecarSubstitution(for: directory)
        )
        let function: [String: any Sendable] = [
            "name": "read_file", "description": "Read a file",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
                as [String: any Sendable],
        ]
        for thinking: Bool? in [nil, true, false] {
            let context: [String: any Sendable]? = thinking.map { ["enable_thinking": $0] }
            let ids = try tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Read note.md"]],
                tools: [["type": "function", "function": function]],
                additionalContext: context
            )
            let text = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
            let tail =
                "<|im_start|>assistant\n"
                + (thinking == true ? "<think>\n" : thinking == false ? "<think>\n\n</think>\n\n" : "")
            #expect(text.contains("<function name=\""))
            #expect(!text.contains("<function="))
            #expect(text.hasSuffix(tail), "Actual app loader tail: \(text.suffix(100).debugDescription)")
        }
    }
}
