//
//  GroupedToolResponseView.swift
//  osaurus
//
//  Collapsible UI to display assistant tool calls and their results, grouped under a message.
//

import AppKit
import SwiftUI

struct GroupedToolResponseView: View {
    let calls: [ToolCall]
    let resultsById: [String: String]
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    private var completedCount: Int {
        resultsById.count
    }

    private var rejectedCount: Int {
        resultsById.values.filter { $0.hasPrefix("[REJECTED]") }.count
    }

    private var successCount: Int {
        completedCount - rejectedCount
    }

    private var hasRejections: Bool {
        rejectedCount > 0
    }

    private var isRunning: Bool {
        completedCount < calls.count
    }

    /// Header status color based on state
    private var statusColor: Color {
        if isRunning {
            return theme.accentColor
        } else if hasRejections {
            return theme.errorColor
        } else {
            return theme.successColor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // Expandable content with smooth height animation
            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryBorder.opacity(0.0),
                                theme.primaryBorder.opacity(0.3),
                                theme.primaryBorder.opacity(0.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                content
                    .padding(.top, 12)
            }
            .frame(maxHeight: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .animation(theme.springAnimation(), value: isExpanded)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.secondaryBackground.opacity(isHovered ? 0.85 : 0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isHovered ? theme.primaryBorder.opacity(0.4) : theme.primaryBorder.opacity(0.25),
                            lineWidth: 0.5
                        )
                )
        )
        .shadow(
            color: theme.shadowColor.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 6 : 3,
            x: 0,
            y: isHovered ? 3 : 1
        )
        .animation(theme.animationQuick(), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var header: some View {
        Button(action: {
            withAnimation(theme.springAnimation()) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 10) {
                // Tool icon with animated background
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(isRunning ? 0.15 : 0.12))
                        .frame(width: 28, height: 28)

                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(statusColor)
                }

                // Title and status
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool \(calls.count == 1 ? "call" : "calls")")
                        .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    // Status indicator
                    HStack(spacing: 5) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.45)
                                .frame(width: 12, height: 12)

                            Text("\(completedCount)/\(calls.count) running...")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                                .foregroundColor(theme.accentColor)
                        } else if hasRejections {
                            Image(systemName: "xmark.circle.fill")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                                .foregroundColor(theme.errorColor)

                            Text(
                                rejectedCount == calls.count
                                    ? "\(rejectedCount) rejected"
                                    : "\(successCount) completed, \(rejectedCount) rejected"
                            )
                            .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                            .foregroundColor(theme.errorColor)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                                .foregroundColor(theme.successColor)

                            Text("\(calls.count) completed")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                                .foregroundColor(theme.successColor)
                        }
                    }
                }

                Spacer()

                // Expand/collapse chevron
                Image(systemName: "chevron.right")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(theme.springAnimation(), value: isExpanded)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(spacing: 8) {
            ForEach(Array(calls.enumerated()), id: \.0) { index, call in
                ToolCallRow(
                    call: call,
                    result: resultsById[call.id],
                    index: index + 1
                )
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Tool Call Row

private struct ToolCallRow: View {
    let call: ToolCall
    let result: String?
    let index: Int

    @State private var showArgs: Bool = false
    @State private var showResult: Bool = false
    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    private var isComplete: Bool {
        result != nil
    }

    private var isRejected: Bool {
        result?.hasPrefix("[REJECTED]") == true
    }

    /// Status color based on completion state
    private var statusColor: Color {
        if !isComplete {
            return theme.accentColor
        } else if isRejected {
            return theme.errorColor
        } else {
            return theme.successColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with function name
            HStack(spacing: 10) {
                // Index badge with status ring
                ZStack {
                    Circle()
                        .strokeBorder(
                            statusColor.opacity(0.5),
                            lineWidth: 1.5
                        )
                        .frame(width: 22, height: 22)

                    Text("\(index)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(statusColor)
                }

                // Function name
                HStack(spacing: 6) {
                    Image(systemName: "function")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    Text(call.function.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                }

                Spacer()

                // Status indicator
                if !isComplete {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)

                        Text("Running")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.accentColor.opacity(0.1))
                    )
                } else if isRejected {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))

                        Text("Rejected")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.errorColor.opacity(0.1))
                    )
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))

                        Text("Done")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.successColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(theme.successColor.opacity(0.1))
                    )
                }
            }

            // Toggle buttons
            HStack(spacing: 8) {
                ToolToggleButton(
                    label: "Arguments",
                    icon: "curlybraces",
                    isActive: showArgs
                ) {
                    withAnimation(theme.springAnimation()) {
                        showArgs.toggle()
                    }
                }

                if isComplete {
                    ToolToggleButton(
                        label: "Result",
                        icon: "doc.text",
                        isActive: showResult
                    ) {
                        withAnimation(theme.springAnimation()) {
                            showResult.toggle()
                        }
                    }
                }

                Spacer()
            }

            // Expandable content
            if showArgs {
                ToolCodeBlock(
                    title: "Arguments",
                    text: prettyJSON(call.function.arguments),
                    language: "json"
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                    )
                )
            }

            if showResult, let result {
                ToolCodeBlock(
                    title: "Result",
                    text: result,
                    language: nil
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                    )
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.primaryBackground.opacity(isHovered ? 0.7 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1), lineWidth: 0.5)
                )
        )
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return raw }
        return String(data: pretty, encoding: .utf8) ?? raw
    }
}

// MARK: - Toggle Button

private struct ToolToggleButton: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)

                if isActive {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? theme.accentColor.opacity(0.12)
                            : (isHovered
                                ? theme.tertiaryBackground.opacity(0.8) : theme.tertiaryBackground.opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isActive ? theme.accentColor.opacity(0.3) : Color.clear,
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Code Block

private struct ToolCodeBlock: View {
    let title: String
    let text: String
    let language: String?

    @State private var isCopied = false
    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    if let language {
                        Image(systemName: languageIcon(for: language))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.8)
                }

                Spacer()

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
                .opacity(isHovered || isCopied ? 1 : 0.5)
                .animation(theme.animationQuick(), value: isHovered)
                .animation(theme.animationQuick(), value: isCopied)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                theme.codeBlockBackground.opacity(0.5)
                    .overlay(
                        LinearGradient(
                            colors: [
                                theme.primaryBorder.opacity(0.04),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )

            // Code content with line numbers for multi-line
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    // Line numbers for multi-line content
                    if text.contains("\n") {
                        lineNumbers
                    }

                    Text(text)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                }
            }
            .background(theme.codeBlockBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isHovered ? theme.primaryBorder.opacity(0.3) : theme.primaryBorder.opacity(0.15),
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: theme.shadowColor.opacity(0.04),
            radius: 2,
            x: 0,
            y: 1
        )
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }

    private var lineNumbers: some View {
        let lines = text.components(separatedBy: "\n")
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(1 ... lines.count, id: \.self) { lineNum in
                Text("\(lineNum)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.4))
                    .frame(height: 15)
            }
        }
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

    private func languageIcon(for lang: String) -> String {
        switch lang.lowercased() {
        case "json": return "curlybraces"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
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

// MARK: - Preview

#if DEBUG
    struct GroupedToolResponseView_Previews: PreviewProvider {
        static var previews: some View {
            let calls = [
                ToolCall(
                    id: "call_1",
                    type: "function",
                    function: ToolCallFunction(
                        name: "get_weather",
                        arguments: "{\"location\": \"San Francisco\", \"unit\": \"celsius\"}"
                    )
                ),
                ToolCall(
                    id: "call_2",
                    type: "function",
                    function: ToolCallFunction(
                        name: "search_web",
                        arguments: "{\"query\": \"Swift programming\", \"limit\": 10}"
                    )
                ),
                ToolCall(
                    id: "call_3",
                    type: "function",
                    function: ToolCallFunction(
                        name: "read_file",
                        arguments: "{\"path\": \"/Users/example/document.txt\"}"
                    )
                ),
            ]

            let results = [
                "call_1": "Temperature: 18°C, Conditions: Partly cloudy with a gentle breeze from the west.",
                "call_2":
                    "Found 10 results for 'Swift programming':\n1. Swift.org - Official Swift Language\n2. Swift Programming Guide\n3. Learn Swift in 30 days",
            ]

            VStack(spacing: 20) {
                GroupedToolResponseView(calls: calls, resultsById: results)

                GroupedToolResponseView(calls: [calls[0]], resultsById: ["call_1": results["call_1"]!])
            }
            .frame(width: 500)
            .padding()
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
