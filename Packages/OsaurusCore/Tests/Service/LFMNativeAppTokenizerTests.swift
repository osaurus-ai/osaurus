import Foundation
import MLXLMCommon
import Testing
import VMLXTokenizers

@testable import OsaurusCore

/// Exact published LFM2.5-24B template, exercised with lossless byte tokens.
/// No model weights, Metal, local model availability or skip branch required.
@Suite(.serialized)
struct LFMNativeAppTokenizerTests {
    // chat_template.jinja SHA256: ea663864491de7ade391839479860ca95541f892f72665c73251fbd4643b1bef
    static let nativeTemplate = #"""
        {{- bos_token -}}
        {%- set preserve_thinking = preserve_thinking | default(false) -%}
        
        {%- macro format_arg_value(arg_value) -%}
            {%- if arg_value is string -%}
                {{- "'" + (arg_value | replace("\\", "\\\\") | replace("'", "\\'") | replace("\n", "\\n") | replace("\r", "\\r")) + "'" -}}
            {%- elif arg_value is mapping or arg_value is iterable -%}
                {{- arg_value | tojson -}}
            {%- else -%}
                {{- arg_value | string -}}
            {%- endif -%}
        {%- endmacro -%}
        
        {%- macro parse_content(content) -%}
            {%- if content is string -%}
                {{- content -}}
            {%- elif content is mapping -%}
                {{- content | tojson -}}
            {%- elif content is iterable -%}
                {%- set _ns = namespace(result="") -%}
                {%- for item in content -%}
                    {%- if item is string -%}
                        {%- set _ns.result = _ns.result + item -%}
                    {%- elif item is mapping and item.get("type") == "image" -%}
                        {%- set _ns.result = _ns.result + "<image>" -%}
                    {%- elif item is mapping and item.get("type") == "text" -%}
                        {%- set _ns.result = _ns.result + ((item.get("text") or "") | string) -%}
                    {%- else -%}
                        {%- set _ns.result = _ns.result + (item | tojson) -%}
                    {%- endif -%}
                {%- endfor -%}
                {{- _ns.result -}}
            {%- endif -%}
        {%- endmacro -%}
        
        {%- macro render_tool_calls(tool_calls) -%}
            {%- set tool_calls_ns = namespace(tool_calls=[]) -%}
            {%- for tool_call in tool_calls -%}
                {%- set func = tool_call["function"] if "function" in tool_call else tool_call -%}
                {%- set func_name = func["name"] -%}
                {%- set func_args = func.get("arguments") -%}
                {%- set args_ns = namespace(arg_strings=[]) -%}
                {%- if func_args is mapping -%}
                    {%- for arg_name, arg_value in func_args.items() -%}
                        {%- set args_ns.arg_strings = args_ns.arg_strings + [arg_name + "=" + format_arg_value(arg_value)] -%}
                    {%- endfor -%}
                {%- elif func_args is string and (func_args | trim) not in ["", "{}", "null"] -%}
                    {{- raise_exception("Tool call arguments must be a mapping, got a JSON-encoded string: parse arguments with json.loads() before applying the chat template") -}}
                {%- endif -%}
                {%- set tool_calls_ns.tool_calls = tool_calls_ns.tool_calls + [func_name + "(" + (args_ns.arg_strings | join(", ")) + ")"] -%}
            {%- endfor -%}
            {{- "<|tool_call_start|>[" + (tool_calls_ns.tool_calls | join(", ")) + "]<|tool_call_end|>" -}}
        {%- endmacro -%}
        
        {%- set ns = namespace(system_prompt="", last_user_index=-1) -%}
        {%- if messages and messages[0]["role"] == "system" -%}
            {%- if messages[0].get("content") -%}
                {%- set ns.system_prompt = parse_content(messages[0]["content"]) -%}
            {%- endif -%}
            {%- set messages = messages[1:] -%}
        {%- endif -%}
        {%- if tools -%}
            {%- set ns.system_prompt = ns.system_prompt + ("\n" if ns.system_prompt else "") + "List of tools: [" -%}
            {%- for tool in tools -%}
                {%- if tool is not string -%}
                    {%- set tool = tool | tojson -%}
                {%- endif -%}
                {%- set ns.system_prompt = ns.system_prompt + tool -%}
                {%- if not loop.last -%}
                    {%- set ns.system_prompt = ns.system_prompt + ", " -%}
                {%- endif -%}
            {%- endfor -%}
            {%- set ns.system_prompt = ns.system_prompt + "]" -%}
        {%- endif -%}
        {%- if ns.system_prompt -%}
            {{- "<|im_start|>system\n" + ns.system_prompt + "<|im_end|>\n" -}}
        {%- endif -%}
        {%- for message in messages -%}
            {%- if message["role"] == "user" -%}
                {%- set ns.last_user_index = loop.index0 -%}
            {%- endif -%}
        {%- endfor -%}
        {%- for message in messages -%}
            {{- "<|im_start|>" + message.role + "\n" -}}
            {%- if message.role == "assistant" -%}
                {%- generation -%}
                {%- set keep_thinking = preserve_thinking or loop.index0 > ns.last_user_index -%}
                {%- set thinking = message.thinking or message.reasoning or message.reasoning_content -%}
                {%- set thinking = thinking if thinking is string else "" -%}
                {%- if thinking and keep_thinking -%}
                    {{- "<think>" + thinking + "</think>" -}}
                {%- endif -%}
                {%- set _cfm_tag = "CONTINUE_FINAL_MESSAGE_TAG " -%}
                {%- set _has_cfm = false -%}
                {%- set content = "" -%}
                {%- if message.get("content") -%}
                    {%- set content = parse_content(message.content) -%}
                {%- endif -%}
                {%- if not keep_thinking and "</think>" in content -%}
                    {%- set content = content.split("</think>")[-1] | trim -%}
                {%- endif -%}
                {%- if content.endswith(_cfm_tag) -%}
                    {%- set _has_cfm = true -%}
                    {%- set _trunc_len = (content | length) - (_cfm_tag | length) -%}
                    {%- set content = content[:_trunc_len] -%}
                {%- endif -%}
                {{- content -}}
                {%- if message.tool_calls -%}
                    {{- render_tool_calls(message.tool_calls) -}}
                {%- endif -%}
                {%- if _has_cfm -%}
                    {{- _cfm_tag -}}
                {%- endif -%}
                {{- "<|im_end|>\n" -}}
                {%- endgeneration -%}
            {%- else %}
                {%- if message.get("content") -%}
                    {{- parse_content(message["content"]) -}}
                {%- endif -%}
                {{- "<|im_end|>\n" -}}
            {%- endif %}
        {%- endfor -%}
        {%- if add_generation_prompt -%}
            {{- "<|im_start|>assistant\n<think>" -}}
        {%- endif -%}
        """#

    private func fixture(template: Any) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm-app-tokenizer-\(UUID().uuidString)")
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
        let special = ["<|startoftext|>", "<|im_start|>", "<|im_end|>", "<think>", "</think>", "<|tool_call_start|>", "<|tool_call_end|>"]
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
            "tokenizer_class": "PreTrainedTokenizerFast", "bos_token": "<|startoftext|>",
            "eos_token": "<|im_end|>", "chat_template": template,
            "clean_up_tokenization_spaces": false,
        ]
        for (name, object) in [
            ("tokenizer.json", tokenizer), ("tokenizer_config.json", config),
            ("config.json", ["model_type": "lfm2_moe"] as [String: Any]),
        ] {
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }


    @Test(arguments: [false, true], [false, true])
    func configuredNativeReasoningToolsPreserveTailAndHistory(named: Bool, wrapped: Bool) async throws {
        let configured: Any = named
            ? [["name": "default", "template": Self.nativeTemplate],
               ["name": "tool_use", "template": Self.nativeTemplate]]
            : Self.nativeTemplate
        let directory = try fixture(template: configured)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: directory)
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        let bridge = try #require(tokenizer as? any GenerationPromptControllableTokenizer)
        let optionsSchema: [String: any Sendable] = [
            "type": "object", "additionalProperties": false,
            "properties": ["flag": ["type": "boolean"]] as [String: [String: String]],
        ]
        let textSchema: [String: any Sendable] = [
            "type": ["string", "null"], "enum": ["red\nblue", "other"],
        ]
        let properties: [String: any Sendable] = ["text": textSchema, "options": optionsSchema]
        let parameters: [String: any Sendable] = [
            "type": "object", "additionalProperties": false,
            "properties": properties, "required": ["text"],
        ]
        let function: [String: any Sendable] = [
            "name": "line_count", "description": "Count lines", "parameters": parameters, "strict": true,
        ]
        let tools: [[String: any Sendable]] = wrapped ? [["type": "function", "function": function]] : [function]
        let callFunction: [String: any Sendable] = [
            "name": "line_count", "arguments": ["text": "red\nblue"] as [String: String],
        ]
        let calls: [[String: any Sendable]] = [["function": callFunction]]
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "Use supplied facts."],
            ["role": "user", "content": "Remember alpine-42."],
            ["role": "assistant", "thinking": "Earlier native reasoning", "content": "Stored."],
            ["role": "user", "content": "Count red\nblue."],
            ["role": "assistant", "thinking": "Current tool reasoning", "content": "",
             "tool_calls": calls],
            ["role": "tool", "content": "2"],
        ]
        for required in [false, true] {
            for preserve in [false, true] {
                for addPrompt in [false, true] {
                    var context: [String: any Sendable] = ["preserve_thinking": preserve]
                    if required { context["tool_choice"] = "required"; context["tool_choice_name"] = "line_count" }
                    let actual = try bridge.applyChatTemplate(
                        messages: messages, tools: tools, additionalContext: context,
                        addGenerationPrompt: addPrompt)
                    let expected = try upstream.applyChatTemplate(
                        messages: messages, chatTemplate: nil, addGenerationPrompt: addPrompt,
                        truncation: false, maxLength: nil,
                        tools: [function],
                        additionalContext: context)
                    #expect(actual == expected)
                    let text = tokenizer.decode(tokenIds: actual, skipSpecialTokens: false)
                    #expect(text.contains("Remember alpine-42."))
                    let toolList = try #require(text.components(separatedBy: "List of tools: ").dropFirst().first)
                        .components(separatedBy: "<|im_end|>")[0]
                    let renderedTools = try #require(
                        JSONSerialization.jsonObject(with: Data(toolList.utf8)) as? [[String: Any]])
                    let renderedFunction = try #require(renderedTools.first)
                    #expect(renderedFunction["name"] as? String == "line_count")
                    #expect(renderedFunction["strict"] as? Bool == true)
                    #expect(renderedFunction["function"] == nil)
                    let parameters = try #require(renderedFunction["parameters"] as? [String: Any])
                    #expect(parameters["additionalProperties"] as? Bool == false)
                    let properties = try #require(parameters["properties"] as? [String: Any])
                    let textSchema = try #require(properties["text"] as? [String: Any])
                    #expect(textSchema["type"] as? [String] == ["string", "null"])
                    let optionsSchema = try #require(properties["options"] as? [String: Any])
                    #expect(optionsSchema["additionalProperties"] as? Bool == false)
                    #expect(text.contains("<think>Earlier native reasoning</think>") == preserve)
                    #expect(text.contains("<think>Current tool reasoning</think>"))
                    #expect(text.contains(#"<|tool_call_start|>[line_count(text='red\nblue')]<|tool_call_end|>"#))
                    #expect(text.contains("<|im_start|>tool\n2<|im_end|>\n"))
                    #expect(!text.contains("Tool result for previous assistant tool call:"))
                    #expect(text.hasSuffix("<|im_start|>assistant\n<think>") == addPrompt)
                }
            }
        }
    }

    @Test func toolShapeAdapterRetainsNoncanonicalMetadata() throws {
        let function: ToolSpec = ["name": "f", "strict": true, "parameters": ["type": "object"]]
        let wrapped: ToolSpec = ["type": "function", "function": function]
        let extended: ToolSpec = ["type": "function", "function": function, "x-transport": "keep"]
        let other: ToolSpec = ["type": "custom", "name": "keep"]
        let adapted = try #require(LFM2ToolCallParser.nativeTemplateTools([wrapped, function, extended, other]))
        #expect(adapted[0]["name"] as? String == "f")
        #expect(adapted[0]["strict"] as? Bool == true)
        #expect(adapted[0]["function"] == nil)
        #expect(adapted[1]["name"] as? String == "f")
        #expect(adapted[2]["x-transport"] as? String == "keep")
        #expect(adapted[2]["function"] != nil)
        #expect(adapted[3]["type"] as? String == "custom")
        #expect(LFM2ToolCallParser.nativeTemplateTools(nil) == nil)
    }

    @Test func nativeArgumentValidationDoesNotFallBack() async throws {
        let directory = try fixture(template: Self.nativeTemplate)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: directory)
        let function: [String: any Sendable] = ["name": "line_count", "parameters": ["type": "object"]]
        let messages: [[String: any Sendable]] = [
            ["role": "user", "content": "Count."],
            ["role": "assistant", "content": "", "tool_calls": [
                ["function": ["name": "line_count", "arguments": #"{"text":"red"}"#]]
            ]],
        ]
        #expect(throws: (any Error).self) {
            try tokenizer.applyChatTemplate(
                messages: messages,
                tools: [["type": "function", "function": function]],
                additionalContext: nil)
        }
    }

    @Test func olderNonReasoningFallbackStillApplies() async throws {
        let directory = try fixture(template: "{% for m in messages %}{{ m.content }}{% endfor %}{% if add_generation_prompt %}LEGACY-TAIL{% endif %}")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: directory)
        let function: [String: any Sendable] = ["name": "line_count", "parameters": ["type": "object"]]
        let ids = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "Count lines."]],
            tools: [["type": "function", "function": function]], additionalContext: nil)
        let text = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
        #expect(text.contains("List of tools:"))
        #expect(text.hasSuffix("<|im_start|>assistant\n"))
        #expect(!text.contains("LEGACY-TAIL"))
    }
}
