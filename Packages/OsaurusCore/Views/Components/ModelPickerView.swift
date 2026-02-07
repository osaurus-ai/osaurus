//
//  ModelPickerView.swift
//  osaurus
//
//  A rich model picker with search, grouped sections, and metadata display.
//

import SwiftUI

struct ModelPickerView: View {
    let options: [ModelOption]
    @Binding var selectedModel: String?
    let personaId: UUID?
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var highlightedIndex: Int?
    @State private var keyMonitor: Any?
    @Environment(\.theme) private var theme

    // MARK: - Data

    private var groupedOptions: [(source: ModelOption.Source, models: [ModelOption])] {
        options.groupedBySource()
    }

    private var filteredGroups: [(source: ModelOption.Source, models: [ModelOption])] {
        guard !searchText.isEmpty else { return groupedOptions }
        return groupedOptions.compactMap { group in
            let groupMatches = SearchService.matches(query: searchText, in: group.source.displayName)
            let matchedModels = group.models.filter {
                SearchService.matches(query: searchText, in: $0.displayName)
                    || SearchService.matches(query: searchText, in: $0.id)
            }
            if groupMatches { return group }
            if !matchedModels.isEmpty {
                return (source: group.source, models: matchedModels)
            }
            return nil
        }
    }

    private var flatFilteredModels: [ModelOption] {
        filteredGroups.flatMap { isGroupExpanded($0.source) ? $0.models : [] }
    }

    private var highlightedModelId: String? {
        guard let index = highlightedIndex, index >= 0, index < flatFilteredModels.count else { return nil }
        return flatFilteredModels[index].id
    }

    private func isGroupExpanded(_ source: ModelOption.Source) -> Bool {
        !searchText.isEmpty || !collapsedGroups.contains(source.displayName)
    }

    private func toggleGroup(_ source: ModelOption.Source) {
        let key = source.displayName
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
    }

    // MARK: - Keyboard Navigation

    private func moveHighlight(by offset: Int) {
        let models = flatFilteredModels
        guard !models.isEmpty else { return }
        if let current = highlightedIndex {
            highlightedIndex = max(0, min(models.count - 1, current + offset))
        } else {
            highlightedIndex = offset > 0 ? 0 : models.count - 1
        }
    }

    private func selectHighlighted() {
        guard let index = highlightedIndex, index >= 0, index < flatFilteredModels.count else { return }
        selectedModel = flatFilteredModels[index].id
        onDismiss()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:  // Down arrow
                moveHighlight(by: 1)
                return nil
            case 126:  // Up arrow
                moveHighlight(by: -1)
                return nil
            case 36:  // Return/Enter
                if highlightedIndex != nil {
                    selectHighlighted()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if filteredGroups.isEmpty {
                emptyState
            } else {
                modelList
            }
        }
        .frame(width: 380, height: min(CGFloat(options.count * 48 + 160), 480))
        .background(popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.25), radius: 20, x: 0, y: 10)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: searchText) { _, _ in highlightedIndex = nil }
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.85 : 0.92))
            LinearGradient(
                colors: [theme.accentColor.opacity(theme.isDark ? 0.06 : 0.04), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Available Models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Text("\(options.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))
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

            TextField("Search models...", text: $searchText)
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
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No models found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Model List

    private var modelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredGroups, id: \.source) { group in
                        Section {
                            if isGroupExpanded(group.source) {
                                ForEach(group.models) { model in
                                    ModelRowItem(
                                        model: model,
                                        isSelected: selectedModel == model.id,
                                        isHighlighted: model.id == highlightedModelId,
                                        onSelect: {
                                            selectedModel = model.id
                                            onDismiss()
                                        }
                                    )
                                    .id(model.id)
                                }
                            }
                        } header: {
                            ModelGroupHeader(
                                source: group.source,
                                count: group.models.count,
                                isExpanded: isGroupExpanded(group.source),
                                onToggle: { toggleGroup(group.source) }
                            )
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .onChange(of: highlightedIndex) { _, newIndex in
                guard let index = newIndex, index >= 0, index < flatFilteredModels.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(flatFilteredModels[index].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Model Group Header

private struct ModelGroupHeader: View {
    let source: ModelOption.Source
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            sourceIcon
                .font(.system(size: 11))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)

            Text(source.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer()

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground)
                        .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 1))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(ModelHoverRowStyle(isHovered: isHovered, showAccent: true))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch source {
        case .foundation: Image(systemName: "apple.logo")
        case .local: Image(systemName: "internaldrive")
        case .remote: Image(systemName: "cloud")
        }
    }
}

// MARK: - Model Row Item

private struct ModelRowItem: View {
    let model: ModelOption
    let isSelected: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    if model.isVLM {
                        ModelSmallBadge(text: "Vision", icon: "eye")
                    }
                }

                if let description = model.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }

                if model.parameterCount != nil || model.quantization != nil {
                    HStack(spacing: 4) {
                        if let params = model.parameterCount {
                            ModelMetadataBadge(text: params, style: .accent)
                        }
                        if let quant = model.quantization {
                            ModelMetadataBadge(text: quant, style: .subtle)
                        }
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .modifier(ModelHoverRowStyle(isHovered: isHovered || isHighlighted || isSelected, showAccent: isSelected))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Shared Components

/// Hover background + border applied to row items and group headers.
private struct ModelHoverRowStyle: ViewModifier {
    let isHovered: Bool
    let showAccent: Bool

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.secondaryBackground.opacity(0.7) : Color.clear)
                    .overlay(
                        isHovered && showAccent
                            ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.accentColor.opacity(0.06), Color.clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            : nil
                    )
            )
            .overlay(
                isHovered
                    ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    showAccent ? theme.accentColor.opacity(0.2) : theme.glassEdgeLight.opacity(0.12),
                                    showAccent ? theme.accentColor.opacity(0.08) : theme.primaryBorder.opacity(0.08),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    : nil
            )
    }
}

/// Theme-aware metadata badge for parameter count and quantization.
private struct ModelMetadataBadge: View {
    enum Style {
        case accent, subtle
    }

    let text: String
    let style: Style

    @Environment(\.theme) private var theme

    private var badgeColor: Color {
        switch style {
        case .accent: return theme.accentColor
        case .subtle: return theme.secondaryText
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(badgeColor.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(badgeColor.opacity(0.12))
            )
    }
}

/// Small capsule badge with optional icon (e.g. "Vision" with eye icon).
private struct ModelSmallBadge: View {
    let text: String
    var icon: String? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(theme.accentColor.opacity(0.12))
                .overlay(Capsule().strokeBorder(theme.accentColor.opacity(0.15), lineWidth: 1))
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct ModelPickerView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var selected: String? = "foundation"

            var body: some View {
                ModelPickerView(
                    options: [
                        .foundation(),
                        ModelOption(
                            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                            displayName: "Llama 3.2 3B Instruct 4bit",
                            source: .local,
                            parameterCount: "3B",
                            quantization: "4-bit",
                            isVLM: false
                        ),
                        ModelOption(
                            id: "mlx-community/Qwen2-VL-7B-Instruct-4bit",
                            displayName: "Qwen2 VL 7B Instruct 4bit",
                            source: .local,
                            parameterCount: "7B",
                            quantization: "4-bit",
                            isVLM: true
                        ),
                        ModelOption(
                            id: "openai/gpt-4o",
                            displayName: "gpt-4o",
                            source: .remote(providerName: "OpenAI", providerId: UUID())
                        ),
                        ModelOption(
                            id: "openai/gpt-3.5-turbo",
                            displayName: "gpt-3.5-turbo",
                            source: .remote(providerName: "OpenAI", providerId: UUID())
                        ),
                    ],
                    selectedModel: $selected,
                    personaId: nil,
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
