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
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var filteredOptions: [ModelOption] {
        options.filter { $0.matches(searchQuery: searchText) }
    }

    private var groupedOptions: [(source: ModelOption.Source, models: [ModelOption])] {
        filteredOptions.groupedBySource()
    }

    /// Get the display name for the selected model
    private var selectedModelName: String? {
        guard let id = selectedModel else { return nil }
        return options.first { $0.id == id }?.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Search field
            searchField

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Model list
            if groupedOptions.isEmpty {
                emptyState
            } else {
                modelList
            }
        }
        .frame(width: 360, height: min(CGFloat(options.count * 52 + 140), 450))
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
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground)
                )
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
            Text("No models found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Model List

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedOptions, id: \.source) { group in
                    Section {
                        ForEach(group.models) { model in
                            ModelRowItem(
                                model: model,
                                isSelected: selectedModel == model.id,
                                onSelect: {
                                    selectedModel = model.id
                                    onDismiss()
                                }
                            )
                        }
                    } header: {
                        sectionHeader(for: group.source, count: group.models.count)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }

    private func sectionHeader(for source: ModelOption.Source, count: Int) -> some View {
        HStack(spacing: 6) {
            sourceIcon(for: source)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)

            Text(source.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)

            Text("(\(count))")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.primaryBackground.opacity(0.98))
    }

    @ViewBuilder
    private func sourceIcon(for source: ModelOption.Source) -> some View {
        switch source {
        case .foundation:
            Image(systemName: "apple.logo")
        case .local:
            Image(systemName: "internaldrive")
        case .remote:
            Image(systemName: "cloud")
        }
    }
}

// MARK: - Model Row Item

private struct ModelRowItem: View {
    let model: ModelOption
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator using theme accent
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.accentColor : theme.tertiaryText.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }

                // Model info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)

                        // VLM indicator
                        if model.isVLM {
                            Image(systemName: "eye")
                                .font(.system(size: 10))
                                .foregroundColor(theme.accentColor)
                                .help("Vision Language Model - supports images")
                        }
                    }

                    // Metadata badges
                    if model.parameterCount != nil || model.quantization != nil {
                        HStack(spacing: 4) {
                            if let params = model.parameterCount {
                                MetadataBadge(text: params, color: .blue)
                            }
                            if let quant = model.quantization {
                                MetadataBadge(text: quant, color: .purple)
                            }
                        }
                    }
                }

                Spacer()

                // Checkmark for selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered || isSelected ? theme.secondaryBackground.opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Metadata Badge

private struct MetadataBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
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
