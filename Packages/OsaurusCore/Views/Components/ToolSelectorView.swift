//
//  ToolSelectorView.swift
//  osaurus
//
//  Per-session tool selector with search and toggles.
//  Allows users to override global tool settings for the current chat session.
//

import SwiftUI

struct ToolSelectorView: View {
    /// All available tools from the registry
    let tools: [ToolRegistry.ToolEntry]
    /// Per-session overrides binding. Empty = use global config for all tools.
    @Binding var enabledOverrides: [String: Bool]
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var filteredTools: [ToolRegistry.ToolEntry] {
        if searchText.isEmpty {
            return tools
        }
        let query = searchText.lowercased()
        return tools.filter {
            $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
    }

    /// Count of enabled tools (with overrides applied)
    private var enabledCount: Int {
        tools.filter { isToolEnabled($0.name) }.count
    }

    /// Check if a tool is enabled (override takes precedence)
    private func isToolEnabled(_ name: String) -> Bool {
        if let override = enabledOverrides[name] {
            return override
        }
        return tools.first { $0.name == name }?.enabled ?? false
    }

    /// Toggle a tool's enabled state in the overrides
    private func toggleTool(_ name: String) {
        let currentlyEnabled = isToolEnabled(name)
        enabledOverrides[name] = !currentlyEnabled
    }

    /// Check if a tool has a per-session override
    private func hasOverride(_ name: String) -> Bool {
        enabledOverrides[name] != nil
    }

    /// Reset all overrides to use global config
    private func resetAllToGlobal() {
        enabledOverrides.removeAll()
    }

    /// Enable all tools for this session
    private func enableAll() {
        for tool in tools {
            enabledOverrides[tool.name] = true
        }
    }

    /// Disable all tools for this session
    private func disableAll() {
        for tool in tools {
            enabledOverrides[tool.name] = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with count
            header

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Search field
            searchField

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Tool list
            if filteredTools.isEmpty {
                emptyState
            } else {
                toolList
            }
        }
        .frame(width: 360, height: min(CGFloat(tools.count * 56 + 180), 480))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
                .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            // Title row
            HStack {
                Text("Available Tools")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                Text("\(enabledCount)/\(tools.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(theme.secondaryBackground)
                    )
            }

            // Action buttons row
            HStack(spacing: 8) {
                Button(action: enableAll) {
                    Text("Enable All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                }
                .buttonStyle(.plain)

                Button(action: disableAll) {
                    Text("Disable All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                if !enabledOverrides.isEmpty {
                    Button(action: resetAllToGlobal) {
                        Text("Reset")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.accentColor.opacity(0.5), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Reset all tools to global settings")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)

            TextField("Search tools...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No tools found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Tool List

    private var toolList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredTools) { tool in
                    ToolRowItem(
                        tool: tool,
                        isEnabled: isToolEnabled(tool.name),
                        hasOverride: hasOverride(tool.name),
                        onToggle: { toggleTool(tool.name) }
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Tool Row Item

private struct ToolRowItem: View {
    let tool: ToolRegistry.ToolEntry
    let isEnabled: Bool
    let hasOverride: Bool
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            // Toggle with theme accent color
            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { _ in onToggle() }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .scaleEffect(0.7)
            .frame(width: 36)

            // Tool info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isEnabled ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    // Override indicator (subtle dot)
                    if hasOverride {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                    }
                }

                Text(tool.description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            // Token estimate (subtle)
            HStack(spacing: 2) {
                Text("~\(tool.estimatedTokens)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)

                Text("tokens")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }
            .help("Adds ~\(tool.estimatedTokens) tokens to context when enabled")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? theme.secondaryBackground.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ToolSelectorView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var overrides: [String: Bool] = [:]

            var body: some View {
                ToolSelectorView(
                    tools: [
                        ToolRegistry.ToolEntry(
                            name: "browser_screenshot",
                            description: "Take a screenshot of the current browser page",
                            enabled: true,
                            parameters: nil
                        ),
                        ToolRegistry.ToolEntry(
                            name: "browser_click",
                            description: "Click an element on the page",
                            enabled: true,
                            parameters: nil
                        ),
                        ToolRegistry.ToolEntry(
                            name: "browser_type",
                            description: "Type text into an input field",
                            enabled: false,
                            parameters: nil
                        ),
                        ToolRegistry.ToolEntry(
                            name: "file_read",
                            description: "Read contents of a file",
                            enabled: true,
                            parameters: nil
                        ),
                        ToolRegistry.ToolEntry(
                            name: "file_write",
                            description: "Write contents to a file",
                            enabled: false,
                            parameters: nil
                        ),
                    ],
                    enabledOverrides: $overrides,
                    onDismiss: {}
                )
                .padding()
                .frame(width: 450, height: 550)
                .background(Color.gray.opacity(0.2))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
