import AppKit
import SwiftUI

private enum ChatPickerLayout {
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    static let columnWidth: CGFloat = 240
    static let optionsColumnWidth: CGFloat = 200
    static let columnSpacing: CGFloat = 20
    static let padding: CGFloat = 16
    /// Vertical gap between option sections in the third column.
    static let sectionSpacing: CGFloat = 10
    /// Height of a section sub-heading (e.g. "Reasoning Effort") in the
    /// options column, including its bottom gap.
    static let sectionTitleHeight: CGFloat = 22
    /// Estimated height of a help footnote under a section.
    static let sectionFootnoteHeight: CGFloat = 44
    /// Height of the quiet "Reset to default" link row.
    static let resetLinkHeight: CGFloat = 32
}

/// Presentation-only projection of the selected model's `ModelPickerOptionsControl`
/// into the picker's third column. Only presentation values survive while the
/// outgoing column is clipped away; actions always resolve against the
/// currently selected model's live control.
private struct ChatPickerOptionsSnapshot: Equatable {
    enum Action: Equatable {
        /// Semantic Thinking: `nil` clears the override (model default).
        case thinking(Bool?)
        case segment(optionID: String, segmentID: String)
        case toggle(optionID: String)
        case reset(optionID: String)
    }

    struct Row: Identifiable, Equatable {
        /// Doubles as the focus key.
        let id: String
        let label: String
        let help: String
        let selected: Bool
        let action: Action
    }

    struct Section: Identifiable, Equatable {
        let id: String
        /// Sub-heading above the rows; nil for a single self-labelled row
        /// (toggle options) where a heading would only repeat the label.
        let title: String?
        let rows: [Row]
        let footnote: String?
        /// Quiet "Reset to default" link shown when the user has an explicit
        /// value and the section has no dedicated Default row.
        let reset: Row?
    }

    let modelID: String?
    let sections: [Section]

    var focusKeys: [String] {
        sections.flatMap { section in section.rows.map(\.id) + (section.reset.map { [$0.id] } ?? []) }
    }

    func row(forKey key: String) -> Row? {
        for section in sections {
            if let row = section.rows.first(where: { $0.id == key }) { return row }
            if let reset = section.reset, reset.id == key { return reset }
        }
        return nil
    }

    static let thinkingSectionID = "thinking"

    static func make(modelID: String?, control: ModelPickerOptionsControl?) -> ChatPickerOptionsSnapshot? {
        guard let control, !control.isEmpty else { return nil }
        var sections: [Section] = []

        if let thinking = control.thinking {
            var rows: [Row] = []
            let explicitID: String? = thinking.isExplicit ? (thinking.isEnabled ? "on" : "off") : nil
            if thinking.supportsUnspecifiedDefault {
                rows.append(
                    Row(
                        id: "thinking:default",
                        label: L("Default"),
                        help: L("Use the model's own thinking default"),
                        selected: explicitID == nil,
                        action: .thinking(nil)
                    )
                )
            }
            // Without a Default row the effective on/off state is what shows.
            let shownID = explicitID ?? (thinking.isEnabled ? "on" : "off")
            let selectedID = thinking.supportsUnspecifiedDefault ? explicitID : shownID
            rows.append(
                Row(
                    id: "thinking:on",
                    label: L("On"),
                    help: L("Let the model reason before it answers"),
                    selected: selectedID == "on",
                    action: .thinking(true)
                )
            )
            rows.append(
                Row(
                    id: "thinking:off",
                    label: L("Off"),
                    help: L("Answer directly without a reasoning pass"),
                    selected: selectedID == "off",
                    action: .thinking(false)
                )
            )
            sections.append(
                Section(
                    id: thinkingSectionID,
                    title: L("Thinking"),
                    rows: rows,
                    footnote: nil,
                    reset: thinking.isExplicit && !thinking.supportsUnspecifiedDefault
                        ? Row(
                            id: "reset:thinking",
                            label: L("Reset to default"),
                            help: L("Reset to default"),
                            selected: false,
                            action: .thinking(nil)
                        )
                        : nil
                )
            )
        }

        for option in control.options {
            let isExplicit = control.values[option.id] != nil
            let resetRow =
                isExplicit
                ? Row(
                    id: "reset:\(option.id)",
                    label: L("Reset to default"),
                    help: L("Reset to default"),
                    selected: false,
                    action: .reset(optionID: option.id)
                )
                : nil
            switch option.kind {
            case .segmented(let segments):
                let selectedID = control.effectiveSegmentId(for: option)
                let rows = segments.map { segment in
                    Row(
                        id: "option:\(option.id):\(segment.id)",
                        label: segment.label,
                        help: option.id == "reasoningEffort"
                            ? control.capabilities?.levels.first { $0.id == segment.id }?.description ?? segment.label
                            : segment.label,
                        selected: selectedID == segment.id,
                        action: .segment(optionID: option.id, segmentID: segment.id)
                    )
                }
                sections.append(
                    Section(id: option.id, title: option.label, rows: rows, footnote: option.help, reset: resetRow)
                )
            case .toggle:
                let isOn = control.effectiveToggleValue(for: option)
                sections.append(
                    Section(
                        id: option.id,
                        title: nil,
                        rows: [
                            Row(
                                id: "option:\(option.id)",
                                label: option.label,
                                help: option.help ?? option.label,
                                selected: isOn,
                                action: .toggle(optionID: option.id)
                            )
                        ],
                        footnote: option.help,
                        reset: resetRow
                    )
                )
            }
        }

        guard !sections.isEmpty else { return nil }
        return ChatPickerOptionsSnapshot(modelID: modelID, sections: sections)
    }

    /// Estimated rendered height of the column body (below the column
    /// heading), for the card frame.
    var estimatedHeight: CGFloat {
        var total: CGFloat = 0
        for (index, section) in sections.enumerated() {
            if index > 0 { total += ChatPickerLayout.sectionSpacing }
            if section.title != nil { total += ChatPickerLayout.sectionTitleHeight }
            total += CGFloat(section.rows.count) * ChatPickerLayout.rowHeight
                + CGFloat(max(0, section.rows.count - 1)) * ChatPickerLayout.rowSpacing
            if section.footnote != nil { total += ChatPickerLayout.sectionFootnoteHeight }
            if section.reset != nil { total += ChatPickerLayout.resetLinkHeight }
        }
        return total
    }
}

/// The chat-only, column-based picker. Selection and option persistence remain
/// owned by FloatingInputCard; browsing another provider never changes a model.
///
/// Every option the selected model exposes (Thinking, reasoning level,
/// speculative depth, profile toggles) renders in one consistent third column
/// using the same rows as Provider and Model, so there is no separate options
/// page.
struct ChatModelPickerCard: View {
    let providers: [ChatModelPickerProvider]
    @Binding var selectedModel: String?
    let optionsControl: ModelPickerOptionsControl?
    let onExploreLocal: () -> Void
    let onExploreCloud: () -> Void
    let onSizeChange: (CGSize) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.anchoredCardMetrics) private var cardMetrics
    @State private var browsedProviderID: String?
    @State private var search = ""
    @ObservedObject var favorites = FavoriteModelsStore.shared
    @FocusState private var focus: String?
    @State private var keyboardNavigation = false
    @State private var retainedOptions: ChatPickerOptionsSnapshot?
    @State private var visibleOptionsWidth: CGFloat = 0

    private var provider: ChatModelPickerProvider? {
        providers.first { $0.id == browsedProviderID }
            ?? providers.first { $0.models.contains { $0.id == selectedModel } }
            ?? providers.first { $0.isActive }
    }

    private var models: [ModelPickerItem] {
        guard let provider else { return [] }
        return provider.models.filter {
            search.isEmpty || $0.displayName.localizedStandardContains(search)
                || $0.id.localizedStandardContains(search)
        }
    }

    private var control: ModelPickerOptionsControl? {
        guard provider?.models.contains(where: { $0.id == selectedModel }) == true else { return nil }
        return optionsControl
    }

    private var columnWidth: CGFloat {
        guard let availableWidth = cardMetrics?.availableSize.width else { return ChatPickerLayout.columnWidth }
        let threeColumnChrome = 2 * ChatPickerLayout.padding + 2 * ChatPickerLayout.columnSpacing
        let fullColumnsWidth = 2 * ChatPickerLayout.columnWidth + ChatPickerLayout.optionsColumnWidth
        let scale = min(1, max(0, availableWidth - threeColumnChrome) / fullColumnsWidth)
        return max(1, ChatPickerLayout.columnWidth * scale)
    }

    private var optionsColumnWidth: CGFloat {
        columnWidth * ChatPickerLayout.optionsColumnWidth / ChatPickerLayout.columnWidth
    }

    private var twoColumnWidth: CGFloat {
        2 * columnWidth + ChatPickerLayout.columnSpacing + 2 * ChatPickerLayout.padding
    }

    private var optionsAreRevealed: Bool {
        currentOptions != nil
            && visibleOptionsWidth >= optionsColumnWidth + ChatPickerLayout.columnSpacing - 0.5
    }

    private var currentOptions: ChatPickerOptionsSnapshot? {
        ChatPickerOptionsSnapshot.make(modelID: selectedModel, control: control)
    }

    static func initialSize(
        providers: [ChatModelPickerProvider],
        selectedModel: String?,
        optionsControl: ModelPickerOptionsControl?
    ) -> CGSize {
        let provider = providers.first { $0.models.contains { $0.id == selectedModel } }
            ?? providers.first { $0.isActive }
        let control = provider?.models.contains { $0.id == selectedModel } == true ? optionsControl : nil
        return cardSize(provider: provider, providerCount: providers.count,
                        options: ChatPickerOptionsSnapshot.make(modelID: selectedModel, control: control),
                        columnWidth: ChatPickerLayout.columnWidth,
                        optionsColumnWidth: ChatPickerLayout.optionsColumnWidth)
    }

    private var preferredSize: CGSize {
        Self.cardSize(provider: provider, providerCount: providers.count, options: currentOptions,
                      columnWidth: columnWidth, optionsColumnWidth: optionsColumnWidth)
    }

    private static func cardSize(
        provider: ChatModelPickerProvider?,
        providerCount: Int,
        options: ChatPickerOptionsSnapshot?,
        columnWidth: CGFloat,
        optionsColumnWidth: CGFloat
    ) -> CGSize {
        let twoColumnWidth = 2 * columnWidth + ChatPickerLayout.columnSpacing + 2 * ChatPickerLayout.padding
        let count = min(8, max(providerCount, provider?.models.count ?? 0))
        let modelFooter = provider?.isLocal == true || provider?.isOsaurusCloud == true ? 44 : 0
        let searchHeight = (provider?.models.count ?? 0) > 10 ? 38 : 0
        let rowsHeight = CGFloat(count) * ChatPickerLayout.rowHeight
            + CGFloat(max(0, count - 1)) * ChatPickerLayout.rowSpacing
        let listHeight = rowsHeight + CGFloat(modelFooter + searchHeight)
        let optionsHeight = options?.estimatedHeight ?? 0
        return CGSize(width: twoColumnWidth + (options == nil ? 0 : optionsColumnWidth + ChatPickerLayout.columnSpacing),
                      height: min(480, max(236, 68 + max(listHeight, optionsHeight))))
    }

    var body: some View {
        columns
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(theme.borderOpacity), lineWidth: theme.defaultBorderWidth)
            }
            .font(theme.font(size: CGFloat(theme.bodySize)))
            .foregroundStyle(theme.primaryText)
            .contentShape(Rectangle())
            .onAppear {
                keyboardNavigation = NSApp.currentEvent?.type == .keyDown
                reportSize()
                focus = provider.map { "provider:\($0.id)" } ?? providers.first.map { "provider:\($0.id)" }
            }
            .onChange(of: preferredSize) { _, _ in reportSize() }
            .onChange(of: currentOptions, initial: true) { previous, current in
                if let current {
                    retainedOptions = current
                } else {
                    retainedOptions = visibleOptionsWidth > 0 ? previous ?? retainedOptions : nil
                }
                restoreOptionsFocusIfNeeded(current)
            }
            .onChange(of: optionsAreRevealed) { _, revealed in
                if !revealed { restoreOptionsFocusIfNeeded(nil) }
            }
            .onChange(of: providers) { _, updated in
                if !updated.contains(where: { $0.id == browsedProviderID && $0.isActive }) {
                    browsedProviderID = nil
                }
            }
            .onKeyPress(phases: .down) { _ in
                keyboardNavigation = true
                return .ignored
            }
            .onMoveCommand { direction in
                keyboardNavigation = true
                moveFocus(direction)
            }
            .accessibilityIdentifier("chat-model-picker")
    }

    private var columns: some View {
        GeometryReader { geometry in
            let slotWidth = min(optionsColumnWidth + ChatPickerLayout.columnSpacing,
                                max(0, geometry.size.width - twoColumnWidth))
            HStack(alignment: .top, spacing: 0) {
                providerColumn.frame(width: columnWidth)
                Color.clear.frame(width: ChatPickerLayout.columnSpacing).accessibilityHidden(true)
                modelColumn.frame(width: columnWidth)
                optionsSlot(width: slotWidth)
            }
            .padding(ChatPickerLayout.padding)
            .onChange(of: slotWidth, initial: true) { _, width in
                visibleOptionsWidth = width
                if width == 0, currentOptions == nil { retainedOptions = nil }
            }
        }
    }

    private func optionsSlot(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: ChatPickerLayout.columnSpacing).accessibilityHidden(true)
            Group {
                if let snapshot = currentOptions ?? retainedOptions {
                    optionsColumn(snapshot)
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: optionsColumnWidth)
        }
        .frame(width: optionsColumnWidth + ChatPickerLayout.columnSpacing, alignment: .leading)
        .frame(width: width, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .disabled(!optionsAreRevealed)
        .allowsHitTesting(optionsAreRevealed)
        .accessibilityHidden(!optionsAreRevealed)
    }

    private static func isOptionsFocusKey(_ key: String) -> Bool {
        key.hasPrefix("thinking:") || key.hasPrefix("option:") || key.hasPrefix("reset:")
    }

    private func restoreOptionsFocusIfNeeded(_ snapshot: ChatPickerOptionsSnapshot?) {
        guard let focus, Self.isOptionsFocusKey(focus) else { return }
        guard snapshot?.row(forKey: focus) == nil else { return }
        if let selectedModel, models.contains(where: { $0.id == selectedModel }) {
            self.focus = "model:\(selectedModel)"
        } else {
            self.focus = models.first.map { "model:\($0.id)" } ?? provider.map { "provider:\($0.id)" }
        }
    }

    private func reportSize() {
        let size = preferredSize
        DispatchQueue.main.async { onSizeChange(size) }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(theme.font(size: CGFloat(theme.smallBodySize) + 2))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(L("Provider"))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatPickerLayout.rowSpacing) {
                        ForEach(providers) { item in
                            let key = "provider:\(item.id)"
                            let title = item.isLocal ? L("Local") : item.title
                            ChatPickerRow(
                                title: title,
                                selected: item.id == provider?.id,
                                muted: !item.isActive,
                                explore: !item.isActive,
                                focused: keyboardNavigation && focus == key,
                                icon: { providerIcon(item) },
                                action: { chooseProvider(item) }
                            )
                            .focused($focus, equals: key)
                            .id(key)
                            .accessibilityLabel(item.isActive ? title : "\(L("Explore")) \(title)")
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .onChange(of: focus) { _, key in
                    if let key, key.hasPrefix("provider:") { proxy.scrollTo(key) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(L("Model"))
            if (provider?.models.count ?? 0) > 10 {
                TextField(L("Find a model"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L("Find a model"))
                    .focused($focus, equals: "search")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatPickerLayout.rowSpacing) {
                        ForEach(models) { model in
                            let key = "model:\(model.id)"
                            HStack(spacing: 0) {
                                ChatPickerRow(title: model.displayName, selected: model.id == selectedModel,
                                              focused: keyboardNavigation && focus == key, icon: { EmptyView() }) {
                                    selectedModel = model.id
                                }
                                .focused($focus, equals: key)
                                if provider?.isOsaurusCloud == true {
                                    let saved = favorites.isFavorite(model.favoriteKey)
                                    Button {
                                        favorites.toggle(model.favoriteKey)
                                    } label: {
                                        Image(systemName: saved ? "star.fill" : "star")
                                            .font(.system(size: 13))
                                            .frame(width: 28, height: ChatPickerLayout.rowHeight)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(ModelFavoriteButtonStyle())
                                    .focusable()
                                    .focusEffectDisabled()
                                    .focused($focus, equals: "favorite:\(model.id)")
                                    .overlay {
                                        if keyboardNavigation && focus == "favorite:\(model.id)" {
                                            VStack {
                                                Spacer()
                                                Rectangle().fill(theme.secondaryText).frame(height: 1).padding(.horizontal, 6)
                                            }
                                        }
                                    }
                                    .onKeyPress(.return) { favorites.toggle(model.favoriteKey); return .handled }
                                    .accessibilityLabel("\(saved ? L("Remove from favorites") : L("Add to favorites")): \(model.displayName)")
                                    .help(saved ? L("Remove from favorites") : L("Add to favorites"))
                                }
                            }
                            .id(key)
                            .help(model.displayName)
                        }
                        if models.isEmpty {
                            Text(search.isEmpty ? L("Choose a provider to browse models.") : L("No matching models. Try another name."))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 12)
                        }
                        if let provider, provider.isLocal || provider.isOsaurusCloud {
                            footerButton(L("More models"), key: "more", icon: "arrow.forward") {
                                provider.isLocal ? onExploreLocal() : onExploreCloud()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(provider.isLocal ? L("More local models") : L("More Osaurus Cloud models"))
                            .id("more")
                        }
                    }
                }
                .onAppear {
                    if let selectedModel { proxy.scrollTo("model:\(selectedModel)", anchor: .center) }
                }
                .onChange(of: focus) { _, key in
                    if let key {
                        if key.hasPrefix("model:") || key == "more" { proxy.scrollTo(key) }
                        if key.hasPrefix("favorite:") { proxy.scrollTo("model:" + key.dropFirst(9)) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func optionsColumn(_ snapshot: ChatPickerOptionsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(L("Model options"))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ChatPickerLayout.sectionSpacing) {
                        ForEach(snapshot.sections) { section in
                            optionsSection(section, in: snapshot)
                        }
                    }
                }
                .onChange(of: focus) { _, key in
                    if let key, Self.isOptionsFocusKey(key) { proxy.scrollTo(key) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func optionsSection(
        _ section: ChatPickerOptionsSnapshot.Section,
        in snapshot: ChatPickerOptionsSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title {
                Text(title)
                    .font(theme.font(size: CGFloat(theme.smallBodySize) - 1, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: ChatPickerLayout.sectionTitleHeight, alignment: .bottomLeading)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: ChatPickerLayout.rowSpacing) {
                ForEach(section.rows) { row in
                    ChatPickerRow(title: row.label,
                                  selected: row.selected,
                                  focused: keyboardNavigation && focus == row.id, icon: { EmptyView() }) {
                        perform(row.action, displayedFor: snapshot)
                    }
                    .focused($focus, equals: row.id)
                    .id(row.id)
                    .help(row.help)
                }
            }
            if let footnote = section.footnote {
                Text(footnote)
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            if let reset = section.reset {
                footerButton(reset.label, key: reset.id, icon: "arrow.uturn.backward") {
                    perform(reset.action, displayedFor: snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(reset.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title ?? section.rows.first?.label ?? "")
    }

    /// Apply an options-column action against the live control. Guarded so a
    /// retained (clipping-away) snapshot for a previous model can never write
    /// into the newly selected model's options.
    private func perform(_ action: ChatPickerOptionsSnapshot.Action, displayedFor snapshot: ChatPickerOptionsSnapshot) {
        guard optionsAreRevealed, let control, selectedModel == snapshot.modelID else { return }
        switch action {
        case .thinking(let enabled):
            guard let thinking = control.thinking else { return }
            thinking.onSetEnabled(enabled)
        case .segment(let optionID, let segmentID):
            guard let option = control.options.first(where: { $0.id == optionID }),
                case .segmented(let segments) = option.kind,
                segments.contains(where: { $0.id == segmentID })
            else { return }
            control.onChange(optionID, .string(segmentID))
        case .toggle(let optionID):
            guard let option = control.options.first(where: { $0.id == optionID }),
                case .toggle = option.kind
            else { return }
            control.onChange(optionID, .bool(!control.effectiveToggleValue(for: option)))
        case .reset(let optionID):
            guard control.options.contains(where: { $0.id == optionID }) else { return }
            control.onChange(optionID, nil)
        }
    }

    private func footerButton(_ title: String, key: String, icon: String, action: @escaping () -> Void) -> some View {
        ChatPickerTextLink(title: title, icon: icon, focused: keyboardNavigation && focus == key, action: action)
            .focused($focus, equals: key)
    }

    private func chooseProvider(_ item: ChatModelPickerProvider) {
        guard item.isActive else {
            item.isLocal ? onExploreLocal() : onExploreCloud()
            return
        }
        browsedProviderID = item.id
        search = ""
    }

    @ViewBuilder private func providerIcon(_ provider: ChatModelPickerProvider) -> some View {
        if provider.isLocal {
            Image(systemName: "desktopcomputer").frame(width: 16)
        } else if provider.isOsaurusCloud {
            Image("osaurus-logo", bundle: .module).resizable().renderingMode(.template).scaledToFit().frame(width: 16, height: 16)
        } else {
            let name = provider.title.lowercased()
            if name.contains("openai") || name.contains("chatgpt") {
                Image("provider-logo-openai", bundle: .module).resizable().scaledToFit().frame(width: 16, height: 16)
            } else if name.contains("claude") || name.contains("anthropic") {
                Image("provider-logo-anthropic", bundle: .module).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: "network").frame(width: 16)
            }
        }
    }

    private var focusColumns: [[String]] {
        var modelKeys = models.flatMap { model in
            provider?.isOsaurusCloud == true
                ? ["model:\(model.id)", "favorite:\(model.id)"] : ["model:\(model.id)"]
        }
        if provider?.isLocal == true || provider?.isOsaurusCloud == true { modelKeys.append("more") }
        var columns = [providers.map { "provider:\($0.id)" }, modelKeys]
        if optionsAreRevealed, let currentOptions {
            columns.append(currentOptions.focusKeys)
        }
        return columns
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard focus != "search" else { return }
        let columns = focusColumns
        let column = columns.firstIndex { $0.contains(focus ?? "") } ?? 0
        let row = columns[column].firstIndex(of: focus ?? "") ?? 0
        let logicalDirection: MoveCommandDirection
        if layoutDirection == .rightToLeft && direction == .left { logicalDirection = .right }
        else if layoutDirection == .rightToLeft && direction == .right { logicalDirection = .left }
        else { logicalDirection = direction }
        switch logicalDirection {
        case .up: if !columns[column].isEmpty { focus = columns[column][max(0, row - 1)] }
        case .down: if !columns[column].isEmpty { focus = columns[column][min(columns[column].count - 1, row + 1)] }
        case .left: focus = columns[max(0, column - 1)].first
        case .right: focus = columns[min(columns.count - 1, column + 1)].first
        default: break
        }
    }
}

/// Quiet inline links follow the last model, with the arrow beside the text.
private struct ChatPickerTextLink: View {
    let title: String
    let icon: String
    let focused: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    private var subduedTextColor: Color { theme.isDark ? theme.tertiaryText : theme.secondaryText }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).underline(hovered)
                    .foregroundStyle(hovered ? theme.primaryText : subduedTextColor)
                Image(systemName: icon).font(.system(size: 11)).accessibilityHidden(true)
            }
            .font(theme.font(size: CGFloat(theme.smallBodySize) - 1, weight: .regular))
            .foregroundStyle(hovered ? theme.primaryText : theme.tertiaryText)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if focused { Rectangle().fill(theme.secondaryText).frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) { action(); return .handled }
    }
}

/// A native button supplies activation and accessibility; focus and hover use
/// the same row shape, with a neutral keyboard underline distinct from selection.
private struct ChatPickerRow<Icon: View>: View {
    let title: String
    let selected: Bool
    var muted = false
    var explore = false
    var focused = false
    @ViewBuilder let icon: () -> Icon
    var trailingSymbol: String? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    private var subduedTextColor: Color { theme.isDark ? theme.tertiaryText : theme.secondaryText }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon().accessibilityHidden(true)
                Text(title)
                    .font(theme.font(size: CGFloat(theme.smallBodySize)))
                    .foregroundStyle(muted && !hovered && !focused ? subduedTextColor : theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if explore && (hovered || focused) {
                    Text("Explore", bundle: .module)
                        .font(theme.font(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.primaryBackground, in: Capsule())
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                } else if let trailingSymbol {
                    Image(systemName: trailingSymbol).font(.system(size: 11)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(muted && !hovered && !focused ? theme.tertiaryText : theme.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: ChatPickerLayout.rowHeight)
            .contentShape(Rectangle())
            .background(selected || hovered || focused ? theme.tertiaryBackground : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if focused {
                    VStack {
                        Spacer()
                        Rectangle().fill(theme.secondaryText).frame(height: 1).padding(.horizontal, 12)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) { action(); return .handled }
        .accessibilityValue(selected ? L("Selected") : "")
        .help(title)
    }
}
