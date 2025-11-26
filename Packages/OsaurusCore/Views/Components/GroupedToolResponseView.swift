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

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                Divider()
                    .background(theme.primaryBorder.opacity(0.3))
                    .padding(.horizontal, 12)

                content
                    .padding(.top, 8)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5)
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var header: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                // Tool icon with count badge
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                Text("Tool \(calls.count == 1 ? "call" : "calls")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                // Status indicator
                if resultsById.count < calls.count {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Running...")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.successColor.opacity(0.8))
                        Text("\(calls.count) completed")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(spacing: 6) {
            ForEach(Array(calls.enumerated()), id: \.0) { (index, call) in
                ToolCallRow(
                    call: call,
                    result: resultsById[call.id],
                    index: index + 1
                )
            }
        }
        .padding(.bottom, 4)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with function name
            HStack(spacing: 8) {
                // Index badge
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )

                // Function name
                Text(call.function.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                Spacer()

                // Status
                if result == nil {
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.successColor)
                }
            }

            // Toggle buttons
            HStack(spacing: 12) {
                ToolToggleButton(
                    label: "Arguments",
                    icon: "curlybraces",
                    isActive: showArgs,
                    action: { withAnimation(.easeInOut(duration: 0.2)) { showArgs.toggle() } }
                )

                if result != nil {
                    ToolToggleButton(
                        label: "Result",
                        icon: "text.alignleft",
                        isActive: showResult,
                        action: { withAnimation(.easeInOut(duration: 0.2)) { showResult.toggle() } }
                    )
                }

                Spacer()
            }

            // Expandable content
            if showArgs {
                ToolCodeBlock(
                    title: "Arguments",
                    text: prettyJSON(call.function.arguments)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showResult, let result {
                ToolCodeBlock(
                    title: "Result",
                    text: result
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.primaryBackground.opacity(isHovered ? 0.6 : 0.4))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
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
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isActive ? Color.accentColor : theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.15)
                            : (isHovered ? theme.tertiaryBackground : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Code Block

private struct ToolCodeBlock: View {
    let title: String
    let text: String

    @State private var isCopied = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)

                Spacer()

                Button(action: copyToClipboard) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isCopied ? theme.successColor : theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.codeBlockBackground.opacity(0.5))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.primaryText.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(theme.codeBlockBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            isCopied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation {
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
                        arguments: "{\"query\": \"Swift programming\"}"
                    )
                ),
            ]

            let results = [
                "call_1": "Temperature: 18°C, Conditions: Partly cloudy",
                "call_2": "Found 10 results for 'Swift programming'...",
            ]

            GroupedToolResponseView(calls: calls, resultsById: results)
                .frame(width: 400)
                .padding()
                .background(Color(hex: "0f0f10"))
        }
    }
#endif
