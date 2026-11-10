//
//  ModelPickerView.swift
//  osaurus
//
//  A rich model picker with provider tabs, unified cross-provider search,
//  and metadata display.
//

import AppKit
import SwiftUI

/// Semantic Thinking row state for the picker's options section. Carries
/// only display state plus a semantic setter — the profile-specific stored
/// boolean (including inverted options like `disableThinking`) is resolved
/// by the owner through `ModelProfileRegistry.thinkingStoredOption`, never
/// in the view.
struct ModelPickerThinkingControl {
    /// Effective on/off state the row shows: the explicit persisted choice
    /// when present, otherwise the model's chat-template default.
    let isEnabled: Bool
    /// Whether an explicit persisted override exists. Drives the Default
    /// pill vs. the reset affordance.
    let isExplicit: Bool
    /// Persist a semantic enabled state; nil removes the override so the
    /// model's template default applies naturally again.
    let onSetEnabled: (Bool?) -> Void
    var supportsUnspecifiedDefault: Bool = false
    var selectionIsValid: Bool = true

    var selectedMode: String? {
        guard selectionIsValid else { return nil }
        if supportsUnspecifiedDefault && !isExplicit { return "default" }
        return isEnabled ? "on" : "off"
    }
}

/// Inline model-options control state for the picker's currently selected
/// model: the semantic Thinking row (when the model has a thinking toggle)
/// plus every other option the model's profile (or live provider catalog)
/// exposes, rendered as a "Model Options" section at the bottom of the
/// picker.
struct ModelPickerOptionsControl {
    /// Catalog-driven reasoning capabilities (ChatGPT/Codex live catalog or
    /// the documented official OpenAI GPT-5.6 contract), when present. Used
    /// to surface per-level catalog descriptions on the effort row.
    let capabilities: ModelReasoningCapabilities?
    /// Semantic Thinking row for models with a boolean thinking toggle.
    /// Rendered first in the section, ahead of the generic rows.
    var thinking: ModelPickerThinkingControl? = nil
    /// Non-thinking option definitions for the selected model, in profile
    /// order. When `capabilities` is present this is just the dynamic
    /// `reasoningEffort` definition.
    let options: [ModelOptionDefinition]
    /// Explicit persisted values. Missing keys mean "use the default" —
    /// nothing is sent on the wire for them.
    let values: [String: ModelOptionValue]
    /// Display-only defaults (profile defaults, or the catalog default for
    /// capability-enriched effort). Never synthesized into requests.
    let defaults: [String: ModelOptionValue]
    /// Persist one option; a nil value removes the explicit override so the
    /// default applies naturally again.
    let onChange: (String, ModelOptionValue?) -> Void

    var reasoningValidationMessage: String? = nil

    var isEmpty: Bool { options.isEmpty && thinking == nil && reasoningValidationMessage == nil }

    func canResetOption(_ id: String) -> Bool {
        options.contains { $0.id == id } || (id == "reasoningEffort" && reasoningValidationMessage != nil)
    }

    /// The segment id the UI marks as selected for a segmented option:
    /// explicit choice first, then the display default, then the first
    /// segment.
    func effectiveSegmentId(for option: ModelOptionDefinition) -> String? {
        if option.id == "reasoningEffort", reasoningValidationMessage != nil { return nil }
        if let explicit = values[option.id]?.stringValue { return explicit }
        if let fallback = defaults[option.id]?.stringValue { return fallback }
        if case .segmented(let segments) = option.kind { return segments.first?.id }
        return nil
    }

    /// The on/off state the UI shows for a toggle option: explicit choice
    /// first, then the display default, then the definition's default.
    func effectiveToggleValue(for option: ModelOptionDefinition) -> Bool {
        if let explicit = values[option.id]?.boolValue { return explicit }
        if let fallback = defaults[option.id]?.boolValue { return fallback }
        if case .toggle(let defaultValue) = option.kind { return defaultValue }
        return false
    }

    /// Height of the "Model Options" section header the view renders above
    /// the rows, included in `estimatedHeight` for the popover frame.
    @MainActor static var headerHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let theme = ThemeManager.shared.currentTheme
        return theme.assignedLineHeight(ModelPickerInspectionStyle.key + "label", fallback: 16)
            + 12 + ModelPickerInspectionStyle.metric("gap", 4, theme)
        #else
        return 28
        #endif
    }

    /// Estimated rendered height of the options section (header + rows),
    /// used for the popover frame.
    @MainActor var estimatedHeight: CGFloat {
        Self.headerHeight + rowsEstimatedHeight
    }

    /// Estimated rendered height of the option rows alone (the scrollable
    /// region once the section exceeds its cap). Segmented rows account for
    /// chip wrapping in the picker's fixed content width.
    @MainActor var rowsEstimatedHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let theme = ThemeManager.shared.currentTheme
        let key = ModelPickerInspectionStyle.key
        let padding = theme.assignedMetric(key + "padding", fallback: 10)
        let gap = theme.assignedMetric(key + "gap", fallback: 6)
        let label = theme.assignedLineHeight(key + "label", fallback: 18)
        let text = theme.assignedLineHeight(key + "text", fallback: 16)
        let caption = theme.assignedLineHeight(key + "caption", fallback: 16)
        let row = max(theme.assignedMetric(key + "height", fallback: 32), caption + padding * 2)
        let font = theme.assignedNativeFont(key + "caption", fallback: theme.nsFont(.footnote))
        let thinkingHeight: CGFloat = thinking == nil ? 0 : max(26, label + gap + text) + padding * 2
        return thinkingHeight + options.reduce(CGFloat(0)) { total, option in
            switch option.kind {
            case .segmented(let segments):
                var lines: CGFloat = 1
                var width: CGFloat = 0
                for segment in segments {
                    let chipWidth = (segment.label as NSString).size(withAttributes: [.font: font]).width + padding * 2 + gap
                    if width + chipWidth > 352 { lines += 1; width = chipWidth }
                    else { width += chipWidth }
                }
                return total + label + gap + lines * row + max(0, lines - 1) * gap + (option.help == nil ? 0 : text + gap) + padding * 2
            case .toggle:
                return total + row + (option.help == nil ? 0 : text + gap)
            }
        }
        #else
        let availableWidth: CGFloat = 352
        // Thinking row: icon container + title/description stack + padding.
        let thinkingHeight: CGFloat = thinking != nil ? 50 : 0
        let validationHeight: CGFloat = reasoningValidationMessage == nil ? 0 : 44
        let resetHeight: CGFloat = reasoningValidationMessage != nil && thinking == nil
            && !options.contains(where: { $0.id == "reasoningEffort" }) ? 24 : 0
        return validationHeight + resetHeight + thinkingHeight + options.reduce(CGFloat(0)) { total, option in
            switch option.kind {
            case .segmented(let segments):
                var lines: CGFloat = 1
                var lineWidth: CGFloat = 0
                for segment in segments {
                    // chip ≈ label width (~6.5pt/char) + horizontal padding + spacing
                    let chipWidth = CGFloat(segment.label.count) * 6.5 + 26
                    if lineWidth + chipWidth > availableWidth {
                        lines += 1
                        lineWidth = chipWidth
                    } else {
                        lineWidth += chipWidth
                    }
                }
                // header + chip lines + row padding (+ description line when
                // the catalog publishes level copy)
                let descriptionHeight: CGFloat =
                    (option.id == "reasoningEffort" && capabilities != nil) ? 16 : 0
                return total + 28 + lines * 31 + 20 + descriptionHeight
            case .toggle:
                return total + 44
            }
        }
        #endif
    }
}

/// An action offered under the model list, for callers that need to give the
/// user a way to get a model that is not there yet (add a provider, download
/// a bundle). Only callers that pass these show a footer; everywhere else the
/// picker is unchanged.
struct ModelPickerFooterAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let action: () -> Void

    init(id: String, title: String, icon: String, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.action = action
    }
}

struct ModelPickerView: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let agentId: UUID?
    var optionsControl: ModelPickerOptionsControl? = nil
    /// Escape hatches shown under the list. Empty for every caller that only
    /// selects among models the user already has.
    var footerActions: [ModelPickerFooterAction] = []
    let onDismiss: () -> Void
    /// Replaces the default "Add Model" action (dismiss + jump to the Models
    /// tab). Hosts that would lose unsaved state on that tab switch use this
    /// to confirm with the user before navigating.
    var onAddModel: (() -> Void)? = nil

    @State private var searchText = ""
    /// The query the rows are filtered by; trails `searchText` by
    /// `SearchDebounce.interval` while typing.
    @State private var appliedSearchText = ""
    /// Tracks IME composition so the placeholder hides while composing.
    @State private var isSearchComposing = false
    @State private var selectedTabKey: String?
    @State private var sortOrder: ModelPickerSortOrder = .default
    @State private var contextFilter: ModelPickerContextFilter = .any
    @State private var visionFilter: ModelPickerVisionFilter = .any
    @State private var localSourceFilter: ModelPickerLocalSourceFilter = .any
    @State private var showSortPopover = false
    @ObservedObject private var favoritesStore = FavoriteModelsStore.shared
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var inspectorEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(26, enabled: inspectorEnabled, authoritative: true) }

    /// Stable key/title for the synthetic Favorites tab. It only exists while
    /// the user has at least one favourite among the currently visible models.
    private static let favoritesTabKey = "favorites"
    private static let favoritesTabTitle = "Favorites"

    // MARK: - Test Mode

    #if DEBUG
        // set USE_MOCK_MODELS=1 in Xcode scheme to automatically use mock data
        private var useMockData: Bool {
            ProcessInfo.processInfo.environment["USE_MOCK_MODELS"] == "1"
        }

        private var displayOptions: [ModelPickerItem] {
            useMockData ? ModelPickerItem.generateMockModels(count: 500) : options
        }
    #else
        private var displayOptions: [ModelPickerItem] { options }
    #endif

    // MARK: - Data

    private var isSearching: Bool {
        !appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Picker options with non-MLX local bundles removed. The catalog greys
    /// these out so the user can see why they won't run, but the picker exists
    /// only to select a usable model — a non-selectable row is just clutter, so
    /// drop them here. Non-local sources (foundation, remote) are always
    /// `isMLXFormat`, so only co-mingled local non-MLX bundles are filtered.
    /// Filtering before grouping keeps the header count, tab badges, and rows
    /// all consistent.
    private var visibleOptions: [ModelPickerItem] {
        displayOptions.filter { $0.isMLXFormat }
    }

    /// Visible models the user has favourited, in the order they were added.
    /// Favourites whose model isn't currently available (provider offline,
    /// deleted on disk) simply don't appear until the model returns.
    private var favoriteItems: [ModelPickerItem] {
        guard !favoritesStore.favoriteKeys.isEmpty else { return [] }
        let byKey = Dictionary(
            visibleOptions.map { ($0.favoriteKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return favoritesStore.favoriteKeys.compactMap { byKey[$0] }
    }

    private var currentTabs: [ModelPickerTab] {
        let base = visibleOptions.groupedByTab()
        let favorites = favoriteItems
        guard !favorites.isEmpty else { return base }
        // Pin the Favourites tab first so a few preferred models are always the
        // shortest path, ahead of the provider tabs.
        let favoritesTab = ModelPickerTab(
            key: Self.favoritesTabKey,
            title: Self.favoritesTabTitle,
            models: favorites
        )
        return [favoritesTab] + base
    }

    /// Provider attribution shown on Favourites-tab rows, since favourites mix
    /// models from every source into one list.
    private func providerTitle(for item: ModelPickerItem) -> String {
        switch item.source {
        case .foundation, .local, .imageGeneration:
            return "Local"
        case .remote(let providerName, _):
            return providerName
        }
    }

    /// The tab to fall back to when there is no valid explicit selection: the
    /// one holding `selectedModel`, otherwise the first tab.
    private static func defaultTabKey(in tabs: [ModelPickerTab], selectedModel: String?) -> String? {
        let modelTab = tabs.first { tab in tab.models.contains { $0.id == selectedModel } }
        return modelTab?.key ?? tabs.first?.key
    }

    /// The tab to render as active: the explicit selection while its tab still
    /// exists, otherwise the derived default. A selection whose tab is
    /// transiently absent mid-refresh falls back here for rendering only.
    private func effectiveSelectedTabKey(in tabs: [ModelPickerTab]) -> String? {
        if let key = selectedTabKey, tabs.contains(where: { $0.key == key }) {
            return key
        }
        return Self.defaultTabKey(in: tabs, selectedModel: selectedModel)
    }

    /// Resolve which tab key should be *committed to `selectedTabKey`*, given the
    /// currently committed key and the available tabs.
    ///
    /// Once a key is committed it is returned untouched — even if that tab is
    /// momentarily absent. The picker refreshes its model lists asynchronously
    /// while open (`refreshConnectedProviders` / `buildModelPickerItems`), so a
    /// tab can briefly disappear mid-refresh; clobbering the user's explicit
    /// choice on that transient absence is what made the picker snap from
    /// "Local" back to the first tab ("Osaurus"). Rendering still falls back
    /// gracefully via `effectiveSelectedTabKey` while a tab is missing, and the
    /// committed key re-resolves the moment it returns.
    ///
    /// With no committed key it derives the initial default via `defaultTabKey`.
    static func resolveCommittedTabKey(
        current: String?,
        tabs: [ModelPickerTab],
        selectedModel: String?
    ) -> String? {
        current ?? defaultTabKey(in: tabs, selectedModel: selectedModel)
    }

    private func ensureSelectedTabValid() {
        let resolved = Self.resolveCommittedTabKey(
            current: selectedTabKey,
            tabs: currentTabs,
            selectedModel: selectedModel
        )
        if selectedTabKey != resolved { selectedTabKey = resolved }
    }

    private func row(for model: ModelPickerItem, providerLabel: String? = nil) -> ModelPickerRow {
        let media = model.mediaModel
        return ModelPickerRow(
            modelId: model.id,
            sourceKey: model.source.uniqueKey,
            displayName: model.displayName,
            description: media.map(Self.mediaDetails) ?? model.description,
            parameterCount: model.parameterCount,
            quantization: model.quantization,
            isVLM: model.isVLM,
            mediaKind: media?.kind,
            mediaPrivacy: media?.privacy.map(Self.mediaPrivacyLabel),
            mediaPrice: media?.pricing?.minimumUSD.map {
                "From \(OsaurusRouter.formatUSDAsCredits($0))"
            },
            isMLXFormat: model.isMLXFormat,
            providerLabel: providerLabel,
            isFavorite: favoritesStore.isFavorite(model.favoriteKey)
        )
    }

    static func mediaPrivacyLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    static func mediaDetails(_ model: MediaModelInfo) -> String? {
        let constraints = model.constraints
        var details: [String] = []
        if !constraints.aspectRatios.isEmpty {
            details.append("AR: \(constraints.aspectRatios.joined(separator: ", "))")
        }
        if !constraints.resolutions.isEmpty {
            details.append("Res: \(constraints.resolutions.joined(separator: ", "))")
        }
        if !constraints.qualities.isEmpty {
            details.append("Quality: \(constraints.qualities.joined(separator: ", "))")
        }
        if !constraints.durations.isEmpty {
            details.append("Duration: \(constraints.durations.joined(separator: ", "))")
        }
        if let defaultSteps = constraints.defaultSteps, let maxSteps = constraints.maxSteps {
            details.append("Steps: \(defaultSteps)–\(maxSteps)")
        } else if let maxSteps = constraints.maxSteps {
            details.append("Steps: ≤\(maxSteps)")
        } else if let defaultSteps = constraints.defaultSteps {
            details.append("Steps: \(defaultSteps)")
        }
        if constraints.supportsAudio {
            details.append(constraints.audioConfigurable ? "Optional audio" : "Audio")
        }
        if let limit = constraints.promptCharacterLimit {
            details.append("Prompt: \(limit.formatted(.number.notation(.compactName)))")
        }
        if let divisor = constraints.dimensionDivisor, divisor > 1 {
            details.append("\(divisor) px increments")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func makeRows(for tab: ModelPickerTab, providerLabel: String? = nil) -> [ModelPickerRow] {
        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(tab.models.count)
        for model in tab.models {
            rows.append(row(for: model, providerLabel: providerLabel))
        }
        return rows
    }

    private func visibleRows(in tabs: [ModelPickerTab]) -> [ModelPickerRow] {
        guard isSearching else {
            guard let key = effectiveSelectedTabKey(in: tabs),
                let tab = tabs.first(where: { $0.key == key })
            else { return [] }
            // The Favourites tab mixes models from every source, so each row
            // carries its provider label to stay distinguishable.
            if tab.key == Self.favoritesTabKey {
                return tab.models.map { row(for: $0, providerLabel: providerTitle(for: $0)) }
            }
            // The Local tab is the only one whose models carry an external
            // provenance (HF cache, LM Studio), so it gets the source filter
            // — users with other apps' models on disk can narrow to
            // Osaurus-managed ones. The vision filter applies here too since
            // local VLMs carry the flag. Both are no-ops at `.any`.
            if tab.isLocal {
                let processed = tab.models
                    .filteredByLocalSource(localSourceFilter)
                    .filteredByVision(visionFilter)
                return makeRows(for: ModelPickerTab(key: tab.key, title: tab.title, models: processed))
            }
            // Context filtering and price sorting only apply to the Osaurus
            // tab, whose models carry context/pricing metadata; other tabs keep
            // their existing alphabetical order. Both steps are no-ops at their
            // default (`.any` / `.default`), so the pipeline is safe to always
            // run for Osaurus.
            guard tab.isOsaurus else { return makeRows(for: tab) }
            let processed = tab.models
                .filteredByContext(contextFilter)
                .filteredByVision(visionFilter)
                .sortedByPrice(sortOrder)
            return makeRows(for: ModelPickerTab(key: tab.key, title: tab.title, models: processed))
        }

        return searchRows(in: tabs)
    }

    private func searchRows(in tabs: [ModelPickerTab]) -> [ModelPickerRow] {
        // Unified search: one pass across every tab's models with the query
        // prepared once. Each row carries its provider title so identical
        // model IDs offered by different providers stay distinguishable.
        let prepared = SearchService.PreparedQuery(appliedSearchText)
        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(64)

        for tab in tabs {
            for model in tab.models {
                guard
                    SearchService.matches(prepared, in: model.displayName)
                        || SearchService.matches(prepared, in: model.id)
                else { continue }
                rows.append(row(for: model, providerLabel: tab.title))
            }
        }
        return rows
    }

    private func switchTab(by offset: Int) {
        let tabs = currentTabs
        guard !tabs.isEmpty else { return }
        let activeKey = effectiveSelectedTabKey(in: tabs)
        let currentIndex = tabs.firstIndex(where: { $0.key == activeKey }) ?? 0
        let newIndex = max(0, min(tabs.count - 1, currentIndex + offset))
        guard tabs[newIndex].key != activeKey else { return }
        selectedTabKey = tabs[newIndex].key
    }

    // MARK: - Body

    /// Height budget the options section adds to the popover frame; the
    /// rows scroll once they exceed their cap so many-option models (e.g.
    /// Gemini image profiles) can't crowd out the model list. The section
    /// header stays pinned above the scroll region, so it is budgeted
    /// separately.
    private var optionsSectionHeight: CGFloat {
        guard let optionsControl, !optionsControl.isEmpty else { return 0 }
        return ModelPickerOptionsControl.headerHeight
            + min(optionsControl.rowsEstimatedHeight, Self.optionsSectionMaxHeight)
    }

    private static let optionsSectionMaxHeight: CGFloat = 240

    private func pickerFrameHeight(rows: [ModelPickerRow]) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let recipe = InspectorNativeModelPickerRecipe(theme: theme)
        let content = rows.prefix(8).reduce(CGFloat(160)) { $0 + recipe.rowHeight($1) }
        return min(content + optionsSectionHeight + footerSectionHeight,
            (optionsSectionHeight > 0 ? 480 + min(optionsSectionHeight, 200) : 480) + footerSectionHeight)
        #else
        return min(CGFloat(visibleOptions.count * 48 + 160) + optionsSectionHeight + footerSectionHeight,
            (optionsSectionHeight > 0 ? 480 + min(optionsSectionHeight, 200) : 480) + footerSectionHeight)
        #endif
    }

    var body: some View {
        let tabs = currentTabs
        let rows = visibleRows(in: tabs)
        // The sort/filter control is offered on the Osaurus tab (the only tab
        // with pricing) and on the Local tab when external models (LM Studio,
        // HF cache) are co-mingled with Osaurus-managed ones — with nothing
        // external there is nothing to filter by, so the control stays hidden.
        // Never shown while the cross-provider search is active.
        let activeTab = tabs.first { $0.key == effectiveSelectedTabKey(in: tabs) }
        let showSort =
            !isSearching
            && ((activeTab?.isOsaurus ?? false)
                || (activeTab?.isLocal == true
                    && !(activeTab?.models.distinctExternalSources.isEmpty ?? true)))
        VStack(spacing: 0) {
            VStack(spacing: theme.space.s8) {
                header(showSort: showSort)
                    .padding(.top, theme.space.s12)
                searchField
                    .padding(.horizontal, headerInset)
                if !isSearching, tabs.count > 1 {
                    tabBar(tabs: tabs)
                }
            }
            .padding(.bottom, ModelPickerInspectionStyle.metric("elements.layout.searchResultsGap", theme.space.s8, theme))
            .nativeCatalogTarget(["component.library.26.elements.layout.searchResultsGap"], "Picker controls → results")

            if rows.isEmpty {
                emptyState
            } else {
                // Favourites-mode (trash control) only while the Favourites tab
                // is the active, non-search view.
                modelList(
                    rows: rows,
                    isFavoritesTab: !isSearching && activeTab?.key == Self.favoritesTabKey
                )
                .padding(.horizontal, theme.space.s8)
            }

            if let optionsControl, !optionsControl.isEmpty {
                Divider().background(ModelPickerInspectionStyle.color("border", theme.border.subtle, theme))
                optionsSection(optionsControl)
            }

            if !footerActions.isEmpty {
                Divider().background(ModelPickerInspectionStyle.color("border", theme.border.subtle, theme))
                footerSection
            }
        }
        .frame(
            width: 380,
            height: pickerFrameHeight(rows: rows)
        )
        .background(popoverBackground)
        .overlay(popoverBorder)
        .nativeCatalogTarget(["background", "border", "borderWidth", "radius"].map { "component.library.26.elements.container." + $0 }, "Searchable picker container")
        #if OSAURUS_DESIGN_SYSTEM
        .environment(\.theme, theme)
        #endif
        .onAppear {
            ensureSelectedTabValid()
        }
        .task {
            // refresh remote model lists on open so newly-added/removed
            // models surface
            await RemoteProviderManager.shared.refreshConnectedProviders()
            await ModelPickerItemCache.shared.buildModelPickerItems()
            ensureSelectedTabValid()

            // Drop external models (HF cache, LM Studio) the user deleted on
            // disk while the app stayed running — the picker cache is built
            // once and rebuilds on `.localModelsChanged`. This also refreshes
            // availability for retained registrations after source loss or
            // recovery. Runs off-main and last since it's lowest priority.
            _ = await Task.detached(priority: .utility) {
                ExternalModelLocator.pruneMissing()
            }.value
        }
        .onChange(of: options) { _, _ in
            ensureSelectedTabValid()
        }
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
            .fill(ModelPickerInspectionStyle.color("background", theme.surface.canvas, theme))
            .themeElevation(theme.elevation.overlay)
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
            .strokeBorder(
                ModelPickerInspectionStyle.color("border", theme.border.subtle, theme),
                lineWidth: ModelPickerInspectionStyle.metric("borderWidth", theme.stroke.default, theme)
            )
    }

    // MARK: - Header

    private var headerInset: CGFloat {
        theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.header.paddingX",
            inheriting: theme.space.s12)
    }

    @ViewBuilder
    private func header(showSort: Bool) -> some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.header.horizontalGap", inheriting: theme.space.s8)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.space.s4) {
                    pickerTitle
                        .fixedSize(horizontal: true, vertical: false)
                    CountBadge(visibleOptions.count)
                        .accessibilityLabel(Text("\(visibleOptions.count) models", bundle: .module))
                }
                pickerTitle
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if showSort {
                sortButton
            }

            Button(action: {
                if let onAddModel {
                    onAddModel()
                    return
                }
                onDismiss()
                Task { @MainActor in
                    try? await Task.sleepForPopoverDismiss()
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                }
            }) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.header.horizontalGap2", inheriting: ModelPickerInspectionStyle.metric("gap", 4, theme))) {
                    Image(systemName: "plus")
                    Text("Add Model", bundle: .module)
                }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.header.horizontalGap2")
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
        }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.header.horizontalGap")
        .padding(.horizontal, headerInset)
        .catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.header.paddingX")
    }

    private var pickerTitle: some View {
        Text("Available Models", bundle: .module)
            .modelPickerFont(SettingsFont.sectionTitle, property: "heading")
            .foregroundColor(theme.text.primary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Sort Menu

    private var sortButton: some View {
        Button(action: { showSortPopover.toggle() }) {
            Image(systemName: "arrow.up.arrow.down")
                .glyphSize(11, weight: .semibold)
                .modelPickerInk("accent", fallback: theme.text.link)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .strokeBorder(theme.border.strong, lineWidth: theme.stroke.default)
                        .background(
                            Circle().fill(theme.status.info.background)
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Sort and filter", bundle: .module))
        .accessibilityLabel(Text("Sort and filter", bundle: .module))
        .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
            sortPopoverView
        }
    }

    /// Whether any non-default sort/filter is applied, used to highlight the
    /// circular control so the user can tell at a glance the list is modified.
    private var isSortOrFilterActive: Bool {
        sortOrder != .default || contextFilter != .any || visionFilter != .any
            || localSourceFilter != .any
    }

    /// Chip choices for the Local tab's source filter: the two fixed cases
    /// plus one chip per external provenance actually present, so the row
    /// never offers a filter that would match nothing.
    private var localSourceOptions: [ModelPickerLocalSourceFilter] {
        let locals = currentTabs.first(where: \.isLocal)?.models ?? []
        return [.any, .osaurus] + locals.distinctExternalSources.map { .external($0) }
    }

    private var sortPopoverView: some View {
        // The popover's sections track the active tab: the Local tab filters
        // by model source (Osaurus-managed vs. externally-discovered) and
        // vision; the Osaurus tab keeps its price sort + context + vision.
        let isLocalTab =
            currentTabs.first { $0.key == effectiveSelectedTabKey(in: currentTabs) }?.isLocal == true
        return VStack(alignment: .leading, spacing: 4) {
            if isLocalTab {
                sortSectionHeader(Text("Source", bundle: .module))

                FlowLayout(spacing: 8) {
                    ForEach(localSourceOptions) { option in
                        FilterChip(option.label, isSelected: localSourceFilter == option) {
                            localSourceFilter = option
                        }
                    }
                }
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.sortPopoverView.paddingX", inheriting: ModelPickerInspectionStyle.metric("padding", 12, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.sortPopoverView.paddingX")
            } else {
                sortSectionHeader(Text("Sort by price", bundle: .module))

                sortRow(.default, Text("Default", bundle: .module), icon: "list.bullet")
                sortRow(.priceLowToHigh, Text("Cheapest first", bundle: .module), icon: "arrow.up")
                sortRow(.priceHighToLow, Text("Highest first", bundle: .module), icon: "arrow.down")

                sortSectionHeader(Text("Context limit", bundle: .module))

                FlowLayout(spacing: 8) {
                    ForEach(ModelPickerContextFilter.allCases) { option in
                        FilterChip(option.label, isSelected: contextFilter == option) {
                            contextFilter = option
                        }
                    }
                }
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.sortPopoverView.paddingX2", inheriting: ModelPickerInspectionStyle.metric("padding", 12, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.sortPopoverView.paddingX2")
            }

            sortSectionHeader(Text("Vision", bundle: .module))

            FlowLayout(spacing: 8) {
                ForEach(ModelPickerVisionFilter.allCases) { option in
                    FilterChip(option.label, isSelected: visionFilter == option) {
                        visionFilter = option
                    }
                }
            }
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.sortPopoverView.paddingX3", inheriting: ModelPickerInspectionStyle.metric("padding", 12, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.sortPopoverView.paddingX3")
            .padding(.bottom, 12)
        }
        .frame(width: 240)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
    }

    private func sortSectionHeader(_ text: Text) -> some View {
        text
            .modelPickerTextStyle(.micro, property: "caption", weight: 700)
            #if !OSAURUS_DESIGN_SYSTEM
            .tracking(0.6)
            #endif
            .foregroundColor(theme.text.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.sortSectionHeader.paddingX", inheriting: ModelPickerInspectionStyle.metric("padding", 12, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.sortSectionHeader.paddingX")
            .padding(.top, 12)
            .padding(.bottom, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.sortSectionHeader.paddingY", inheriting: ModelPickerInspectionStyle.metric("gap", 6, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.sortSectionHeader.paddingY")
    }

    private func sortRow(_ order: ModelPickerSortOrder, _ title: Text, icon: String) -> some View {
        SortOptionRow(icon: icon, title: title, isSelected: sortOrder == order) {
            sortOrder = order
            showSortPopover = false
        }
    }

    private struct SortOptionRow: View {
        let icon: String
        let title: Text
        let isSelected: Bool
        let action: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .glyphSize(12, weight: .medium)
                        .frame(width: 16)
                        .foregroundColor(isSelected ? theme.text.link : theme.text.secondary)
                    title
                        .modelPickerTextStyle(.caption, property: "caption", weight: isSelected ? 600 : 500)
                        .foregroundColor(isSelected ? theme.text.link : theme.text.primary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .glyphSize(10, weight: .bold)
                            .modelPickerInk("accent", fallback: theme.text.link)
                    }
                }
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.sortOptionRow.body.paddingX", inheriting: ModelPickerInspectionStyle.metric("padding", 12, theme))).catalogLayoutTarget("component.library.26.elements.layout.sortOptionRow.body.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.sortOptionRow.body.paddingY", inheriting: ModelPickerInspectionStyle.metric("padding", 8, theme))).catalogLayoutTarget("component.library.26.elements.layout.sortOptionRow.body.paddingY")
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(
                            isSelected
                                ? theme.surface.selected
                                : (isHovering
                                    ? theme.surface.hover
                                    : Color.clear)
                        )
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(theme.motion.quick) {
                    isHovering = hovering
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        searchFieldContent
            .task(id: searchText) {
                let text = searchText
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await Task.sleep(for: SearchDebounce.interval)
                    guard !Task.isCancelled else { return }
                }
                if appliedSearchText != text { appliedSearchText = text }
            }
    }

    @ViewBuilder private var searchFieldContent: some View {
        #if OSAURUS_DESIGN_SYSTEM
        SearchField(text: $searchText, placeholder: "Search models...", fillsAvailableWidth: true)
        #else
        HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.searchField.horizontalGap", inheriting: ModelPickerInspectionStyle.metric("gap", 8, theme))) {
            Image(systemName: "magnifyingglass")
                .glyphSize(13)
                .foregroundColor(theme.text.secondary)

            ZStack(alignment: .leading) {
                if searchText.isEmpty && !isSearchComposing {
                    Text("Search models...", bundle: .module)
                        .modelPickerFont(SettingsFont.body, property: "text")
                        .foregroundColor(theme.text.secondary)
                        .allowsHitTesting(false)
                }
                IMEAwareTextField(
                    text: $searchText,
                    isComposing: $isSearchComposing,
                    font: theme.nsFont(.label, weight: .regular),
                    textColor: NSColor(theme.text.primary)
                )
                .accessibilityLabel(Text("Search models", bundle: .module))
                .frame(height: 17)
            }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .glyphSize(12)
                        .foregroundColor(theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.searchField.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.searchField.paddingX", inheriting: ModelPickerInspectionStyle.metric("padding", 12, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.searchField.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.searchField.paddingY", inheriting: ModelPickerInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.searchField.paddingY")
        .background(ModelPickerInspectionStyle.color("background", theme.surface.subtle, theme))
        .animation(theme.motion.quick, value: searchText.isEmpty)
        #endif
    }

    // MARK: - Tab Bar

    @ViewBuilder
    private func tabBar(tabs: [ModelPickerTab]) -> some View {
        let activeKey = effectiveSelectedTabKey(in: tabs)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.tabBar.horizontalGap", inheriting: theme.space.s6)) {
                    ForEach(tabs) { tab in
                        tabChip(for: tab, activeKey: activeKey)
                            .id(tab.key)
                    }
                }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.tabBar.horizontalGap")
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.tabBar.paddingX", inheriting: headerInset)).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.tabBar.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.tabBar.paddingY", inheriting: theme.space.s4)).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.tabBar.paddingY")
            }
            .onAppear {
                if let key = activeKey {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
            .onChange(of: selectedTabKey) { _, newKey in
                guard let newKey else { return }
                withAnimation(reduceMotion ? nil : theme.motion.quick) {
                    proxy.scrollTo(newKey, anchor: .center)
                }
            }
        }
    }

    private func tabChip(for tab: ModelPickerTab, activeKey: String?) -> some View {
        let isActive = tab.key == activeKey
        let isFavorites = tab.key == Self.favoritesTabKey
        return FilterChip(
            isFavorites ? L("Favorites") : tab.title,
            icon: isActive ? "checkmark" : isFavorites ? "heart.fill" : nil,
            count: tab.models.count,
            isSelected: isActive
        ) {
            selectedTabKey = tab.key
        }
    }

    // MARK: - Options Section

    /// Inline "Model Options" section: the semantic Thinking row first (when
    /// the model has a thinking toggle), then every other option the selected
    /// model exposes, in profile/catalog order. The rows scroll once their
    /// estimated content exceeds the section cap so many-option models can't
    /// crowd out the model list; the section header stays pinned.
    @ViewBuilder
    private func optionsSection(_ control: ModelPickerOptionsControl) -> some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            if let message = control.reasoningValidationMessage {
                Text(message)
                    .modelPickerFont(SettingsFont.footnote, property: "caption")
                    .foregroundColor(theme.text.secondary)
                    .padding(.horizontal, theme.space.s16)
                    .padding(.vertical, theme.space.s8)
                if control.thinking == nil && !control.options.contains(where: { $0.id == "reasoningEffort" }) {
                    resetButton { control.onChange("reasoningEffort", nil) }
                }
            }
            if let thinking = control.thinking {
                thinkingOptionRow(thinking)
                if !control.options.isEmpty {
                    Divider()
                        .background(theme.border.subtle)
                        .padding(.horizontal, 16)
                }
            }
            ForEach(Array(control.options.enumerated()), id: \.element.id) { index, option in
                if index > 0 {
                    Divider()
                        .background(theme.border.subtle)
                        .padding(.horizontal, 16)
                }
                switch option.kind {
                case .segmented:
                    segmentedOptionRow(option, control: control)
                case .toggle:
                    toggleOptionRow(option, control: control)
                }
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            optionsSectionHeader
            if control.rowsEstimatedHeight > Self.optionsSectionMaxHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    rows
                }
                .frame(height: Self.optionsSectionMaxHeight)
            } else {
                rows
            }
        }
    }

    /// Section title separating the model list above from the per-model
    /// option rows below, so the section reads as one coherent group.
    private var optionsSectionHeader: some View {
        Text("Model Options", bundle: .module)
            .modelPickerFont(SettingsFont.compactLabel, property: "label")
            #if !OSAURUS_DESIGN_SYSTEM
            .kerning(0.8)
            #endif
            .foregroundColor(theme.text.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.optionsSectionHeader.paddingY", inheriting: ModelPickerInspectionStyle.metric("gap", 4, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.optionsSectionHeader.paddingY")
            .accessibilityAddTraits(.isHeader)
    }

    /// Dedicated Thinking row, in the settings-row idiom: a tinted icon
    /// container that carries the on/off state at a glance, the title +
    /// one-line explanation stacked beside it, and the switch on the
    /// trailing edge. The model's template default is surfaced via the
    /// Default pill; an explicit override swaps it for a compact reset
    /// affordance.
    @ViewBuilder
    private func thinkingOptionRow(_ thinking: ModelPickerThinkingControl) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(
                        thinking.selectionIsValid && thinking.isEnabled
                            ? theme.surface.selected
                            : ModelPickerInspectionStyle.color("background", theme.surface.subtle, theme)
                    )
                Image(systemName: "brain")
                    .glyphSize(12, weight: .medium)
                    .foregroundColor(
                        thinking.selectionIsValid && thinking.isEnabled ? theme.text.link : theme.text.tertiary
                    )
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.thinkingOptionRow.horizontalGap", inheriting: ModelPickerInspectionStyle.metric("gap", 6, theme))) {
                    // Label context (the name of the mode), distinct from the
                    // streaming "Thinking" status so translators can use a
                    // noun form here and a progressive form there (#2621).
                    Text("thinking.mode.label", bundle: .module)
                        .modelPickerFont(SettingsFont.compactLabel, property: "label")
                        .foregroundColor(theme.text.primary)

                    if !thinking.isExplicit && thinking.selectionIsValid {
                        defaultPill
                    }
                }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.thinkingOptionRow.horizontalGap")

                Text("Let the model reason before it answers", bundle: .module)
                    .modelPickerFont(SettingsFont.footnote, property: "caption")
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if thinking.isExplicit {
                compactResetButton { thinking.onSetEnabled(nil) }
            }

            if thinking.supportsUnspecifiedDefault || !thinking.selectionIsValid {
                #if OSAURUS_DESIGN_SYSTEM
                SettingsMenuPicker(
                    selection: Binding(
                        get: { thinking.selectedMode ?? "unsupported" },
                        set: { thinking.onSetEnabled($0 == "default" ? nil : $0 == "on") }
                    ),
                    options: (thinking.selectionIsValid ? [] : [.init("unsupported", "Choose reasoning")])
                        + (thinking.supportsUnspecifiedDefault ? [.init("default", "Default")] : [])
                        + [.init("on", "On"), .init("off", "Off")],
                    disabledValues: ["unsupported"]
                )
                    .accessibilityIdentifier("model-thinking-mode")
                #else
                Picker(
                    L("thinking.mode.label"),
                    selection: Binding(
                        get: { thinking.selectedMode ?? "unsupported" },
                        set: { thinking.onSetEnabled($0 == "default" ? nil : $0 == "on") }
                    )
                ) {
                    if !thinking.selectionIsValid {
                        Text("Choose reasoning", bundle: .module).tag("unsupported").disabled(true)
                    }
                    if thinking.supportsUnspecifiedDefault {
                        Text("Default", bundle: .module).tag("default")
                    }
                    Text("On", bundle: .module).tag("on")
                    Text("Off", bundle: .module).tag("off")
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("model-thinking-mode")
                #endif
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { thinking.isEnabled },
                        set: { thinking.onSetEnabled($0) }
                    )
                )
                .settingsSwitch()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.thinkingOptionRow.paddingY", inheriting: ModelPickerInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.thinkingOptionRow.paddingY")
        .animation(theme.motion.springAnimation, value: thinking.isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("thinking.mode.label", bundle: .module))
        .accessibilityValue(
            !thinking.selectionIsValid
                ? Text("Choose reasoning", bundle: .module)
                : thinking.supportsUnspecifiedDefault && !thinking.isExplicit
                ? Text("Default", bundle: .module)
                : thinking.isEnabled
                    ? Text("On", bundle: .module)
                    : Text("Off", bundle: .module)
        )
    }

    /// Icon-only reset affordance for compact rows where the labeled
    /// `resetButton` would crowd the switch; the label moves to the tooltip.
    private func compactResetButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .glyphSize(9, weight: .semibold)
                .foregroundColor(theme.text.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(ModelPickerInspectionStyle.color("background", theme.surface.subtle, theme)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(String(localized: "Reset to default", bundle: .module))
        .accessibilityLabel(Text("Reset to default", bundle: .module))
    }

    /// Segmented option row: the option's segments in declared order, the
    /// effective selection marked, a "Default" pill while no explicit
    /// override exists, and a reset affordance while one does. For the
    /// catalog-enriched effort row, catalog level descriptions render as
    /// secondary text/help.
    @ViewBuilder
    private func segmentedOptionRow(
        _ option: ModelOptionDefinition,
        control: ModelPickerOptionsControl
    ) -> some View {
        let segments: [ModelOptionSegment] = {
            if case .segmented(let segments) = option.kind { return segments }
            return []
        }()
        let isExplicit = control.values[option.id] != nil
            || (option.id == "reasoningEffort" && control.reasoningValidationMessage != nil)
        let effectiveId = control.effectiveSegmentId(for: option)
        // Catalog levels (with descriptions) back the effort row when the
        // provider published capabilities; other rows have segments only.
        let capabilityLevels: [ModelReasoningCapabilities.Level]? =
            (option.id == "reasoningEffort") ? control.capabilities?.levels : nil

        VStack(alignment: .leading, spacing: 8) {
            optionRowHeader(option: option, isExplicit: isExplicit, control: control)

            FlowLayout(spacing: 6) {
                ForEach(segments) { segment in
                    segmentChip(
                        label: segment.label,
                        help: capabilityLevels?.first(where: { $0.id == segment.id })?.description,
                        isSelected: segment.id == effectiveId,
                        action: { control.onChange(option.id, .string(segment.id)) }
                    )
                }
            }

            // The effective level's catalog description, when the provider
            // published one (Codex catalog levels carry ChatGPT's own copy).
            if let description = capabilityLevels?
                .first(where: { $0.id == effectiveId })?.description,
                !description.isEmpty
            {
                Text(description)
                    .modelPickerFont(SettingsFont.footnote, property: "caption")
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help = option.help, !help.isEmpty {
                Text(help)
                    .modelPickerFont(SettingsFont.footnote, property: "caption")
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.content.paddingY", inheriting: ModelPickerInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.content.paddingY")
    }

    /// Toggle option row in the same visual family as the segmented rows.
    @ViewBuilder
    private func toggleOptionRow(
        _ option: ModelOptionDefinition,
        control: ModelPickerOptionsControl
    ) -> some View {
        let isExplicit = control.values[option.id] != nil
        let isOn = control.effectiveToggleValue(for: option)

        HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.content.horizontalGap", inheriting: ModelPickerInspectionStyle.metric("gap", 6, theme))) {
            if let icon = option.icon {
                Image(systemName: icon)
                    .glyphSize(11, weight: .medium)
                    .foregroundColor(isExplicit ? theme.text.link : theme.text.tertiary)
            }
            Text(option.label)
                .modelPickerFont(SettingsFont.compactLabel, property: "label")
                .foregroundColor(theme.text.primary)

            if !isExplicit {
                defaultPill
            }

            Spacer(minLength: 8)

            if isExplicit {
                // Compact next to the switch: the labeled reset would crowd it.
                compactResetButton { control.onChange(option.id, nil) }
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { control.onChange(option.id, .bool($0)) }
                )
            )
            .settingsSwitch()
        }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.content.horizontalGap")
        .padding(.horizontal, 16)
        .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.content.paddingY2", inheriting: ModelPickerInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.content.paddingY2")
    }

    /// Shared header line for option rows: icon, label, "Default" pill while
    /// no explicit override exists, reset affordance while one does.
    private func optionRowHeader(
        option: ModelOptionDefinition,
        isExplicit: Bool,
        control: ModelPickerOptionsControl
    ) -> some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.content.horizontalGap2", inheriting: ModelPickerInspectionStyle.metric("gap", 6, theme))) {
            if let icon = option.icon {
                Image(systemName: icon)
                    .glyphSize(11, weight: .medium)
                    .foregroundColor(isExplicit ? theme.text.link : theme.text.tertiary)
            }

            Text(option.label)
                .modelPickerFont(SettingsFont.compactLabel, property: "label")
                .foregroundColor(theme.text.primary)

            if !isExplicit {
                defaultPill
            }

            Spacer()

            if isExplicit {
                resetButton { control.onChange(option.id, nil) }
            }
        }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.content.horizontalGap2")
    }

    private var defaultPill: some View {
        StatusChip(L("Default"), tone: .neutral)
            .overlay(Capsule().strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
    }

    private func resetButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .glyphSize(9)
                Text("Reset to default", bundle: .module)
                    .modelPickerFont(SettingsFont.smallLabel, property: "caption")
            }
            .foregroundColor(theme.text.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func segmentChip(
        label: String,
        help: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .modelPickerTextStyle(.footnote, property: "caption", weight: isSelected ? 600 : 500)
                .foregroundColor(isSelected ? theme.text.link : theme.text.secondary)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.content.paddingX", inheriting: ModelPickerInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.content.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.content.paddingY3", inheriting: ModelPickerInspectionStyle.metric("padding", 5, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.content.paddingY3")
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .fill(
                            isSelected
                                ? theme.surface.selected
                                : ModelPickerInspectionStyle.color("background", theme.surface.subtle, theme)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? theme.border.strong
                                : theme.border.subtle,
                            lineWidth: theme.stroke.default
                        )
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help ?? label)
    }

    // MARK: - Footer

    private static let footerRowHeight: CGFloat = 36

    private var footerSectionHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        guard !footerActions.isEmpty else { return 0 }
        let row = max(ModelPickerInspectionStyle.metric("height", Self.footerRowHeight, theme),
            theme.assignedLineHeight(ModelPickerInspectionStyle.key + "label", fallback: 16))
        return CGFloat(footerActions.count) * row + 2 * ModelPickerInspectionStyle.metric("padding", 4, theme)
        #else
        footerActions.isEmpty ? 0 : CGFloat(footerActions.count) * Self.footerRowHeight + 8
        #endif
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            ForEach(footerActions) { item in
                Button {
                    // The caller presents its own UI, so the popover has to
                    // get out of the way first.
                    onDismiss()
                    item.action()
                } label: {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.footerSection.horizontalGap", inheriting: ModelPickerInspectionStyle.metric("gap", 8, theme))) {
                        Image(systemName: item.icon)
                            .glyphSize(12, weight: .medium)
                            .modelPickerInk("accent", fallback: theme.text.link)
                            .frame(width: 16)
                        Text(item.title)
                            .modelPickerFont(SettingsFont.compactLabel, property: "label")
                            .modelPickerInk("accent", fallback: theme.text.link)
                        Spacer(minLength: 0)
                    }.catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.footerSection.horizontalGap")
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.footerSection.paddingX", inheriting: ModelPickerInspectionStyle.metric("padding", 14, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.footerSection.paddingX")
                    .frame(minHeight: ModelPickerInspectionStyle.metric("height", Self.footerRowHeight, theme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, theme.catalogLayoutMetric("component.library.26.elements.layout.modelPickerView.footerSection.paddingY", inheriting: ModelPickerInspectionStyle.metric("padding", 4, theme))).catalogLayoutTarget("component.library.26.elements.layout.modelPickerView.footerSection.paddingY")
    }

    // MARK: - Empty State

    /// With a footer present the rows below say what to do next, so the
    /// empty state only has to explain why the list is bare.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: footerActions.isEmpty ? "magnifyingglass" : "cube")
                .glyphSize(24)
                .foregroundColor(theme.text.tertiary)
            Group {
                if isSearching || footerActions.isEmpty {
                    Text("No models found", bundle: .module)
                } else {
                    Text("No models are set up yet", bundle: .module)
                }
            }
            .modelPickerFont(SettingsFont.body, property: "text")
            .foregroundColor(theme.text.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Model List

    private func modelList(rows: [ModelPickerRow], isFavoritesTab: Bool) -> some View {
        ModelPickerTableRepresentable(
            rows: rows,
            theme: theme,
            selectedModelId: selectedModel,
            isFavoritesTab: isFavoritesTab,
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
            },
            // nil while searching so left/right arrows stay with the
            // search field's text cursor instead of switching hidden tabs
            onSwitchTab: isSearching ? nil : { offset in switchTab(by: offset) },
            onToggleFavorite: { row in
                favoritesStore.toggle(row.favoriteKey)
            },
            onDismiss: onDismiss
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct ModelPickerView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var selected: String? = "foundation"
            @State private var useMockData = true

            var body: some View {
                VStack(spacing: 0) {
                    // toggle for mock data
                    HStack {
                        Toggle(isOn: $useMockData) {
                            Text(
                                mockModels.count == 1
                                    ? L("Use Mock Data (1 model)")
                                    : L("Use Mock Data (\(mockModels.count) models)")
                            )
                        }
                        .settingsCheckbox()
                        .padding()
                        Spacer()
                    }
                    .background(CustomizableTheme.dark().surface.hover)

                    ModelPickerView(
                        options: useMockData ? mockModels : smallSampleModels,
                        selectedModel: $selected,
                        agentId: nil,
                        onDismiss: {}
                    )
                    .padding()
                }
                .frame(width: 450, height: 550)
                .background(CustomizableTheme.dark().surface.hover)
            }

            // large mock dataset for performance testing
            private var mockModels: [ModelPickerItem] {
                ModelPickerItem.generateMockModels(count: 500)
            }

            // small sample for quick testing — multiple providers so the tab
            // bar and unified search attribution are exercised
            private var smallSampleModels: [ModelPickerItem] {
                let openAIId = UUID()
                let anthropicId = UUID()
                return [
                    .foundation(),
                    ModelPickerItem(
                        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                        displayName: "Llama 3.2 3B Instruct 4bit",
                        source: .local,
                        parameterCount: "3B",
                        quantization: "4-bit",
                        isVLM: false
                    ),
                    ModelPickerItem(
                        id: "mlx-community/Qwen2-VL-7B-Instruct-4bit",
                        displayName: "Qwen2 VL 7B Instruct 4bit",
                        source: .local,
                        parameterCount: "7B",
                        quantization: "4-bit",
                        isVLM: true
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-4o",
                        displayName: "gpt-4o",
                        source: .remote(providerName: "OpenAI", providerId: openAIId)
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-3.5-turbo",
                        displayName: "gpt-3.5-turbo",
                        source: .remote(providerName: "OpenAI", providerId: openAIId)
                    ),
                    ModelPickerItem(
                        id: "anthropic/claude-opus-5-5",
                        displayName: "claude-opus-5-5",
                        source: .remote(providerName: "Anthropic", providerId: anthropicId)
                    ),
                ]
            }
        }

        /// Standalone picker with a Thinking-capable options section, for
        /// visually validating the Model Options header, Thinking row, and
        /// segmented effort row together. An explicit override toggles the
        /// Default pill and reset affordance like the live picker.
        struct ThinkingPreviewWrapper: View {
            @State private var selected: String? = "qwen3.5-35b-a3b-4bit"
            @State private var thinkingOverride: Bool? = nil
            @State private var effortOverride: String? = nil

            private var thinkingOptionsControl: ModelPickerOptionsControl {
                ModelPickerOptionsControl(
                    capabilities: nil,
                    thinking: ModelPickerThinkingControl(
                        isEnabled: thinkingOverride ?? true,
                        isExplicit: thinkingOverride != nil,
                        onSetEnabled: { thinkingOverride = $0 }
                    ),
                    options: [
                        ModelOptionDefinition(
                            id: "reasoningEffort",
                            label: L("Reasoning Effort"),
                            icon: "brain",
                            kind: .segmented([
                                ModelOptionSegment(id: "low", label: L("Low")),
                                ModelOptionSegment(id: "medium", label: L("Medium")),
                                ModelOptionSegment(id: "high", label: L("High")),
                            ])
                        )
                    ],
                    values: effortOverride.map { ["reasoningEffort": .string($0)] } ?? [:],
                    defaults: ["reasoningEffort": .string("medium")],
                    onChange: { _, newValue in
                        effortOverride = newValue?.stringValue
                    }
                )
            }

            var body: some View {
                ModelPickerView(
                    options: [
                        ModelPickerItem(
                            id: "qwen3.5-35b-a3b-4bit",
                            displayName: "Qwen3.5 35B A3B 4bit",
                            source: .local,
                            parameterCount: "35B",
                            quantization: "4-bit",
                            isVLM: false
                        )
                    ],
                    selectedModel: $selected,
                    agentId: nil,
                    optionsControl: thinkingOptionsControl,
                    onDismiss: {}
                )
                .padding()
                .frame(width: 450, height: 620)
                .background(CustomizableTheme.dark().surface.hover)
            }
        }

        static var previews: some View {
            PreviewWrapper()
                .previewDisplayName("Model list")
            ThinkingPreviewWrapper()
                .previewDisplayName("Thinking-capable options")
        }
    }
#endif
