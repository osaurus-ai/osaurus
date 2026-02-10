//
//  InlineToolCallView.swift
//  osaurus
//
//  Compact inline view for tool calls - shows tool name, arg preview, and status.
//  Expandable to reveal full arguments and result.
//

import AppKit
import SwiftUI

// MARK: - Layout Constants

private enum ToolCallLayout {
    static let rowVerticalPadding: CGFloat = 14
    static let rowTrailingPadding: CGFloat = 16
    static let rowLeadingPadding: CGFloat = 12
    static let rowLeadingPaddingWithStrip: CGFloat = 14
    static let expandedContentPadding: CGFloat = 12
}

// MARK: - JSON Formatting Utility

/// Formats JSON on a background thread to avoid blocking UI
private enum JSONFormatter {
    static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data)
        else { return raw }

        // Return compact string for empty objects
        if let dict = obj as? [String: Any], dict.isEmpty {
            return "{}"
        }

        guard let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else {
            return raw
        }
        return String(data: pretty, encoding: .utf8) ?? raw
    }
}

// MARK: - Tool Category

/// Tool categories for icon selection
private enum ToolCategory {
    case file
    case search
    case terminal
    case network
    case database
    case code
    case general

    var icon: String {
        switch self {
        case .file: return "folder.fill"
        case .search: return "magnifyingglass"
        case .terminal: return "terminal.fill"
        case .network: return "globe"
        case .database: return "cylinder.split.1x2.fill"
        case .code: return "curlybraces"
        case .general: return "gearshape.fill"
        }
    }

    var gradient: [Color] {
        switch self {
        case .file: return [Color(hex: "f59e0b"), Color(hex: "d97706")]
        case .search: return [Color(hex: "8b5cf6"), Color(hex: "7c3aed")]
        case .terminal: return [Color(hex: "10b981"), Color(hex: "059669")]
        case .network: return [Color(hex: "3b82f6"), Color(hex: "2563eb")]
        case .database: return [Color(hex: "ec4899"), Color(hex: "db2777")]
        case .code: return [Color(hex: "06b6d4"), Color(hex: "0891b2")]
        case .general: return [Color(hex: "6b7280"), Color(hex: "4b5563")]
        }
    }

    static func from(toolName: String) -> ToolCategory {
        let name = toolName.lowercased()

        // File operations
        if name.contains("file") || name.contains("read") || name.contains("write")
            || name.contains("path") || name.contains("directory") || name.contains("folder")
        {
            return .file
        }

        // Search operations
        if name.contains("search") || name.contains("find") || name.contains("query")
            || name.contains("grep") || name.contains("lookup")
        {
            return .search
        }

        // Terminal/command operations
        if name.contains("terminal") || name.contains("command") || name.contains("exec")
            || name.contains("shell") || name.contains("run") || name.contains("bash")
        {
            return .terminal
        }

        // Network operations
        if name.contains("http") || name.contains("api") || name.contains("fetch")
            || name.contains("request") || name.contains("url") || name.contains("web")
        {
            return .network
        }

        // Database operations
        if name.contains("database") || name.contains("sql") || name.contains("db")
            || name.contains("query") || name.contains("table")
        {
            return .database
        }

        // Code operations
        if name.contains("code") || name.contains("edit") || name.contains("replace")
            || name.contains("refactor") || name.contains("lint")
        {
            return .code
        }

        return .general
    }
}

// MARK: - Preview Generator

/// Generates human-readable previews for JSON and text content
private enum PreviewGenerator {
    /// Generate a preview for JSON arguments (object)
    static func jsonPreview(_ jsonString: String, maxLength: Int = 60) -> String? {
        guard let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !json.isEmpty
        else { return nil }

        var parts: [String] = []
        var totalLength = 0

        // Priority keys for preview
        let priorityKeys = ["path", "file", "file_path", "query", "url", "name", "command", "pattern", "content"]

        // Build preview string
        for key in priorityKeys {
            if let value = json[key] {
                let valueStr = formatValue(value)
                let part = "\(key): \(valueStr)"
                if totalLength + part.count > maxLength && !parts.isEmpty {
                    break
                }
                parts.append(part)
                totalLength += part.count + 2
            }
        }

        // If no priority keys found, use first few keys (sorted for stable ordering)
        if parts.isEmpty {
            for key in json.keys.sorted().prefix(3) {
                guard let value = json[key] else { continue }
                let valueStr = formatValue(value)
                let part = "\(key): \(valueStr)"
                if totalLength + part.count > maxLength && !parts.isEmpty {
                    break
                }
                parts.append(part)
                totalLength += part.count + 2
            }
        }

        // Add count if more parameters exist
        let remaining = json.count - parts.count
        if remaining > 0 {
            parts.append("+\(remaining) more")
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Generate a preview for result content (handles JSON arrays, objects, and plain text)
    static func resultPreview(_ text: String, maxLength: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse as JSON first
        if let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        {

            // Handle JSON array
            if let array = json as? [Any] {
                if array.isEmpty {
                    return "Empty array []"
                }
                // Describe array contents
                let itemDescriptions = array.prefix(3).map { formatValue($0) }
                let preview = itemDescriptions.joined(separator: ", ")
                let suffix = array.count > 3 ? " +\(array.count - 3) more" : ""
                let result = "[\(array.count) items] \(preview)\(suffix)"
                if result.count > maxLength {
                    return String(result.prefix(maxLength - 3)) + "..."
                }
                return result
            }

            // Handle JSON object
            if let dict = json as? [String: Any] {
                if dict.isEmpty {
                    return "Empty object {}"
                }
                // Use jsonPreview for objects
                if let preview = jsonPreview(trimmed, maxLength: maxLength) {
                    return preview
                }
                return "{\(dict.count) keys}"
            }
        }

        // Plain text - get first meaningful line
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let firstLine = lines.first else {
            return trimmed.isEmpty ? "Empty response" : trimmed
        }

        if firstLine.count <= maxLength {
            if lines.count > 1 {
                return "\(firstLine) (+\(lines.count - 1) lines)"
            }
            return firstLine
        }

        return String(firstLine.prefix(maxLength - 3)) + "..."
    }

    /// Format size for display
    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    /// Count lines in text
    static func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    private static func formatValue(_ value: Any) -> String {
        switch value {
        case let str as String:
            let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if clean.count > 30 {
                return String(clean.prefix(27)) + "..."
            }
            return clean
        case let num as NSNumber:
            return num.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let arr as [Any]:
            return "[\(arr.count) items]"
        case let dict as [String: Any]:
            // Try to get a meaningful preview from the dict
            if let name = dict["title"] as? String ?? dict["name"] as? String {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count > 25 {
                    return String(clean.prefix(22)) + "..."
                }
                return clean
            }
            return "{\(dict.count) keys}"
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Pulsing Dot Animation

/// Animated pulsing dot for in-progress state
private struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 16, height: 16)
                .scaleEffect(isPulsing ? 1.4 : 1.0)
                .opacity(isPulsing ? 0 : 0.6)

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Inline Tool Call View (Compact Row)

/// Compact inline view for a single tool call - shows tool name, arg preview, and status.
/// Expandable to reveal full arguments and result.
struct InlineToolCallView: View {
    let call: ToolCall
    let result: String?
    var showAccentStrip = false

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var formattedArgs: String?
    @Environment(\.theme) private var theme

    private var isComplete: Bool {
        result != nil
    }

    private var isRejected: Bool {
        result?.hasPrefix("[REJECTED]") == true
    }

    private var category: ToolCategory {
        ToolCategory.from(toolName: call.function.name)
    }

    /// Extract a key argument preview from the JSON arguments
    private var argPreview: String? {
        PreviewGenerator.jsonPreview(call.function.arguments, maxLength: 80)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact header row
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 10) {
                    // Status icon
                    statusIcon

                    // Category icon with gradient background
                    categoryIcon

                    // Tool name
                    Text(call.function.name)
                        .font(theme.monoFont(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    // Arg preview
                    if let preview = argPreview {
                        Text(preview)
                            .font(theme.font(size: 11, weight: .regular))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()

                    // Expand chevron with smooth rotation
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText.opacity(isHovered ? 1.0 : 0.7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
                        .animation(.easeOut(duration: 0.15), value: isHovered)
                }
                .padding(
                    .leading,
                    showAccentStrip ? ToolCallLayout.rowLeadingPaddingWithStrip : ToolCallLayout.rowLeadingPadding
                )
                .padding(.trailing, ToolCallLayout.rowTrailingPadding)
                .padding(.vertical, ToolCallLayout.rowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content with animation
            if isExpanded {
                expandedContent
                    .padding(
                        .leading,
                        showAccentStrip ? ToolCallLayout.rowLeadingPaddingWithStrip : ToolCallLayout.rowLeadingPadding
                    )
                    .padding(.trailing, ToolCallLayout.expandedContentPadding)
                    .padding(.bottom, ToolCallLayout.expandedContentPadding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Accent strip on left edge (when not in grouped container)
        .overlay(alignment: .leading) {
            if showAccentStrip {
                Rectangle()
                    .fill(statusColor)
                    .frame(width: 3)
            }
        }
        // Subtle hover glow
        .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.accentColor.opacity(isHovered ? 0.05 : 0))
                .animation(.easeOut(duration: 0.2), value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && formattedArgs == nil {
                let rawArgs = call.function.arguments
                Task.detached(priority: .userInitiated) {
                    let formatted = JSONFormatter.prettyJSON(rawArgs)
                    await MainActor.run { formattedArgs = formatted }
                }
            }
        }
        .id(call.id)
    }

    private var statusColor: Color {
        if !isComplete {
            return theme.accentColor
        } else if isRejected {
            return theme.errorColor
        } else {
            return theme.successColor
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if !isComplete {
            PulsingDot(color: theme.accentColor)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: isRejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusIconGradient)
        }
    }

    private var statusIconGradient: LinearGradient {
        let color = isRejected ? theme.errorColor : theme.successColor
        return LinearGradient(
            colors: [color, color.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var categoryIcon: some View {
        Image(systemName: category.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: category.gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Arguments - hide if empty or "{}"
            let currentArgs = formattedArgs ?? call.function.arguments
            let isArgsEmpty =
                currentArgs.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
                || currentArgs.isEmpty

            if !isArgsEmpty {
                CollapsibleCodeSection(
                    title: "Arguments",
                    text: currentArgs,
                    language: "json",
                    previewText: PreviewGenerator.jsonPreview(call.function.arguments, maxLength: 80),
                    sectionId: "\(call.id)-args"
                )
            }

            // Result (if complete)
            if let result {
                CollapsibleCodeSection(
                    title: "Result",
                    text: result,
                    language: nil,
                    previewText: PreviewGenerator.resultPreview(result, maxLength: 80),
                    sectionId: "\(call.id)-result"
                )
            }
        }
    }
}

// MARK: - Collapsible Code Section

/// A collapsible section for displaying code/text content with a preview
struct CollapsibleCodeSection: View {
    let title: String
    let text: String
    let language: String?
    let previewText: String?
    let sectionId: String

    // Max height for expanded content
    private static let maxContentHeight: CGFloat = 200

    @State private var isCollapsed = true
    @State private var isHovered = false
    @State private var isCopied = false
    @State private var preparedContent: PreparedContent?
    @State private var isLoading = false
    @Environment(\.theme) private var theme

    init(title: String, text: String, language: String?, previewText: String?, sectionId: String = UUID().uuidString) {
        self.title = title
        self.text = text
        self.language = language
        self.previewText = previewText
        self.sectionId = sectionId
    }

    private var sizeInfo: String {
        let bytes = text.count
        let lines = PreviewGenerator.lineCount(text)
        return "\(PreviewGenerator.formatSize(bytes)), \(lines) line\(lines == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always visible
            Button(action: toggleCollapse) {
                HStack(spacing: 8) {
                    // Expand/collapse chevron
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)

                    // Language/type icon
                    if let language {
                        Image(systemName: languageIcon(for: language))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                    }

                    // Title
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.8)

                    // Size info
                    Text("(\(sizeInfo))")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(theme.tertiaryText.opacity(0.6))

                    Spacer()

                    // Copy button
                    Button(action: copyToClipboard) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .medium))
                                .contentTransition(.symbolEffect(.replace))

                            if isCopied {
                                Text("Copied!")
                                    .font(.system(size: 9, weight: .medium))
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                            }
                        }
                        .foregroundColor(isCopied ? theme.successColor : theme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isCopied ? theme.successColor.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || isCopied ? 1 : 0.6)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Preview row (when collapsed)
            if isCollapsed, let preview = previewText, !preview.isEmpty {
                HStack(spacing: 0) {
                    Text(preview)
                        .font(theme.monoFont(size: 11, weight: .regular))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)

                    Spacer(minLength: 0)
                }
            }

            // Expanded content
            if !isCollapsed {
                codeContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.codeBlockBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    theme.primaryBorder.opacity(isHovered ? 0.25 : 0.15),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .id(sectionId)
    }

    private func toggleCollapse() {
        isCollapsed.toggle()
        // Prepare content when expanding
        if !isCollapsed && preparedContent == nil {
            prepareContent()
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        if let content = preparedContent {
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    // Line numbers
                    if content.displayText.contains("\n") {
                        lineNumbers(count: content.lineCount)
                    }

                    Text(content.displayText)
                        .font(theme.monoFont(size: CGFloat(theme.codeSize) - 2, weight: .regular))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: Self.maxContentHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.codeBlockBackground)
        } else if isLoading {
            loadingView
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(height: 20)
                .onAppear { prepareContent() }
        }
    }

    private func lineNumbers(count: Int) -> some View {
        let lineNumbersText = (1 ... count).map { String($0) }.joined(separator: "\n")

        return Text(lineNumbersText)
            .font(theme.monoFont(size: CGFloat(theme.codeSize) - 3, weight: .regular))
            .foregroundColor(theme.tertiaryText.opacity(0.4))
            .lineSpacing(0)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 10)
            .background(
                Rectangle()
                    .fill(theme.codeBlockBackground.opacity(0.3))
            )
            .overlay(
                Rectangle()
                    .fill(theme.primaryBorder.opacity(0.1))
                    .frame(width: 1),
                alignment: .trailing
            )
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0 ..< 3, id: \.self) { index in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.tertiaryText.opacity(0.06))
                        .frame(width: 16, height: 12)
                        .padding(.trailing, 12)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.tertiaryText.opacity(0.06))
                        .frame(width: shimmerWidth(for: index), height: 12)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBlockBackground)
    }

    private func shimmerWidth(for index: Int) -> CGFloat {
        switch index {
        case 0: return 180
        case 1: return 240
        case 2: return 140
        default: return 160
        }
    }

    private func languageIcon(for lang: String) -> String {
        switch lang.lowercased() {
        case "json": return "curlybraces"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    private func prepareContent() {
        let sourceText = text
        let maxChars = 50_000
        let maxLines = 500

        if sourceText.count < 1000 {
            let content = prepareDisplayContent(
                from: sourceText,
                truncate: true,
                maxChars: maxChars,
                maxLines: maxLines
            )
            preparedContent = content
            isLoading = false
            return
        }

        isLoading = true
        Task {
            let content = await Task.detached(priority: .userInitiated) {
                prepareDisplayContent(
                    from: sourceText,
                    truncate: true,
                    maxChars: maxChars,
                    maxLines: maxLines
                )
            }.value

            try? await Task.sleep(nanoseconds: 100_000_000)

            await MainActor.run {
                preparedContent = content
                isLoading = false
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation(theme.springAnimation()) {
            isCopied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(theme.animationQuick()) {
                isCopied = false
            }
        }
    }
}

// MARK: - Prepared Content

private struct PreparedContent: Equatable {
    let displayText: String
    let lineCount: Int
    let totalLineCount: Int
    let totalSize: Int
    let isTruncated: Bool
}

// MARK: - Content Preparation (Off Main Thread)

private func prepareDisplayContent(
    from text: String,
    truncate: Bool,
    maxChars: Int,
    maxLines: Int
) -> PreparedContent {
    var totalLineCount = 1
    for char in text {
        if char == "\n" { totalLineCount += 1 }
    }

    let totalSize = text.count
    let needsTruncation = truncate && (text.count > maxChars || totalLineCount > maxLines)

    let displayText: String
    let displayLineCount: Int

    if !needsTruncation {
        displayText = text
        displayLineCount = totalLineCount
    } else if text.count > maxChars {
        let truncated = String(text.prefix(maxChars))
        if let lastNewline = truncated.lastIndex(of: "\n") {
            displayText = String(truncated[..<lastNewline])
        } else {
            displayText = truncated
        }
        displayLineCount = displayText.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    } else {
        var count = 0
        var endIndex = text.startIndex
        for (idx, char) in text.enumerated() {
            if char == "\n" {
                count += 1
                if count >= maxLines {
                    endIndex = text.index(text.startIndex, offsetBy: idx)
                    break
                }
            }
        }
        displayText = String(text[..<endIndex])
        displayLineCount = maxLines
    }

    return PreparedContent(
        displayText: displayText,
        lineCount: displayLineCount,
        totalLineCount: totalLineCount,
        totalSize: totalSize,
        isTruncated: needsTruncation
    )
}

// MARK: - Grouped Tool Calls Container View

/// Renders multiple tool calls in a single grouped container with animated borders
struct GroupedToolCallsContainerView: View {
    let calls: [ToolCallItem]

    @Environment(\.theme) private var theme
    @State private var gradientRotation: Double = 0
    @State private var showCompletionGlow = false
    @State private var wasInProgress = false

    /// Check if any tool call is still in progress
    private var hasInProgressCall: Bool {
        calls.contains { $0.result == nil }
    }

    /// Check if any tool call was rejected
    private var hasRejectedCall: Bool {
        calls.contains { $0.result?.hasPrefix("[REJECTED]") == true }
    }

    /// Status color for accent strip
    private var statusColor: Color {
        if hasInProgressCall {
            return theme.accentColor
        } else if hasRejectedCall {
            return theme.errorColor
        } else {
            return theme.successColor
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Accent strip on left edge
            accentStrip

            // Tool calls content
            VStack(spacing: 0) {
                ForEach(Array(calls.enumerated()), id: \.element.call.id) { index, item in
                    InlineToolCallView(
                        call: item.call,
                        result: item.result,
                        showAccentStrip: false
                    )

                    // Divider between tool calls (not after last)
                    if index < calls.count - 1 {
                        Divider()
                            .background(theme.primaryBorder.opacity(0.3))
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
        // Border: colored based on status
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    statusColor.opacity(showCompletionGlow ? 0.5 : 0.25),
                    lineWidth: showCompletionGlow ? 1.5 : 1
                )
                .animation(.easeOut(duration: 0.8), value: showCompletionGlow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Glow effect on completion
        .shadow(
            color: showCompletionGlow ? statusColor.opacity(0.2) : .clear,
            radius: 8,
            x: 0,
            y: 2
        )
        .animation(.easeOut(duration: 0.8), value: showCompletionGlow)
        .onAppear {
            wasInProgress = hasInProgressCall
            if hasInProgressCall {
                startShimmerAnimation()
            }
        }
        .onChange(of: hasInProgressCall) { oldValue, inProgress in
            if inProgress {
                wasInProgress = true
                startShimmerAnimation()
            } else if wasInProgress {
                // Just completed - show completion glow then fade
                showCompletionGlow = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.8)) {
                        showCompletionGlow = false
                    }
                }
            }
        }
    }

    // MARK: - Accent Strip

    @ViewBuilder
    private var accentStrip: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 10, bottomLeading: 10),
            style: .continuous
        )
        .fill(hasInProgressCall ? AnyShapeStyle(shimmerGradient) : AnyShapeStyle(statusColor))
        .frame(width: 4)
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: statusColor.opacity(0.5), location: 0),
                .init(color: statusColor, location: 0.3),
                .init(color: statusColor.opacity(0.8), location: 0.5),
                .init(color: statusColor, location: 0.7),
                .init(color: statusColor.opacity(0.5), location: 1.0),
            ],
            startPoint: UnitPoint(x: 0, y: gradientRotation / 360 - 0.5),
            endPoint: UnitPoint(x: 0, y: gradientRotation / 360 + 0.5)
        )
    }

    private func startShimmerAnimation() {
        gradientRotation = 0
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            gradientRotation = 360
        }
    }

}

// MARK: - Preview

#if DEBUG
    struct ToolCallView_Previews: PreviewProvider {
        static var previews: some View {
            let toolCalls: [ToolCallItem] = [
                ToolCallItem(
                    call: ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(
                            name: "read_file",
                            arguments: "{\"path\": \"/Users/example/src/main.swift\"}"
                        )
                    ),
                    result: "import Foundation\n\nfunc main() {\n    print(\"Hello!\")\n}"
                ),
                ToolCallItem(
                    call: ToolCall(
                        id: "call_2",
                        type: "function",
                        function: ToolCallFunction(
                            name: "search_web",
                            arguments: "{\"query\": \"Swift best practices\", \"limit\": 10}"
                        )
                    ),
                    result: "Found 10 results for 'Swift best practices'"
                ),
                ToolCallItem(
                    call: ToolCall(
                        id: "call_3",
                        type: "function",
                        function: ToolCallFunction(
                            name: "run_command",
                            arguments: "{\"command\": \"npm install\"}"
                        )
                    ),
                    result: nil  // In progress
                ),
            ]

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Grouped Tool Calls")
                        .font(.headline)
                        .foregroundColor(.white)

                    GroupedToolCallsContainerView(calls: toolCalls)

                    Text("Single Tool Call")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.top, 8)

                    GroupedToolCallsContainerView(calls: [toolCalls[0]])
                }
                .padding()
            }
            .frame(width: 600, height: 600)
            .background(Color(hex: "0c0c0b"))
        }
    }
#endif
