//
//  MarkdownBlockViews.swift
//  osaurus
//
//  Additional markdown block views: headings, blockquotes, horizontal rules, and lists
//

import SwiftUI

// MARK: - Heading View

struct HeadingView: View {
    let level: Int
    let text: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    private var fontSize: CGFloat {
        let scale = Typography.scale(for: baseWidth)
        // Use theme title/heading/body sizes as base, with level offsets
        switch level {
        case 1: return CGFloat(theme.titleSize) * scale
        case 2: return (CGFloat(theme.titleSize) - 4) * scale
        case 3: return CGFloat(theme.headingSize) * scale
        case 4: return (CGFloat(theme.headingSize) - 2) * scale
        case 5: return (CGFloat(theme.bodySize) + 2) * scale
        default: return CGFloat(theme.bodySize) * scale
        }
    }

    private var fontWeight: Font.Weight {
        switch level {
        case 1, 2: return .bold
        case 3, 4: return .semibold
        default: return .medium
        }
    }

    private var topPadding: CGFloat {
        switch level {
        case 1: return 8
        case 2: return 6
        case 3: return 4
        default: return 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headingText
            if level <= 2 {
                underline
            }
        }
        .padding(.top, topPadding)
    }

    @ViewBuilder
    private var headingText: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(theme.font(size: fontSize, weight: fontWeight))
                .foregroundColor(theme.primaryText)
                .lineSpacing(2)
        } else {
            Text(text)
                .font(theme.font(size: fontSize, weight: fontWeight))
                .foregroundColor(theme.primaryText)
                .lineSpacing(2)
        }
    }

    private var underline: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        theme.primaryBorder.opacity(0.5),
                        theme.primaryBorder.opacity(0.1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.top, 8)
    }
}

// MARK: - Blockquote View

struct BlockquoteView: View {
    let content: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.8),
                            theme.accentColor.opacity(0.4),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)

            // Quote content
            quoteText
                .padding(.leading, 14)
                .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
    }

    @ViewBuilder
    private var quoteText: some View {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(Typography.body(baseWidth, theme: theme))
                .italic()
                .foregroundColor(theme.secondaryText)
                .lineSpacing(4)
        } else {
            Text(content)
                .font(Typography.body(baseWidth, theme: theme))
                .italic()
                .foregroundColor(theme.secondaryText)
                .lineSpacing(4)
        }
    }
}

// MARK: - Horizontal Rule View

struct HorizontalRuleView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryBorder.opacity(0.0),
                            theme.primaryBorder.opacity(0.5),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            Circle()
                .fill(theme.primaryBorder.opacity(0.5))
                .frame(width: 4, height: 4)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.primaryBorder.opacity(0.5),
                            theme.primaryBorder.opacity(0.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - List Block View

struct ListBlockView: View {
    let items: [String]
    let ordered: Bool
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ListItemView(
                    item: item,
                    index: index,
                    ordered: ordered,
                    baseWidth: baseWidth
                )
            }
        }
        .padding(.leading, 4)
    }
}

// MARK: - List Item View (Extracted for optimization)

private struct ListItemView: View {
    let item: String
    let index: Int
    let ordered: Bool
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Bullet or number - uses theme body size and mono font
            if ordered {
                Text("\(index + 1).")
                    .font(
                        theme.monoFont(
                            size: CGFloat(theme.bodySize) * Typography.scale(for: baseWidth),
                            weight: .medium
                        )
                    )
                    .foregroundColor(theme.accentColor)
                    .frame(width: 24, alignment: .trailing)
            } else {
                Circle()
                    .fill(theme.accentColor.opacity(0.7))
                    .frame(width: 6, height: 6)
                    .padding(.top, 7)
                    .frame(width: 24, alignment: .center)
            }

            // Item content
            itemText
        }
    }

    @ViewBuilder
    private var itemText: some View {
        if let attributed = try? AttributedString(
            markdown: item,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(Typography.body(baseWidth, theme: theme))
                .foregroundColor(theme.primaryText)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item)
                .font(Typography.body(baseWidth, theme: theme))
                .foregroundColor(theme.primaryText)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Previews

#if DEBUG
    struct MarkdownBlockViews_Previews: PreviewProvider {
        static var previews: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Group {
                        Text("Headings")
                            .font(.caption)
                            .foregroundColor(.gray)

                        HeadingView(level: 1, text: "Heading Level 1", baseWidth: 600)
                        HeadingView(level: 2, text: "Heading Level 2", baseWidth: 600)
                        HeadingView(level: 3, text: "Heading Level 3", baseWidth: 600)
                        HeadingView(level: 4, text: "Heading Level 4", baseWidth: 600)
                    }

                    Divider()

                    Group {
                        Text("Blockquote")
                            .font(.caption)
                            .foregroundColor(.gray)

                        BlockquoteView(
                            content:
                                "This is a blockquote with some **important** information that might span multiple lines.",
                            baseWidth: 600
                        )
                    }

                    Divider()

                    Group {
                        Text("Horizontal Rule")
                            .font(.caption)
                            .foregroundColor(.gray)

                        HorizontalRuleView()
                    }

                    Divider()

                    Group {
                        Text("Unordered List")
                            .font(.caption)
                            .foregroundColor(.gray)

                        ListBlockView(
                            items: [
                                "First item with **bold** text",
                                "Second item",
                                "Third item with *italic* text",
                            ],
                            ordered: false,
                            baseWidth: 600
                        )
                    }

                    Divider()

                    Group {
                        Text("Ordered List")
                            .font(.caption)
                            .foregroundColor(.gray)

                        ListBlockView(
                            items: [
                                "First step",
                                "Second step with more detail",
                                "Third step to complete the task",
                            ],
                            ordered: true,
                            baseWidth: 600
                        )
                    }
                }
                .padding(24)
                .frame(width: 600, alignment: .leading)
            }
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
