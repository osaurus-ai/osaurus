//
//  NativeToolCallGroupView.swift
//  osaurus
//
//  Pure AppKit replacement for GroupedToolCallsContainerView + InlineToolCallView.
//  Zero NSHostingView overhead; uses CALayer for backgrounds/borders, NSStackView
//  for rows, and NativeMarkdownView for expanded content.
//
//  Expand state is passed externally (coordinator-owned), so toggling one row
//  only invalidates the single row's height — not the entire cell.
//

import AppKit
import SwiftUI

// MARK: - JSON Formatting Utility

enum JSONFormatter {
    /// Single `JSONSerialization` parse; returns pretty text, or `nil` if `raw` is not JSON.
    static func prettyPrintedJSONIfValid(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if let dict = obj as? [String: Any], dict.isEmpty {
            return "{}"
        }

        guard let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: pretty, encoding: .utf8)
        else { return nil }
        return s
    }

    /// Pretty-print when valid JSON; otherwise returns `raw` unchanged.
    static func prettyJSON(_ raw: String) -> String {
        prettyPrintedJSONIfValid(raw) ?? raw
    }
}

// MARK: - Tool Category

/// Tool categories for icon selection
enum ToolCategory {
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

        // Network operations (includes mail/thread APIs)
        if name.contains("http") || name.contains("api") || name.contains("fetch")
            || name.contains("request") || name.contains("url") || name.contains("web")
            || name.contains("thread") || name.contains("mailbox") || name.contains("mail")
            || name.contains("messages")
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
enum PreviewGenerator {
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

// MARK: - ToolCategory + AppKit
extension ToolCategory {
    /// First color of the SwiftUI gradient, translated to NSColor.
    var primaryNSColor: NSColor {
        switch self {
        case .file: return NSColor(red: 0.96, green: 0.62, blue: 0.27, alpha: 1)
        case .search: return NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1)
        case .terminal: return NSColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1)
        case .network: return NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1)
        case .database: return NSColor(red: 0.93, green: 0.29, blue: 0.60, alpha: 1)
        case .code: return NSColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1)
        case .general: return NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
        }
    }
}

// MARK: - NativeToolCallGroupView

final class NativeToolCallGroupView: NSView {

    // MARK: Subviews

    private let accentStrip = NSView()
    private let rowStack = NSStackView()
    private var rowViews: [NativeToolCallRowView] = []

    /// pins group height — intrinsic alone is not always honored when only top is pinned to the cell.
    private var groupHeightConstraint: NSLayoutConstraint?

    // MARK: State

    private var lastCallCount = 0

    // MARK: Callbacks

    var onToggle: ((String) -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(
        calls: [ToolCallItem],
        expandedIds: Set<String>,
        width: CGFloat,
        theme: any ThemeProtocol,
        onToggle: @escaping (String) -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged

        let statusColor = statusNSColor(calls: calls, theme: theme)
        accentStrip.layer?.backgroundColor = statusColor.withAlphaComponent(0.7).cgColor

        layer?.backgroundColor = NSColor(theme.secondaryBackground).withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = statusColor.withAlphaComponent(0.25).cgColor

        while rowViews.count < calls.count {
            let row = NativeToolCallRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            rowViews.append(row)
        }
        while rowViews.count > calls.count {
            let removed = rowViews.removeLast()
            rowStack.removeArrangedSubview(removed)
            removed.removeFromSuperview()
        }

        let innerWidth = max(0, width - 8 - 6)  // subtract accent strip + padding
        for (index, item) in calls.enumerated() {
            let row = rowViews[index]
            let isExpanded = expandedIds.contains(item.call.id)
            row.configure(
                item: item,
                index: index,
                totalCount: calls.count,
                isExpanded: isExpanded,
                width: innerWidth,
                theme: theme
            ) { [weak self] in
                self?.onToggle?(item.call.id)
            } onHeightChanged: { [weak self] in
                self?.onHeightChanged?()
            }
        }

        let totalH = measuredHeight()
        if let c = groupHeightConstraint {
            c.constant = max(totalH, 1)
        } else {
            let c = heightAnchor.constraint(equalToConstant: max(totalH, 1))
            c.priority = .required
            c.isActive = true
            groupHeightConstraint = c
        }
        invalidateIntrinsicContentSize()
    }

    // MARK: Measured height (used by cell coordinator)

    func measuredHeight() -> CGFloat {
        rowViews.reduce(0) { $0 + $1.measuredHeight() }
    }

    // provide intrinsic content size for auto layout
    override var intrinsicContentSize: NSSize {
        let height = measuredHeight()
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: - Private

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        accentStrip.translatesAutoresizingMaskIntoConstraints = false
        accentStrip.wantsLayer = true
        accentStrip.layer?.cornerRadius = 2
        addSubview(accentStrip)

        rowStack.orientation = .vertical
        rowStack.spacing = 0
        rowStack.distribution = .fill
        // default .center horizontally centers subviews in a vertical stack; keep rows flush left
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            // accentStrip tracks rowStack height (not the group view's total height)
            accentStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            accentStrip.topAnchor.constraint(equalTo: topAnchor),
            accentStrip.bottomAnchor.constraint(equalTo: rowStack.bottomAnchor),
            accentStrip.widthAnchor.constraint(equalToConstant: 3),

            rowStack.leadingAnchor.constraint(equalTo: accentStrip.trailingAnchor, constant: 5),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func statusNSColor(calls: [ToolCallItem], theme: any ThemeProtocol) -> NSColor {
        if calls.contains(where: { $0.result == nil }) {
            return NSColor(theme.accentColor)
        } else if calls.contains(where: { ($0.result.map(ToolEnvelope.isError) ?? false) }) {
            return NSColor(theme.errorColor)
        } else {
            return NSColor(theme.successColor)
        }
    }
}

// MARK: - NativeToolCallRowView

final class NativeToolCallRowView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    private let statusIcon = NSImageView()
    /// Replaces `statusIcon` while this row's `speak` call is still
    /// playing audio (matched via `TTSService.activeSpeakCallId`).
    private let statusSpinner = NSProgressIndicator()
    private let categoryIcon = NSImageView()
    private let categoryBg = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let argPreviewLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    // Expanded content
    private let contentContainer = NSView()
    private let argumentsSectionTitle = NSTextField(labelWithString: L("ARGUMENTS"))
    private var resultSectionTitle: NSTextField?
    private var argsView: NativeMarkdownView?
    private var resultView: NativeMarkdownView?
    private let separatorView = NSView()
    /// pins contentContainer height for hit-testing; toggled when result section is shown
    private var contentBottomToArgs: NSLayoutConstraint?
    private var contentBottomToResult: NSLayoutConstraint?
    private var resultTitleTopToArgs: NSLayoutConstraint?
    private var resultViewTopToTitle: NSLayoutConstraint?

    /// headings + body share the same left/right inset (matches reference: ARGUMENTS/RESULT align with code/result text)
    private static let sectionContentInset: CGFloat = 12
    /// row `contentContainer` is inset 12+12; section content is inset 12+12 → `innerWidth - 48` for markdown
    private static var sectionMarkdownWidthDeduction: CGFloat { 4 * sectionContentInset }

    // MARK: Self-sizing height constraint

    private var rowHeight: NSLayoutConstraint?

    // MARK: State

    private var isExpanded = false
    private var cachedArgs: String?
    private var currentItemId: String = ""
    private var currentItem: ToolCallItem?
    private var currentWidth: CGFloat = 0
    private var lastConfiguredTheme: (any ThemeProtocol)?
    /// `nonisolated(unsafe)` so deinit can read it; only ever set in
    /// init on the main actor.
    nonisolated(unsafe) private var ttsObservation: NSObjectProtocol?

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
        ttsObservation = NotificationCenter.default.addObserver(
            forName: .ttsPlaybackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatusIndicator()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation = ttsObservation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let h = hit {
            if h === contentContainer && isExpanded {
                if let a = argsView {
                    let pa = convert(point, to: a)
                    if let inner = a.hitTest(pa) { return inner }
                }
                if let r = resultView, !r.isHidden {
                    let pr = convert(point, to: r)
                    if let inner = r.hitTest(pr) { return inner }
                }
            }
            return h
        }
        guard isExpanded else { return nil }
        let pc = convert(point, to: contentContainer)
        return contentContainer.hitTest(pc)
    }

    // MARK: Configure

    func configure(
        item: ToolCallItem,
        index: Int,
        totalCount: Int,
        isExpanded: Bool,
        width: CGFloat,
        theme: any ThemeProtocol,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        self.currentWidth = width
        self.lastConfiguredTheme = theme

        let isNew = item.call.id != currentItemId
        currentItemId = item.call.id
        currentItem = item

        refreshStatusIndicator()

        let category = ToolCategory.from(toolName: item.call.function.name)
        categoryIcon.image = NSImage(systemSymbolName: category.icon, accessibilityDescription: nil)
        let tintColor = category.primaryNSColor
        categoryIcon.contentTintColor = tintColor
        categoryBg.layer?.backgroundColor = tintColor.withAlphaComponent(0.15).cgColor

        nameLabel.stringValue = item.call.function.name
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = NSColor(theme.primaryText)

        if let preview = PreviewGenerator.jsonPreview(item.call.function.arguments, maxLength: 80) {
            argPreviewLabel.stringValue = preview
            argPreviewLabel.isHidden = false
        } else {
            argPreviewLabel.isHidden = true
        }
        argPreviewLabel.font = NSFont.systemFont(ofSize: 11)
        argPreviewLabel.textColor = NSColor(theme.tertiaryText)

        updateChevron(expanded: isExpanded, animated: !isNew && isExpanded != self.isExpanded)
        self.isExpanded = isExpanded

        separatorView.isHidden = !isExpanded
        contentContainer.isHidden = !isExpanded

        if isExpanded {
            applyToolDetailSectionHeading(to: argumentsSectionTitle, text: "ARGUMENTS", theme: theme)

            let rawArgs = item.call.function.arguments
            if isNew || cachedArgs == nil {
                let pretty = JSONFormatter.prettyJSON(rawArgs)
                cachedArgs = pretty.isEmpty ? rawArgs : pretty
            }
            if let args = cachedArgs {
                let av = ensureArgsView()
                let textW = max(0, width - Self.sectionMarkdownWidthDeduction)
                av.configure(
                    text: "```json\n\(args)\n```",
                    width: textW,
                    theme: theme,
                    cacheKey: "args-\(item.call.id)",
                    isStreaming: false
                )
                av.onHeightChanged = { [weak self] in self?.applyHeight() }
            }
            if let result = item.result {
                ensureResultSectionTitle(theme: theme).isHidden = false

                let rv = ensureResultView()
                rv.isHidden = false
                let textW = max(0, width - Self.sectionMarkdownWidthDeduction)
                let resultMarkdown = Self.markdownForToolResultDisplay(result)
                rv.configure(
                    text: resultMarkdown,
                    width: textW,
                    theme: theme,
                    cacheKey: "result-\(item.call.id)",
                    isStreaming: false
                )
                rv.onHeightChanged = { [weak self] in self?.applyHeight() }
                contentBottomToArgs?.isActive = false
                contentBottomToResult?.isActive = true
            } else {
                tearDownResultSection()
            }
        }

        applyHeight()

        // row separator (hidden for last row)
        if let sep = subviews.last, sep.identifier?.rawValue == "rowSep" {
            sep.isHidden = index >= totalCount - 1
        }
    }

    // MARK: Measured height

    func measuredHeight() -> CGFloat {
        let rowH: CGFloat = 40
        guard isExpanded else { return rowH + 1 }  // 40pt header + 1pt separator line at bottom
        // matches InlineToolCallView ToolDetailSection header row (~9pt bold + padding)
        let sectionTitleH: CGFloat = 22
        let textW = max(0, currentWidth - Self.sectionMarkdownWidthDeduction)
        let argsH = argsView?.measuredHeight(for: textW) ?? 0
        let resultH: CGFloat
        if let rv = resultView, !rv.isHidden {
            resultH = 8 + sectionTitleH + rv.measuredHeight(for: textW)
        } else {
            resultH = 0
        }
        return rowH + 1 + 8 + sectionTitleH + argsH + resultH + 8
    }

    // MARK: - Private

    /// JSON → fenced `json` block (pretty-printed). Anything else → raw markdown so prose/lists/**bold** render.
    ///
    /// Special case: a `ToolEnvelope` success result whose payload is a
    /// `{"text": "..."}` carrier renders as the prose verbatim (markdown).
    /// This keeps file_tree / file_read / capability listings readable in
    /// the tool-call card instead of getting buried under a JSON wrapper.
    private static func markdownForToolResultDisplay(_ result: String) -> String {
        if ToolEnvelope.isError(result) {
            return result
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any],
            payload.count == 1,
            let text = payload["text"] as? String
        {
            return text
        }
        if let pretty = JSONFormatter.prettyPrintedJSONIfValid(trimmed) {
            return "```json\n\(pretty)\n```"
        }
        return trimmed
    }

    private func applyHeight() {
        rowHeight?.constant = measuredHeight()
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // content views first (behind button)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(statusIcon)

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isIndeterminate = true
        statusSpinner.isDisplayedWhenStopped = false
        addSubview(statusSpinner)

        categoryBg.translatesAutoresizingMaskIntoConstraints = false
        categoryBg.wantsLayer = true
        categoryBg.layer?.cornerRadius = 6
        addSubview(categoryBg)

        categoryIcon.translatesAutoresizingMaskIntoConstraints = false
        categoryIcon.imageScaling = .scaleProportionallyUpOrDown
        categoryBg.addSubview(categoryIcon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.maximumNumberOfLines = 1
        nameLabel.alignment = .left
        nameLabel.usesSingleLineMode = true
        // keep tool name visible — arg preview + chevron must shrink first
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(nameLabel)

        argPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        argPreviewLabel.isEditable = false; argPreviewLabel.isBordered = false
        argPreviewLabel.drawsBackground = false
        argPreviewLabel.lineBreakMode = .byTruncatingTail; argPreviewLabel.maximumNumberOfLines = 1
        argPreviewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        argPreviewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(argPreviewLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.wantsLayer = true
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.imageScaling = .scaleProportionallyUpOrDown
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(chevron)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        argumentsSectionTitle.translatesAutoresizingMaskIntoConstraints = false
        argumentsSectionTitle.isEditable = false
        argumentsSectionTitle.isBordered = false
        argumentsSectionTitle.drawsBackground = false
        argumentsSectionTitle.alignment = .left
        contentContainer.addSubview(argumentsSectionTitle)

        NSLayoutConstraint.activate([
            argumentsSectionTitle.leadingAnchor.constraint(
                equalTo: contentContainer.leadingAnchor,
                constant: Self.sectionContentInset
            ),
            argumentsSectionTitle.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor),
            argumentsSectionTitle.topAnchor.constraint(equalTo: contentContainer.topAnchor),
        ])

        // header button ON TOP — transparent overlay for click handling
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""
        headerButton.isBordered = false
        headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.focusRingType = .none
        headerButton.target = self; headerButton.action = #selector(tapped)
        addSubview(headerButton)  // added last → front of Z-order

        let rowH: CGFloat = 40

        // self-sizing height constraint
        let h = heightAnchor.constraint(equalToConstant: rowH + 1)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        rowHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: rowH),

            statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: rowH / 2),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),

            statusSpinner.centerXAnchor.constraint(equalTo: statusIcon.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: statusIcon.centerYAnchor),

            categoryBg.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            categoryBg.centerYAnchor.constraint(equalTo: statusIcon.centerYAnchor),
            categoryBg.widthAnchor.constraint(equalToConstant: 24),
            categoryBg.heightAnchor.constraint(equalToConstant: 24),

            categoryIcon.centerXAnchor.constraint(equalTo: categoryBg.centerXAnchor),
            categoryIcon.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            categoryIcon.widthAnchor.constraint(equalToConstant: 14),
            categoryIcon.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: categoryBg.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),

            argPreviewLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            argPreviewLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            argPreviewLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: rowH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),
        ])

        // row separator line at bottom
        let rowSep = NSView()
        rowSep.identifier = NSUserInterfaceItemIdentifier("rowSep")
        rowSep.translatesAutoresizingMaskIntoConstraints = false
        rowSep.wantsLayer = true
        rowSep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        addSubview(rowSep)
        NSLayoutConstraint.activate([
            rowSep.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowSep.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowSep.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowSep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func ensureArgsView() -> NativeMarkdownView {
        if let v = argsView { return v }
        let v = NativeMarkdownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Self.sectionContentInset),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -Self.sectionContentInset),
            v.topAnchor.constraint(equalTo: argumentsSectionTitle.bottomAnchor, constant: 4),
        ])
        argsView = v

        let pinArgs = contentContainer.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        pinArgs.isActive = true
        contentBottomToArgs = pinArgs
        return v
    }

    private func ensureResultSectionTitle(theme: any ThemeProtocol) -> NSTextField {
        let resultLabel = L("RESULT")
        if let t = resultSectionTitle {
            applyToolDetailSectionHeading(to: t, text: resultLabel, theme: theme)
            return t
        }
        let t = NSTextField(labelWithString: resultLabel)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isEditable = false
        t.isBordered = false
        t.drawsBackground = false
        t.alignment = .left
        applyToolDetailSectionHeading(to: t, text: resultLabel, theme: theme)
        contentContainer.addSubview(t)
        let av = ensureArgsView()
        let top = t.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 8)
        top.isActive = true
        resultTitleTopToArgs = top
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Self.sectionContentInset),
            t.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor),
        ])
        resultSectionTitle = t
        return t
    }

    private func ensureResultView() -> NativeMarkdownView {
        if let v = resultView { return v }
        // Lazily create args / result-title if missing (defensive against unexpected
        // call ordering during rapid cell reconfiguration or reuse).
        if resultSectionTitle == nil || argsView == nil {
            assertionFailure("ensureResultView: expected ensureResultSectionTitle to be called first")
            if argsView == nil {
                _ = ensureArgsView()
            }
            if resultSectionTitle == nil {
                _ = ensureResultSectionTitle(theme: lastConfiguredTheme ?? LightTheme())
            }
        }
        guard let rt = resultSectionTitle else {
            // Should never reach here after the above, but return a detached view
            // rather than crashing in production.
            let v = NativeMarkdownView()
            resultView = v
            return v
        }
        let v = NativeMarkdownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentContainer.addSubview(v)

        contentBottomToArgs?.isActive = false
        let pinResult = contentContainer.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        pinResult.isActive = true
        contentBottomToResult = pinResult

        let topToTitle = v.topAnchor.constraint(equalTo: rt.bottomAnchor, constant: 4)
        topToTitle.isActive = true
        resultViewTopToTitle = topToTitle

        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: Self.sectionContentInset),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -Self.sectionContentInset),
        ])
        resultView = v
        return v
    }

    /// removes result UI so the args section can own `contentContainer.bottom` without conflicting constraints
    private static func toolDetailSectionHeadingFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: 9, weight: .bold)
        guard let roundedDesc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: roundedDesc, size: 9) ?? base
    }

    private func applyToolDetailSectionHeading(to field: NSTextField, text: String, theme: any ThemeProtocol) {
        let font = Self.toolDetailSectionHeadingFont()
        let s = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: s.length)
        s.addAttribute(.font, value: font, range: full)
        s.addAttribute(.kern, value: 0.8, range: full)
        s.addAttribute(.foregroundColor, value: NSColor(theme.tertiaryText), range: full)
        field.attributedStringValue = s
    }

    private func tearDownResultSection() {
        resultTitleTopToArgs?.isActive = false
        resultViewTopToTitle?.isActive = false
        resultTitleTopToArgs = nil
        resultViewTopToTitle = nil

        contentBottomToResult?.isActive = false
        contentBottomToResult = nil

        resultSectionTitle?.removeFromSuperview()
        resultSectionTitle = nil
        resultView?.removeFromSuperview()
        resultView = nil

        contentBottomToArgs?.isActive = true
    }

    private func statusInfo(item: ToolCallItem, theme: any ThemeProtocol) -> (String, NSColor) {
        if item.result == nil { return ("circle.dotted", NSColor(theme.accentColor)) }
        if let r = item.result, ToolEnvelope.isError(r) {
            return ("xmark.circle.fill", NSColor(theme.errorColor))
        }
        return ("checkmark.circle.fill", NSColor(theme.successColor))
    }

    /// Spinner if this is a `speak` call still playing; otherwise the
    /// static dotted/check/xmark icon.
    private func refreshStatusIndicator() {
        guard let item = currentItem, let theme = lastConfiguredTheme else {
            statusSpinner.stopAnimation(nil)
            statusIcon.isHidden = false
            return
        }
        let isSpeakInFlight =
            item.call.function.name == "speak"
            && TTSService.shared.activeSpeakCallId == item.call.id
        if isSpeakInFlight {
            statusIcon.isHidden = true
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
            statusIcon.isHidden = false
            let (statusImg, statusColor) = statusInfo(item: item, theme: theme)
            statusIcon.image = NSImage(systemSymbolName: statusImg, accessibilityDescription: nil)
            statusIcon.contentTintColor = statusColor
        }
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        let angle: CGFloat = expanded ? .pi / 2 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                chevron.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            }
        } else {
            chevron.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
    }

    @objc private func tapped() { onToggle?() }
}
