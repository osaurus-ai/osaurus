import AppKit
import SwiftUI

@MainActor private enum ChatPickerLayout {
    static var rowHeight: CGFloat { ModelPickerInspectionStyle.rowHeight(ThemeManager.shared.currentTheme) }
    static var rowSpacing: CGFloat { ModelPickerInspectionStyle.metric("elements.layout.rowGap", PickerCardMetrics.rowSpacing, ThemeManager.shared.currentTheme) }
    static let columnWidth: CGFloat = 240
    static let optionsColumnWidth: CGFloat = 200
    static var columnSpacing: CGFloat { ModelPickerInspectionStyle.metric("elements.layout.columnGap", ThemeManager.shared.currentTheme.space.s20, ThemeManager.shared.currentTheme) }
    static let providerIconSize: CGFloat = 16
    static var padding: CGFloat { ModelPickerInspectionStyle.metric("padding", PickerCardMetrics.padding, ThemeManager.shared.currentTheme) }
    /// Vertical gap between option sections in the third column.
    static var sectionSpacing: CGFloat { ModelPickerInspectionStyle.metric("elements.layout.sectionGap", PickerCardMetrics.sectionSpacing, ThemeManager.shared.currentTheme) }
    /// Height of a section sub-heading (e.g. "Reasoning Effort") in the
    /// options column, including its bottom gap.
    static let sectionTitleHeight = PickerCardMetrics.sectionTitleHeight
    /// Estimated height of a help footnote under a section.
    static let sectionFootnoteHeight: CGFloat = 44
    /// Height of the quiet "Reset to default" link row.
    static let resetLinkHeight: CGFloat = 32
}

/// Presentation-only projection of the selected model's `ModelPickerOptionsControl`
/// into the picker's third column. Only presentation values survive while the
/// outgoing column is clipped away; actions always resolve against the
/// currently selected model's live control.
struct ChatPickerOptionsSnapshot: Equatable {
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
            let selectedID = thinking.selectedMode
            if thinking.supportsUnspecifiedDefault {
                rows.append(
                    Row(
                        id: "thinking:default",
                        label: L("Default"),
                        help: L("Use the model's own thinking default"),
                        selected: selectedID == "default",
                        action: .thinking(nil)
                    )
                )
            }
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
            // On/Off is the coarsest reasoning effort; keep "Thinking" only
            // when a real effort option sits beside it, so titles stay unique.
            let hasEffortOption = control.options.contains { $0.id == "reasoningEffort" }
            sections.append(
                Section(
                    id: thinkingSectionID,
                    title: hasEffortOption ? L("thinking.mode.label") : L("Reasoning Effort"),
                    rows: rows,
                    footnote: control.reasoningValidationMessage,
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
                || (option.id == "reasoningEffort" && control.reasoningValidationMessage != nil)
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
                let hasDefaultSegment = segments.contains { $0.id == ModelOptionSegment.defaultID }
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
                    Section(id: option.id, title: option.label, rows: rows,
                            footnote: option.id == "reasoningEffort" && control.thinking == nil
                                ? control.reasoningValidationMessage ?? option.help : option.help,
                            reset: hasDefaultSegment ? nil : resetRow)
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

        if let message = control.reasoningValidationMessage,
            control.thinking == nil,
            !control.options.contains(where: { $0.id == "reasoningEffort" })
        {
            sections.insert(Section(id: "reasoning-unsupported", title: L("Reasoning Effort"),
                rows: [], footnote: message,
                reset: Row(id: "reset:reasoningEffort", label: L("Reset to default"),
                    help: L("Reset to default"), selected: false, action: .reset(optionID: "reasoningEffort"))), at: 0)
        }

        guard !sections.isEmpty else { return nil }
        return ChatPickerOptionsSnapshot(modelID: modelID, sections: sections)
    }

    /// Estimated rendered height of the column body (below the column
    /// heading), for the card frame.
    @MainActor var estimatedHeight: CGFloat {
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
    /// The harness row the agent runs on; nil on the built-in loop, where
    /// `selectedModel` is the live choice.
    var selectedHarnessID: String? = nil
    /// Options for the selected harness row (Claude Code's effort). Shown in
    /// place of `optionsControl`, which belongs to the built-in model.
    var harnessOptionsControl: ModelPickerOptionsControl? = nil
    /// While a turn runs, rows that would move the agent to another runtime
    /// are disabled; the running turn keeps its process.
    var runtimeSwitchLocked = false
    /// A harness row was picked, or nil when a model row moves the agent
    /// back to the built-in loop.
    var onSelectHarness: (ChatHarnessPickerOption?) -> Void = { _ in }
    let onExploreLocal: () -> Void
    let onExploreCloud: () -> Void
    let onSizeChange: (CGSize) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var inspectorEnabled
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
            ?? Self.selectedProvider(in: providers, selectedModel: selectedModel, selectedHarnessID: selectedHarnessID)
            ?? providers.first { $0.isActive }
    }

    private static func selectedProvider(
        in providers: [ChatModelPickerProvider],
        selectedModel: String?,
        selectedHarnessID: String?
    ) -> ChatModelPickerProvider? {
        if let selectedHarnessID {
            return providers.first { $0.harnessOptions.contains { $0.id == selectedHarnessID } }
        }
        return providers.first { $0.models.contains { $0.id == selectedModel } }
    }

    private var harnessOptions: [ChatHarnessPickerOption] {
        provider?.harnessOptions ?? []
    }

    /// A model row is the live choice only on the built-in loop.
    private var builtInSelectedModel: String? {
        selectedHarnessID == nil ? selectedModel : nil
    }

    private var models: [ModelPickerItem] {
        guard let provider else { return [] }
        return provider.models.filter {
            search.isEmpty || $0.displayName.localizedStandardContains(search)
                || $0.id.localizedStandardContains(search)
        }
    }

    private var control: ModelPickerOptionsControl? {
        Self.visibleControl(
            provider: provider,
            selectedModel: selectedModel,
            selectedHarnessID: selectedHarnessID,
            optionsControl: optionsControl,
            harnessOptionsControl: harnessOptionsControl
        )
    }

    /// Options show only beside the live choice: the harness row the agent
    /// runs on, or the built-in model when it runs on none.
    private static func visibleControl(
        provider: ChatModelPickerProvider?,
        selectedModel: String?,
        selectedHarnessID: String?,
        optionsControl: ModelPickerOptionsControl?,
        harnessOptionsControl: ModelPickerOptionsControl?
    ) -> ModelPickerOptionsControl? {
        if let selectedHarnessID {
            guard provider?.harnessOptions.contains(where: { $0.id == selectedHarnessID }) == true else { return nil }
            return harnessOptionsControl
        }
        guard provider?.models.contains(where: { $0.id == selectedModel }) == true else { return nil }
        return optionsControl
    }

    /// The row the options column belongs to, so a retained snapshot can't
    /// write into a different row's options.
    private var optionsOwnerID: String? {
        selectedHarnessID ?? selectedModel
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
        ChatPickerOptionsSnapshot.make(modelID: optionsOwnerID, control: control)
    }

    static func initialSize(
        providers: [ChatModelPickerProvider],
        selectedModel: String?,
        optionsControl: ModelPickerOptionsControl?,
        selectedHarnessID: String? = nil,
        harnessOptionsControl: ModelPickerOptionsControl? = nil
    ) -> CGSize {
        let provider = selectedProvider(in: providers, selectedModel: selectedModel, selectedHarnessID: selectedHarnessID)
            ?? providers.first { $0.isActive }
        let control = visibleControl(
            provider: provider,
            selectedModel: selectedModel,
            selectedHarnessID: selectedHarnessID,
            optionsControl: optionsControl,
            harnessOptionsControl: harnessOptionsControl
        )
        return cardSize(provider: provider, providerCount: providers.count,
                        options: ChatPickerOptionsSnapshot.make(modelID: selectedHarnessID ?? selectedModel, control: control),
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
        let count = min(8, max(providerCount, provider?.rowCount ?? 0))
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
            .pickerCardSurface(assignmentFamily: 26)
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
            HStack(alignment: .top, spacing: theme.space.s0) {
                providerColumn.frame(width: columnWidth)
                Color.clear.frame(width: ChatPickerLayout.columnSpacing).nativeCatalogTarget(["component.library.26.elements.layout.columnGap"], "Between picker columns").accessibilityHidden(true)
                modelColumn.frame(width: columnWidth)
                optionsSlot(width: slotWidth)
            }
            .padding(ChatPickerLayout.padding)
            .nativeCatalogTarget(["component.library.26.elements.container.padding"], "Picker inner padding")
            .onChange(of: slotWidth, initial: true) { _, width in
                visibleOptionsWidth = width
                if width == 0, currentOptions == nil { retainedOptions = nil }
            }
        }
    }

    private func optionsSlot(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: theme.space.s0) {
            Color.clear.frame(width: ChatPickerLayout.columnSpacing).nativeCatalogTarget(["component.library.26.elements.layout.columnGap"], "Between picker columns").accessibilityHidden(true)
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
        if let selectedHarnessID, harnessOptions.contains(where: { $0.id == selectedHarnessID }) {
            self.focus = selectedHarnessID
        } else if let selectedModel, models.contains(where: { $0.id == selectedModel }) {
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
        PickerCardHeading(title: title, assignmentFamily: 26) { EmptyView() }
            .padding(.bottom, ModelPickerInspectionStyle.metric("elements.layout.headingGap", theme.space.s8, theme))
            .nativeCatalogTarget(["component.library.26.elements.heading.heading", "component.library.26.elements.body.foreground", "component.library.26.elements.layout.headingGap"], "\(title) heading → content")
    }

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
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

    private struct ModelListIdentity: Hashable {
        let providerID: String?
        let search: String
    }

    private var modelColumn: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            heading(L("Model"))
            if (provider?.models.count ?? 0) > 10 {
                SearchField(text: $search, placeholder: "Find a model", fillsAvailableWidth: true,
                    onFocusChange: { focused in
                        if focused { focus = "search" }
                        else if focus == "search" { focus = nil }
                    })
                    .nativeCatalogTarget(["background", "border", "foreground", "placeholder", "text", "radius", "paddingX", "paddingY", "borderWidth"].map { "component.library.26.elements.input." + $0 }, "Model search field")
                    .padding(.bottom, ModelPickerInspectionStyle.metric("elements.layout.searchResultsGap", theme.space.s8, theme))
                    .nativeCatalogTarget(["component.library.26.elements.layout.searchResultsGap"], "Search field → results")
                    .accessibilityLabel(L("Find a model"))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatPickerLayout.rowSpacing) {
                        ForEach(harnessOptions) { option in
                            let selected = option.id == selectedHarnessID
                            let locked = runtimeSwitchLocked && !selected
                            ChatPickerRow(title: option.title, selected: selected, muted: locked,
                                          focused: keyboardNavigation && focus == option.id, icon: { EmptyView() }) {
                                guard !locked, !selected else { return }
                                onSelectHarness(option)
                            }
                            .disabled(locked)
                            .focused($focus, equals: option.id)
                            .id(option.id)
                            .help(locked ? L("Wait for the current reply to finish before switching runtimes.") : option.title)
                        }
                        ForEach(models) { model in
                            let key = "model:\(model.id)"
                            let locked = runtimeSwitchLocked && selectedHarnessID != nil
                            HStack(spacing: theme.space.s0) {
                                ChatPickerRow(title: model.displayName, selected: model.id == builtInSelectedModel,
                                              muted: locked,
                                              focused: keyboardNavigation && focus == key, icon: { EmptyView() }) {
                                    guard !locked else { return }
                                    if selectedHarnessID != nil { onSelectHarness(nil) }
                                    selectedModel = model.id
                                }
                                .disabled(locked)
                                .focused($focus, equals: key)
                                if provider?.isOsaurusCloud == true {
                                    let saved = favorites.isFavorite(model.favoriteKey)
                                    Button {
                                        favorites.toggle(model.favoriteKey)
                                    } label: {
                                        Image(systemName: saved ? "star.fill" : "star")
                                            .glyphSize(.label)
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
                                                Rectangle().fill(theme.text.secondary).frame(height: 1).padding(
                                                    .horizontal,
                                                    6
                                                )
                                            }
                                        }
                                    }
                                    .onKeyPress(.return) {
                                        guard inspectorEnabled else { return .ignored }
                                        favorites.toggle(model.favoriteKey); return .handled
                                    }
                                    .accessibilityLabel("\(saved ? L("Remove from favorites") : L("Add to favorites")): \(model.displayName)")
                                    .help(saved ? L("Remove from favorites") : L("Add to favorites"))
                                }
                            }
                            .id(key)
                            .help(model.displayName)
                        }
                        if models.isEmpty && harnessOptions.isEmpty {
                            Text(
                                search.isEmpty
                                    ? L("Choose a provider to browse models.")
                                    : L("No matching models. Try another name.")
                            )
                            .modelPickerTextStyle(.bodySmall, property: "text")
                            .modelPickerInk("secondary", fallback: theme.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, theme.space.s12)
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
                // Filtering can remove the selected row far below the first match.
                // Reset the scroll container so LazyVStack cannot retain an offset
                // beyond the new result set and display an empty model column.
                .id(ModelListIdentity(providerID: provider?.id, search: search))
                .onAppear {
                    if search.isEmpty, let selectedModel,
                        models.contains(where: { $0.id == selectedModel }) {
                        proxy.scrollTo("model:\(selectedModel)", anchor: .center)
                    }
                }
                .onChange(of: focus) { _, key in
                    if let key {
                        if key.hasPrefix("model:") || key.hasPrefix("harness:") || key == "more" { proxy.scrollTo(key) }
                        if key.hasPrefix("favorite:") { proxy.scrollTo("model:" + key.dropFirst(9)) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func optionsColumn(_ snapshot: ChatPickerOptionsSnapshot) -> some View {
        // A lone titled section names the column itself instead of nesting
        // under a generic heading.
        let promotedTitle = snapshot.sections.count == 1 ? snapshot.sections.first?.title : nil
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            heading(promotedTitle ?? L("Model options"))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ChatPickerLayout.sectionSpacing) {
                        ForEach(snapshot.sections) { section in
                            optionsSection(section, in: snapshot, showsTitle: promotedTitle == nil)
                                .nativeCatalogTarget(["component.library.26.elements.layout.sectionGap"], "Between option sections")
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
        in snapshot: ChatPickerOptionsSnapshot,
        showsTitle: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            if showsTitle, let title = section.title {
                PickerCardSectionTitle(title: title, assignmentFamily: 26) { EmptyView() }
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
                PickerCardFootnote(text: footnote, assignmentFamily: 26)
                    .padding(.top, theme.space.s6)
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
        guard optionsAreRevealed, let control, optionsOwnerID == snapshot.modelID else { return }
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
            guard control.canResetOption(optionID) else { return }
            control.onChange(optionID, nil)
        }
    }

    private func footerButton(_ title: String, key: String, icon: String, action: @escaping () -> Void) -> some View {
        PickerCardTextLink(title: title, icon: icon, focused: keyboardNavigation && focus == key, assignmentFamily: 26, action: action)
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
        if case .harness(let kind) = provider.kind {
            if kind == .claudeCode {
                Image("provider-logo-anthropic", bundle: .module).resizable().scaledToFit().frame(width: ChatPickerLayout.providerIconSize, height: ChatPickerLayout.providerIconSize)
            } else {
                Image(systemName: "terminal").frame(width: ChatPickerLayout.providerIconSize)
            }
        } else if provider.isLocal {
            Image(systemName: "desktopcomputer").frame(width: ChatPickerLayout.providerIconSize)
        } else if provider.isOsaurusCloud {
            Image("osaurus-logo", bundle: .module).resizable().renderingMode(.template).scaledToFit().frame(width: ChatPickerLayout.providerIconSize, height: ChatPickerLayout.providerIconSize)
        } else {
            let name = provider.title.lowercased()
            if name.contains("openai") || name.contains("chatgpt") {
                Image("provider-logo-openai", bundle: .module).resizable().scaledToFit().frame(width: ChatPickerLayout.providerIconSize, height: ChatPickerLayout.providerIconSize)
            } else if name.contains("claude") || name.contains("anthropic") {
                Image("provider-logo-anthropic", bundle: .module).resizable().scaledToFit().frame(width: ChatPickerLayout.providerIconSize, height: ChatPickerLayout.providerIconSize)
            } else {
                Image(systemName: "network").frame(width: ChatPickerLayout.providerIconSize)
            }
        }
    }

    private var focusColumns: [[String]] {
        var modelKeys = harnessOptions.map(\.id) + models.flatMap { model in
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
    @Environment(\.isEnabled) private var inspectorEnabled
    @State private var hovered = false

    private var subduedTextColor: Color { theme.isDark ? theme.text.tertiary : theme.text.secondary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ModelPickerInspectionStyle.metric("elements.row.gap", theme.space.s8, theme)) {
                icon().accessibilityHidden(true)
                Text(title)
                    .modelPickerTextStyle(.bodySmall, property: "elements.row.label")
                    .modelPickerInk("elements.row.foreground", fallback: muted && !hovered && !focused ? subduedTextColor : theme.text.primary, muted: muted && !hovered && !focused)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if explore && (hovered || focused) {
                    Text("Explore", bundle: .module)
                        .modelPickerTextStyle(.footnote, property: "elements.row.caption")
                        .padding(.horizontal, theme.space.s6).padding(.vertical, theme.space.s2)
                        .background(theme.surface.canvas, in: Capsule())
                } else if selected {
                    Image(systemName: "checkmark").glyphSize(.footnote, weight: .medium)
                        .accessibilityHidden(true)
                } else if let trailingSymbol {
                    Image(systemName: trailingSymbol).glyphSize(.footnote).accessibilityHidden(true)
                }
            }
            .modelPickerInk("elements.row.accent", fallback: muted && !hovered && !focused ? theme.text.tertiary : theme.text.primary, muted: muted && !hovered && !focused)
            .modelPickerRowChrome(selected: selected, hovered: hovered, focused: focused)
            .overlay {
                if focused {
                    VStack {
                        Spacer()
                        Rectangle().fill(theme.text.secondary).frame(height: 1).padding(.horizontal, theme.space.s12)
                    }
                }
            }
        }
        .nativeCatalogTarget(["radius", "padding", "height", "background", "selected", "hover", "foreground", "label", "gap"].map { "component.library.26.elements.row." + $0 } + ["component.library.26.elements.layout.rowGap"], "Row \(title)")
        .assignedBasePlainButtonStyle()
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) {
            guard inspectorEnabled else { return .ignored }
            action(); return .handled
        }
        .accessibilityValue(selected ? L("Selected") : "")
        .help(title)
    }
}
