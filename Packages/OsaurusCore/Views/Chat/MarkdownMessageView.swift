//
//  MarkdownMessageView.swift
//  osaurus
//
//  Renders markdown text with proper typography, code blocks, images, and more.
//  Optimized for streaming responses with stable block identity.
//  Uses NSTextView for web-like text selection across blocks.
//

import AppKit
import SwiftUI

struct MarkdownMessageView: View {
    let text: String
    let baseWidth: CGFloat
    /// Optional cache key passed to SelectableTextView for width-aware height caching
    var cacheKey: String? = nil
    /// Whether content is actively streaming - when true, uses lighter rendering for large content
    var isStreaming: Bool = false

    var body: some View {
        // Use inner view with memoized parsing to avoid re-parsing on every render
        MemoizedMarkdownView(text: text, baseWidth: baseWidth, cacheKey: cacheKey, isStreaming: isStreaming)
    }
}

// MARK: - Memoized Inner View

/// Inner view that caches parsed segments and only recomputes when text changes
private struct MemoizedMarkdownView: View {
    let text: String
    let baseWidth: CGFloat
    let cacheKey: String?
    let isStreaming: Bool

    @Environment(\.theme) private var theme

    @State private var cachedSegments: [ContentSegment] = []
    @State private var lastParsedText: String = ""
    @State private var cachedBlocks: [MessageBlock] = []
    @State private var lastStableIndex: Int = 0
    @State private var currentParseTask: Task<Void, Never>?
    @State private var lastParseRequestTime: Date = .distantPast

    init(text: String, baseWidth: CGFloat, cacheKey: String?, isStreaming: Bool) {
        self.text = text
        self.baseWidth = baseWidth
        self.cacheKey = cacheKey
        self.isStreaming = isStreaming

        // Initialize from cache if available synchronously
        if let cached = ThreadCache.shared.markdown(for: text) {
            _cachedSegments = State(initialValue: cached.segments)
            _cachedBlocks = State(initialValue: cached.blocks)
            _lastParsedText = State(initialValue: text)
        }
    }

    // Debounce interval in milliseconds - scales with content size
    // With paragraph-based rendering, each paragraph is smaller so debounce can be shorter
    private var debounceIntervalMs: UInt64 {
        let charCount = text.utf8.count
        switch charCount {
        case 0 ..< 500:
            return 30  // Very small: fast updates
        case 500 ..< 1_000:
            return 50
        case 1_000 ..< 2_000:
            return 80
        case 2_000 ..< 5_000:
            return 120
        default:
            return 200  // Large content: moderate debounce
        }
    }

    /// Cheap fallback text that strips data-URI images to avoid SwiftUI laying out
    /// multi-MB base64 strings while the background parse is in flight.
    private var fallbackText: String {
        guard text.contains("data:image/") else { return text }
        return text.replacingOccurrences(
            of: #"!\[[^\]]*\]\(data:image/[^)]+\)"#,
            with: "![image]",
            options: .regularExpression
        )
    }

    var body: some View {
        Group {
            if cachedSegments.isEmpty && !text.isEmpty {
                Text(fallbackText)
                    .font(Typography.body(baseWidth, theme: theme))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cachedSegments.enumerated()), id: \.element.id) { index, segment in
                        segmentView(for: segment, isFirst: index == 0)
                    }
                }
            }
        }
        .onAppear {
            if lastParsedText != text {
                scheduleBackgroundParse(for: text, oldText: "", debounce: false)
            }
        }
        .onChange(of: text) { oldText, newText in
            if lastParsedText != newText {
                scheduleBackgroundParse(for: newText, oldText: oldText, debounce: true)
            }
        }
        .onChange(of: isStreaming) { _, newValue in
            // When streaming ends, parse synchronously so the segments
            // are up-to-date before the table re-measures row height.
            // Background parsing would race with noteHeightOfRows.
            if !newValue && lastParsedText != text {
                currentParseTask?.cancel()
                currentParseTask = nil
                let blocks = parseBlocks(text)
                let segments = groupBlocksIntoSegments(blocks)
                cachedBlocks = blocks
                cachedSegments = segments
                lastParsedText = text
                lastStableIndex = max(0, blocks.count - 1)
                ThreadCache.shared.setMarkdown(blocks: blocks, segments: segments, for: text)
            }
        }
    }

    /// Schedule parsing on a background thread to avoid blocking the main thread
    /// - Parameters:
    ///   - textToParse: The text to parse
    ///   - oldText: The previous text (for detecting append-only changes)
    ///   - debounce: Whether to apply debouncing delay
    private func scheduleBackgroundParse(for textToParse: String, oldText: String, debounce: Bool) {
        // Cancel any in-flight parsing task
        currentParseTask?.cancel()

        // Capture state for the background task
        let textSnapshot = textToParse
        let debounceMs = debounce ? debounceIntervalMs : 0
        lastParseRequestTime = Date()

        currentParseTask = Task {
            // Apply debounce delay if requested
            if debounceMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceMs * 1_000_000)
                } catch {
                    // Task was cancelled during sleep - exit early
                    return
                }
            }

            // Check if task was cancelled
            if Task.isCancelled { return }

            // Run parsing on a background thread
            // Note: We always do a full parse to avoid the complexity and bugs of incremental parsing.
            // The debouncing and background execution provide sufficient performance improvement.
            let (newBlocks, newSegments) = await Task.detached(priority: .userInitiated) {
                let blocks = parseBlocks(textSnapshot)
                let segments = groupBlocksIntoSegments(blocks)
                return (blocks, segments)
            }.value

            // Check if task was cancelled while parsing
            if Task.isCancelled { return }

            // Update UI state on main thread
            await MainActor.run {
                // Double-check we're still processing the same text
                // (prevents race conditions if text changed while parsing)
                guard textSnapshot == text else { return }

                cachedBlocks = newBlocks
                cachedSegments = newSegments
                lastParsedText = textSnapshot
                lastStableIndex = max(0, newBlocks.count - 1)

                // Update cache
                ThreadCache.shared.setMarkdown(blocks: newBlocks, segments: newSegments, for: textSnapshot)
            }
        }
    }

    @ViewBuilder
    private func segmentView(for segment: ContentSegment, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Add spacing before non-first segments
            if !isFirst {
                Spacer()
                    .frame(height: segment.spacingBefore)
            }

            let segmentCacheKey = cacheKey.map { "\($0)-\(segment.id)" }

            switch segment.kind {
            case .textGroup(let textBlocks):
                SelectableTextView(
                    blocks: textBlocks,
                    baseWidth: baseWidth,
                    theme: theme,
                    cacheKey: segmentCacheKey
                )
                .frame(minWidth: baseWidth, maxWidth: baseWidth, alignment: .leading)

            case .codeBlock(let code, let language):
                CodeBlockView(code: code, language: language, baseWidth: baseWidth)

            case .image(let url, let altText):
                MarkdownImageView(urlString: url, altText: altText, baseWidth: baseWidth)

            case .math(let latex):
                MathBlockView(latex: latex, baseWidth: baseWidth)

            case .table(let headers, let rows):
                MarkdownTableBlockView(headers: headers, rows: rows, baseWidth: baseWidth)
            }
        }
    }
}

// MARK: - Markdown Table (SwiftUI wrapper around NativeMarkdownTableView)

struct MarkdownTableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        MarkdownTableRepresentable(
            headers: headers,
            rows: rows,
            width: baseWidth,
            theme: theme
        )
        .frame(maxWidth: baseWidth, alignment: .leading)
    }
}

private struct MarkdownTableRepresentable: NSViewRepresentable {
    let headers: [String]
    let rows: [[String]]
    let width: CGFloat
    let theme: any ThemeProtocol

    func makeNSView(context: Context) -> NativeMarkdownTableView {
        let v = NativeMarkdownTableView()
        v.configure(headers: headers, rows: rows, width: width, theme: theme)
        return v
    }

    func updateNSView(_ nsView: NativeMarkdownTableView, context: Context) {
        nsView.configure(headers: headers, rows: rows, width: width, theme: theme)
    }
}

// MARK: - Content Segment

/// Represents a segment of content - either a group of selectable text blocks or a standalone image
struct ContentSegment: Identifiable {
    enum Kind {
        case textGroup([SelectableTextBlock])
        case codeBlock(code: String, language: String?)
        case image(url: String, altText: String)
        case math(latex: String)
        case table(headers: [String], rows: [[String]])
    }

    let id: String
    let kind: Kind
    let spacingBefore: CGFloat

    init(id: String, kind: Kind, spacingBefore: CGFloat = 0) {
        self.id = id
        self.kind = kind
        self.spacingBefore = spacingBefore
    }
}

// MARK: - Block Grouping

/// True when a fenced block should render as markdown prose
private func isProseFenceLanguage(_ lang: String?) -> Bool {
    let n = lang?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if n.isEmpty { return true }
    let prose = Set([
        "text", "plain", "plaintext", "markdown", "md", "poem", "poetry", "verse", "prose",
        "output", "ascii", "chat", "letter",
    ])
    return prose.contains(n)
}

/// Groups consecutive text blocks into segments for efficient rendering with NSTextView.
/// Code blocks, images, and math blocks break the text group into separate segments.
/// Horizontal rules and tables are kept inline for continuous selection.
func groupBlocksIntoSegments(_ blocks: [MessageBlock]) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    var currentTextBlocks: [SelectableTextBlock] = []
    var segmentIndex = 0
    func flushTextGroup() {
        if !currentTextBlocks.isEmpty {
            let spacing = segments.isEmpty ? 0 : imageSpacing
            segments.append(
                ContentSegment(
                    id: "text-\(segmentIndex)",
                    kind: .textGroup(currentTextBlocks),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            currentTextBlocks.removeAll()
        }
    }

    func emitBlock(_ block: MessageBlock) {
        switch block.kind {
        case .paragraph(let text):
            currentTextBlocks.append(.paragraph(text))

        case .heading(let level, let text):
            currentTextBlocks.append(.heading(level: level, text: text))

        case .blockquote(let content):
            currentTextBlocks.append(.blockquote(content))

        case .list(let items):
            for item in items {
                currentTextBlocks.append(
                    .listItem(
                        text: item.text,
                        index: item.displayNumber - 1,  // Convert 1-based display number to 0-based index
                        ordered: item.isOrdered,
                        indentLevel: item.indentLevel
                    )
                )
            }

        case .code(let code, let lang):
            if isProseFenceLanguage(lang) {
                let inner = parseBlocks(code)
                for ib in inner {
                    emitBlock(ib)
                }
            } else {
                flushTextGroup()
                let spacing: CGFloat = segments.isEmpty ? 0 : 14
                segments.append(
                    ContentSegment(
                        id: "code-\(segmentIndex)",
                        kind: .codeBlock(code: code, language: lang),
                        spacingBefore: spacing
                    )
                )
                segmentIndex += 1
            }

        case .image(let url, let altText):
            // Images are the only blocks that break text groups (can't be attributed text)
            flushTextGroup()
            // A leading/only image (e.g. a generated-image reply) shouldn't carry
            // top spacing — match the other block kinds and only space it from
            // preceding content.
            let spacing: CGFloat = segments.isEmpty ? 0 : imageSpacing
            segments.append(
                ContentSegment(
                    id: "image-\(segmentIndex)",
                    kind: .image(url: url, altText: altText),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1

        case .horizontalRule:
            // Keep horizontal rules inline in the text group
            currentTextBlocks.append(.horizontalRule)

        case .table(let headers, let rows):
            // Render tables as their own grid segment — inline monospace-padded layout
            // can't wrap multi-line cells without breaking column alignment.
            flushTextGroup()
            let spacing = segments.isEmpty ? 0 : imageSpacing
            segments.append(
                ContentSegment(
                    id: "table-\(segmentIndex)",
                    kind: .table(headers: headers, rows: rows),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1

        case .math(let latex):
            flushTextGroup()
            let spacing = segments.isEmpty ? 0 : imageSpacing
            segments.append(
                ContentSegment(
                    id: "math-\(segmentIndex)",
                    kind: .math(latex: latex),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
        }
    }

    for block in blocks {
        emitBlock(block)
    }

    flushTextGroup()

    return segments
}

/// Spacing between segments (code blocks, images, math, and text groups)
private let imageSpacing: CGFloat = 16

// The Markdown block model (`MessageBlock`, `ListItem`) and `parseBlocks`
// live in Utils/MarkdownBlockParsing.swift, shared with the Agent Channel
// outbound formatters.

// MARK: - Preview

#if DEBUG
    struct MarkdownMessageView_Previews: PreviewProvider {
        static let sampleMarkdown = """
            # Welcome to Osaurus

            Here's a **bold** statement and some *italic* text.

            ## Code Example

            This is a code example:

            ```swift
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            ```

            ---

            ### Lists

            Unordered list:
            - First item
            - Second item
            - Third item

            Ordered list:
            1. Step one
            2. Step two
            3. Step three

            Nested list (ordered with unordered children):
            1. Shang Dynasty (c. 1600–1046 BCE)
              - First historically documented dynasty.
              - Known for bronze vessels and oracle bones.
            2. Zhou Dynasty (1046–256 BCE)
              - Founded by King Wu.
              - Introduced the "Mandate of Heaven".

            Loose ordered list (with blank lines):

            1. First item

            2. Second item

            3. Third item

            > This is a blockquote with some important information
            > that spans multiple lines.

            ### Table Example

            | Name | Age | City |
            | --- | --- | --- |
            | Alice | 30 | New York |
            | Bob | 25 | San Francisco |
            | Charlie | 35 | Chicago |

            Here's an image:

            ![Cat Image](https://placekitten.com/400/300)

            And that's all folks!
            """

        static var previews: some View {
            ScrollView {
                MarkdownMessageView(text: sampleMarkdown, baseWidth: 600)
                    .padding()
                    .frame(width: 600, alignment: .leading)
            }
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
