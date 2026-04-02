//
//  MockChatData.swift
//  osaurus
//
//  Debug-only synthetic chat turns for NSTableView / native cell performance testing
//  (same idea as USE_MOCK_MODELS in ModelPickerView).
//
//  Environment (scheme → Run → Arguments → Environment Variables):
//  - USE_MOCK_CHAT_DATA=1 — enable mock thread
//  - USE_MOCK_CHAT_PAIR_COUNT — optional; default 500 user+assistant exchanges (1000 ChatTurns).
//    Total ContentBlock rows are higher (group spacers + assistant headers); ~5× pair count.
//  - USE_MOCK_CHAT_SEED — optional UInt64 for reproducible random lengths (default 0xC0FFEE42)
//
//  Assistant turns cycle through variants: markdown (code fences, lists), thinking blocks,
//  tool call groups (with/without results), preflight capability rows, share_artifact cards, etc.
//

#if DEBUG
    import Foundation

    @MainActor
    enum MockChatData {
        /// set USE_MOCK_CHAT_DATA=1 in Xcode scheme to render a large synthetic thread
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["USE_MOCK_CHAT_DATA"] == "1"
        }

        /// number of user–assistant exchanges (default 500 → ~1000 turns, ~2500 content blocks with spacers/headers).
        static var pairCount: Int {
            let raw =
                ProcessInfo.processInfo.environment["USE_MOCK_CHAT_PAIR_COUNT"]?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
            if let n = Int(raw), n > 0 { return n }
            return 500
        }

        private static var cachedTurns: [ChatTurn]?

        /// stable for the process lifetime so BlockMemoizer fast paths behave like a fixed conversation
        static func mockTurnsForPerformanceTest() -> [ChatTurn] {
            if let cached = cachedTurns { return cached }
            let turns = generateTurns(pairCount: pairCount)
            cachedTurns = turns
            return turns
        }

        private static func generateTurns(pairCount: Int) -> [ChatTurn] {
            var rng = SplitMix64(seed: seedUInt64)
            let lorem =
                "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Pellentesque habitant morbi tristique senectus et netus. "
            var turns: [ChatTurn] = []
            turns.reserveCapacity(pairCount * 2)
            for pairIndex in 0 ..< pairCount {
                let userLen = Int.random(in: 12 ... 900, using: &rng)
                let userText = randomString(length: userLen, template: lorem, rng: &rng)
                turns.append(ChatTurn(role: .user, content: userText))

                turns.append(makeAssistantTurn(pairIndex: pairIndex, rng: &rng))
            }
            return turns
        }

        private static let assistantVariantCount = 12

        /// Cycles assistant shapes so `ContentBlock.generateBlocks` hits paragraphs (markdown/code),
        /// thinking, tool groups, preflight rows, share_artifact, and pending-style tool rows.
        private static func makeAssistantTurn(pairIndex: Int, rng: inout SplitMix64) -> ChatTurn {
            let turn = ChatTurn(role: .assistant, content: "")
            let v = pairIndex % assistantVariantCount

            switch v {
            case 0:
                // markdown: headings, lists, fenced swift/json/bash (native markdown + code path)
                turn.content =
                    markdownRichStatic
                    + "\n\n"
                    + markdownExtraNoise(length: Int.random(in: 80 ... 2200, using: &rng), rng: &rng)

            case 1:
                // thinking block + follow-up text
                turn.thinking = thinkingBody(rng: &rng)
                turn.content = "### answer\n\n" + shortMarkdownParagraph(rng: &rng)

            case 2:
                // single tool + result + wrap-up text
                let id = "mock_\(pairIndex)_read"
                turn.toolCalls = [
                    ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(
                            name: "read_file",
                            arguments: "{\"path\": \"/mock/Sources/App.swift\", \"limit\": 400}"
                        )
                    )
                ]
                turn.toolResults[id] =
                    "import SwiftUI\n\n@main\nstruct MockApp: App {\n    var body: some Scene {\n        WindowGroup { Text(\"hi\") }\n    }\n}\n"
                turn.content = "I inspected the file. Summary:\n\n- Uses `@main`\n- Single window group\n"

            case 3:
                // two tools in one group
                let idA = "mock_\(pairIndex)_a"
                let idB = "mock_\(pairIndex)_b"
                turn.toolCalls = [
                    ToolCall(
                        id: idA,
                        type: "function",
                        function: ToolCallFunction(
                            name: "grep",
                            arguments: "{\"pattern\": \"func\", \"path\": \"/mock\"}"
                        )
                    ),
                    ToolCall(
                        id: idB,
                        type: "function",
                        function: ToolCallFunction(name: "list_dir", arguments: "{\"path\": \"/mock/Sources\"}")
                    ),
                ]
                turn.toolResults[idA] =
                    "/mock/Sources/App.swift:3:func main()\n/mock/Sources/Util.swift:1:func helper()\n"
                turn.toolResults[idB] = "App.swift\nUtil.swift\nPackage.swift\n"
                turn.content = "Cross-checked grep and directory listing."

            case 4:
                // tool row with no result yet (in-flight affordance)
                let id = "mock_\(pairIndex)_run"
                turn.toolCalls = [
                    ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(
                            name: "run_command",
                            arguments: "{\"command\": \"xcodebuild -scheme osaurus test\"}"
                        )
                    )
                ]
                turn.content = "Kicking off a long build; result still streaming in real life — here we leave it nil."

            case 5:
                // preflight capability strip + answer
                turn.preflightCapabilities = [
                    PreflightCapabilityItem(
                        type: .method,
                        name: "workspace_index",
                        description: "Semantic index over the repo root."
                    ),
                    PreflightCapabilityItem(
                        type: .tool,
                        name: "read_file",
                        description: "Read UTF-8 text from a path."
                    ),
                    PreflightCapabilityItem(
                        type: .skill,
                        name: "swiftui_layout",
                        description: "Layout patterns for macOS chat UI."
                    ),
                ]
                turn.content =
                    "Preflight loaded the above capabilities; answering with a short plan.\n\n1. profile\n2. fix hotspots\n"

            case 6:
                // share_artifact enriched result (card UI) + short reply
                let artId = "mock_\(pairIndex)_art"
                turn.toolCalls = [
                    ToolCall(
                        id: artId,
                        type: "function",
                        function: ToolCallFunction(name: "share_artifact", arguments: "{\"filename\":\"notes.md\"}")
                    )
                ]
                turn.toolResults[artId] = mockEnrichedShareArtifactToolResult(
                    filename: "notes-\(pairIndex).md",
                    body: "# export\n\n- item A\n- item B\n\n```swift\nlet x = 1\n```\n"
                )
                turn.content = "Shared a markdown artifact you can open from the card above."

            case 7:
                // thinking + tools + prose (common assistant shape)
                turn.thinking = "plan: read manifest, then list packages.\n"
                let id = "mock_\(pairIndex)_pkg"
                turn.toolCalls = [
                    ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(name: "read_file", arguments: "{\"path\": \"/mock/Package.swift\"}")
                    )
                ]
                turn.toolResults[id] = "// swift-tools-version: 6.2\nimport PackageDescription\n"
                turn.content =
                    "Package manifest uses Swift 6.2; dependencies declared below.\n\n```swift\nlet package = Package(\n    name: \"OsaurusCore\"\n)\n```\n"

            case 8:
                // heavy fenced code (scroll / measure layout)
                turn.content = longFencedCodeSample(rng: &rng)

            case 9:
                // tools only, empty assistant text (no paragraph block)
                let id = "mock_\(pairIndex)_onlytools"
                turn.toolCalls = [
                    ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(
                            name: "web_search",
                            arguments: "{\"query\": \"NSTableView diffable data source\"}"
                        )
                    )
                ]
                turn.toolResults[id] =
                    "result snippet: Apple docs recommend NSDiffableDataSourceSnapshot for large threads.\n"
                turn.content = ""

            case 10:
                // preflight + thinking + markdown
                turn.preflightCapabilities = [
                    PreflightCapabilityItem(type: .tool, name: "bash", description: "Run shell commands in sandbox.")
                ]
                turn.thinking = "User asked about GPU; checking thermal notes.\n"
                turn.content =
                    "> quote: keep frame time under 16ms.\n\n| metric | target |\n| --- | --- |\n| fps | 60 |\n"

            default:
                // share_artifact then ordinary tool (ordering / split blocks)
                let shareId = "mock_\(pairIndex)_sh"
                let readId = "mock_\(pairIndex)_rd"
                turn.toolCalls = [
                    ToolCall(
                        id: shareId,
                        type: "function",
                        function: ToolCallFunction(name: "share_artifact", arguments: "{}")
                    ),
                    ToolCall(
                        id: readId,
                        type: "function",
                        function: ToolCallFunction(name: "read_file", arguments: "{\"path\": \"/mock/README.md\"}")
                    ),
                ]
                turn.toolResults[shareId] = mockEnrichedShareArtifactToolResult(
                    filename: "bundle-\(pairIndex).md",
                    body: "# diagram\n\nplaceholder content for the card.\n"
                )
                turn.toolResults[readId] = "# title\n\nbody\n"
                turn.content = "Artifact plus file read in one turn."
            }

            return turn
        }

        private static let markdownRichStatic = """
            ## analysis

            Bullets exercise list rendering:

            - first
            - second with **bold** and `inline code`

            ```swift
            struct Row: Identifiable {
                let id: String
                var height: CGFloat
            }
            ```

            ```json
            { "cells": 1000, "reuse": true, "platform": "macOS" }
            ```

            ```bash
            xcodebuild -scheme osaurus -destination 'platform=macOS' build 2>&1 | tail -n 20
            ```
            """

        private static func markdownExtraNoise(length: Int, rng: inout SplitMix64) -> String {
            let unit = "More prose and `ticks` and [link](https://example.com) patterns.\n\n"
            return randomString(length: length, template: unit, rng: &rng)
        }

        private static func shortMarkdownParagraph(rng: inout SplitMix64) -> String {
            randomString(length: Int.random(in: 120 ... 600, using: &rng), template: "word ", rng: &rng)
        }

        private static func thinkingBody(rng: inout SplitMix64) -> String {
            let base =
                "Reasoning trace: consider scroll anchoring, diffable snapshots, and height cache coalescing.\n\n"
            return base + randomString(length: Int.random(in: 200 ... 1800, using: &rng), template: "note ", rng: &rng)
        }

        private static func longFencedCodeSample(rng: inout SplitMix64) -> String {
            var body = "### generated sample\n\n"
            let reps = Int.random(in: 3 ... 12, using: &rng)
            for i in 0 ..< reps {
                body += """
                    ```swift
                    func block_\(i)() {
                        let table = NSTableView()
                        table.usesAutomaticRowHeights = false
                        table.rowHeight = CGFloat(\(40 + i * 3))
                    }
                    ```

                    """
            }
            body += randomString(length: Int.random(in: 400 ... 2500, using: &rng), template: "padding ", rng: &rng)
            return body
        }

        /// Marker-delimited result compatible with `SharedArtifact.fromEnrichedToolResult`.
        private static func mockEnrichedShareArtifactToolResult(filename: String, body: String) -> String {
            let metadata: [String: Any] = [
                "filename": filename,
                "mime_type": SharedArtifact.mimeType(from: filename),
                "has_content": true,
                "description": "mock shared artifact for performance UI",
                "host_path": "/tmp/osaurus-mock/\(filename)",
                "context_id": "mock-chat-context",
                "context_type": ArtifactContextType.chat.rawValue,
                "file_size": body.utf8.count,
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: metadata),
                let jsonLine = String(data: jsonData, encoding: .utf8)
            else {
                let fallback =
                    "{\"filename\":\"fallback.txt\",\"mime_type\":\"text/plain\",\"has_content\":true,\"description\":\"mock\",\"host_path\":\"/tmp/osaurus-mock/fallback.txt\",\"context_id\":\"mock-chat-context\",\"context_type\":\"chat\",\"file_size\":0}"
                return SharedArtifact.startMarker + fallback + SharedArtifact.endMarker
            }
            if body.isEmpty {
                return SharedArtifact.startMarker + jsonLine + SharedArtifact.endMarker
            }
            return SharedArtifact.startMarker + jsonLine + "\n" + body + SharedArtifact.endMarker
        }

        private static var seedUInt64: UInt64 {
            let raw =
                ProcessInfo.processInfo.environment["USE_MOCK_CHAT_SEED"]?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
            if let s = UInt64(raw) { return s }
            return 0xC0FFEE42
        }

        private static func randomString(length: Int, template: String, rng: inout SplitMix64) -> String {
            guard length > 0 else { return "" }
            var result = ""
            result.reserveCapacity(length)
            while result.count < length {
                result.append(template)
            }
            if result.count > length {
                result = String(result.prefix(length))
            }
            return result
        }
    }

    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
#else
    @MainActor
    enum MockChatData {
        static var isEnabled: Bool { false }
        static var pairCount: Int { 0 }
        static func mockTurnsForPerformanceTest() -> [ChatTurn] { [] }
    }
#endif
