//
//  ToolSelectorView.swift
//  osaurus
//
//  Tool selector showing available tools and their current state.
//  Displays persona overrides where applicable, toggles modify global config.
//

import SwiftUI

struct ToolSelectorView: View {
    /// All available tools from the registry
    let tools: [ToolRegistry.ToolEntry]
    /// Persona's tool overrides (if any). Used to show persona-level settings.
    let personaToolOverrides: [String: Bool]?
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @Environment(\.theme) private var theme

    private var filteredTools: [ToolRegistry.ToolEntry] {
        if searchText.isEmpty {
            return tools
        }
        return tools.filter {
            SearchService.matches(query: searchText, in: $0.name)
                || SearchService.matches(query: searchText, in: $0.description)
        }
    }

    /// Count of enabled tools (with persona overrides applied)
    private var enabledCount: Int {
        tools.filter { isToolEnabled($0.name) }.count
    }

    /// Check if a tool is enabled (persona override > global config)
    private func isToolEnabled(_ name: String) -> Bool {
        if let personaOverrides = personaToolOverrides,
            let personaValue = personaOverrides[name]
        {
            return personaValue
        }
        return ToolRegistry.shared.isGlobalEnabled(name)
    }

    /// Check if a tool has a persona-level override
    private func hasPersonaOverride(_ name: String) -> Bool {
        guard let personaOverrides = personaToolOverrides else { return false }
        return personaOverrides[name] != nil
    }

    /// Toggle a tool's global enabled state
    private func toggleTool(_ name: String) {
        let currentlyEnabled = isToolEnabled(name)
        ToolRegistry.shared.setEnabled(!currentlyEnabled, for: name)
    }

    /// Enable all tools globally
    private func enableAll() {
        for tool in tools {
            ToolRegistry.shared.setEnabled(true, for: tool.name)
        }
    }

    /// Disable all tools globally
    private func disableAll() {
        for tool in tools {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
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
        .frame(width: 360, height: min(CGFloat(tools.count * 56 + 160), 480))
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

                if personaToolOverrides != nil {
                    Text("Persona overrides active")
                        .font(.system(size: 10))
                        .foregroundColor(theme.accentColor)
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
                        hasPersonaOverride: hasPersonaOverride(tool.name),
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
    let hasPersonaOverride: Bool
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

                    // Persona override indicator (blue dot)
                    if hasPersonaOverride {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 5, height: 5)
                            .help("Set by persona")
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
                    ],
                    personaToolOverrides: ["browser_type": true],
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
