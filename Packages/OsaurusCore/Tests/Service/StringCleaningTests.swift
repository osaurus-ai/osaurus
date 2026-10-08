import Foundation
import Testing

@testable import OsaurusCore

struct StringCleaningTests {
    @Test(arguments: [
        #"{"name":"no_args","arguments":null}"#, #"{"name":"no_args"}"#,
        #"{"name":"no_args","arguments":"{}"}"#, #"{"name":"nested","arguments":{"payload":{}}}"#,
    ])
    func stripsCompleteInlineToolEnvelope(body: String) {
        let input = "Before\n<tool_call>\(body)</tool_call>\nAfter"
        #expect(StringCleaning.stripLeakedActionJSON(input) == "Before\n\nAfter")
    }

    @Test func preservesOrdinaryXMLAndNameOnlyJSON() {
        for input in [
            #"{"name":"Ada"}"#, "<tool_call>explanation</tool_call>",
            #"<tool_call>{"result":42}</tool_call>"#,
        ] {
            #expect(StringCleaning.stripLeakedActionJSON(input) == input)
        }
    }

    @Test
    func stripGeminiDisplayMetadata_removesGeminiSignatureMarkers() {
        let input = "\u{200B}ts:CiQabcDEF123+/=_\u{200B}Dependencies installed."
        let cleaned = StringCleaning.stripGeminiDisplayMetadata(input)

        #expect(cleaned == "Dependencies installed.")
    }

    @Test
    func stripGeminiDisplayMetadata_removesVisibleLeakedSignatureTokens() {
        let input = "ts:CiQbvj72+49RKk4lfHalZIoEXp8c2HsTTVB9c3ugC9IWty4E1FQKdAG+Pvb7T6Kk0wzT0GD Dependencies installed."
        let cleaned = StringCleaning.stripGeminiDisplayMetadata(input)

        #expect(cleaned == "Dependencies installed.")
    }
    // MARK: - Leaked Harmony channel labels

    /// The bug: Gemma-4 emits `<|channel>thought\n…<channel|>`; when the closing
    /// tag spelling isn't recognised the delimiters go but the label survives
    /// into the user-visible answer. Token ids [100, 45518, 107, 101].
    @Test
    func stripLeakedChannelLabel_removesLabelAsEntireMessage() {
        #expect(StringCleaning.stripLeakedChannelLabel("thought") == "")
        #expect(StringCleaning.stripLeakedChannelLabel("  thought \n") == "")
    }

    @Test
    func stripLeakedChannelLabel_removesLabelLineAheadOfTheAnswer() {
        #expect(StringCleaning.stripLeakedChannelLabel("thought\nThe capital is Paris.") == "The capital is Paris.")
    }

    /// The regression guard that matters for every OTHER model: a reply that
    /// legitimately opens with a heading word must survive untouched. An
    /// earlier draft matched case-insensitively and ate this.
    @Test
    func stripLeakedChannelLabel_leavesCapitalisedHeadingsAlone() {
        let heading = "Analysis\nThe data shows a 12% increase."
        #expect(StringCleaning.stripLeakedChannelLabel(heading) == heading)
        #expect(StringCleaning.stripLeakedChannelLabel("Final") == "Final")
        #expect(StringCleaning.stripLeakedChannelLabel("Thought") == "Thought")
    }

    @Test
    func stripLeakedChannelLabel_leavesOrdinaryProseAlone() {
        let prose = "I thought the answer was 42, but the final tally says otherwise."
        #expect(StringCleaning.stripLeakedChannelLabel(prose) == prose)
        let multiword = "thought experiment"
        #expect(StringCleaning.stripLeakedChannelLabel(multiword) == multiword)
        #expect(StringCleaning.stripLeakedChannelLabel("") == "")
    }

    @Test
    func isHarmonyChannelLabel_isExactAndCaseSensitive() {
        #expect(StringCleaning.isHarmonyChannelLabel("thought"))
        #expect(StringCleaning.isHarmonyChannelLabel("analysis"))
        #expect(!StringCleaning.isHarmonyChannelLabel("Thought"))
        #expect(!StringCleaning.isHarmonyChannelLabel("Paris"))
        #expect(!StringCleaning.isHarmonyChannelLabel("thoughts"))
    }

    // MARK: - stripLeakedActionJSON scan bound (APPLE-MACOS-1FE / 2PF)

    /// The pre-fix algorithm, kept here as the oracle: brace-match and
    /// JSON-parse every `{` once a tool-call key is present anywhere in the
    /// text. The shipped version skips braces that cannot enclose a key; its
    /// output must be byte-identical.
    private static func referenceStrip(_ content: String) -> String {
        guard content.contains("\"action\"") || content.contains("\"arguments\"") else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let chars = Array(content)
        var output: [Character] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "{",
                let end = referenceMatchingBrace(chars, start: i),
                referenceIsLeaked(String(chars[i ... end]))
            {
                i = end + 1
                continue
            }
            output.append(chars[i])
            i += 1
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func referenceMatchingBrace(_ chars: [Character], start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func referenceIsLeaked(_ block: String) -> Bool {
        guard let data = block.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if object["action"] != nil, object["action_input"] != nil || object["action_inputs"] != nil { return true }
        if object["name"] != nil, object["arguments"] != nil || object["parameters"] != nil { return true }
        return false
    }

    private static let leakedCall = #"{"action": "share_artifact", "action_input": {"path": "a.md"}}"#
    private static let leakedOpenAI = #"{"name": "file_read", "arguments": {"path": "b.md"}}"#
    private static let legitJSON = #"{"name": "Ada", "age": 36, "tags": ["x", "{y}"], "meta": {"name": "n"}}"#
    private static let code = """
        func f() { if x { return { "arguments": 1 } } }
        struct S { let name: String }
        """

    @Test(arguments: [
        leakedCall,
        "Intro\n\(leakedCall)\nOutro",
        "Intro\n\(leakedOpenAI)",
        "\(leakedCall)\n\(legitJSON)\n\(code)",
        "\(legitJSON)\n\(code)\n\(leakedOpenAI)",
        "\(code)\n\(legitJSON)",
        "no braces, but \"arguments\" appears in prose",
        "unbalanced { \"action\": \"x\", \"action_input\": {",
        #"escaped key {"\u0061ction": "x", "action_input": {}} tail"#,
        #"quoted brace {"action": "a}b", "action_input": "{"} tail"#,
        "nested legit {\"outer\": \(leakedCall)} then \(leakedCall)",
        "stray = '{';\n\(legitJSON)\n\(code)\n\(leakedCall)",
        "brace in string {\"s\": \"{\", \"name\": \"n\", \"arguments\": {}} { \"name\": \"m\", \"parameters\": [] }",
        "{ \"s\": \"unterminated {\"x\": 1, \"action\": 2, \"action_input\": 3} tail",
        "",
    ])
    func stripLeakedActionJSON_matchesReferenceAlgorithm(input: String) {
        #expect(StringCleaning.stripLeakedActionJSON(input) == Self.referenceStrip(input))
    }

    /// Large brace-heavy answer with a leaked call at the very end: every
    /// `{` before it used to be brace-matched and JSON-parsed. This is the
    /// shape behind the main-thread hangs; it must both stay correct and run
    /// in well under the hang threshold.
    @Test func stripLeakedActionJSON_boundsWorkOnBraceHeavyContent() {
        let block = "{\"id\": 1, \"items\": [{\"k\": {\"v\": [1, 2, {\"w\": 3}]}}]}\n"
        let body = String(repeating: block, count: 1_500)  // ~90 KB, ~9k braces
        let input = body + Self.leakedCall
        let start = ContinuousClock.now
        let output = StringCleaning.stripLeakedActionJSON(input)
        let elapsed = ContinuousClock.now - start
        #expect(output == body.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }

    /// A stray unbalanced brace (`'{'` char literal) used to make every later
    /// `{` re-scan to the end of the text: ~9k braces × 90 KB on the main
    /// thread. The brace-match cache resolves them in one pass.
    @Test func stripLeakedActionJSON_staysLinearWithUnbalancedBrace() {
        let block = "{\"id\": 1, \"items\": [{\"k\": {\"v\": [1, 2, {\"w\": 3}]}}]}\n"
        let body = "const open = '{';\n" + String(repeating: block, count: 1_500)
        let input = body + Self.leakedCall
        let start = ContinuousClock.now
        let output = StringCleaning.stripLeakedActionJSON(input)
        let elapsed = ContinuousClock.now - start
        #expect(output == body.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }

}
