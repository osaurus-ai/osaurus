//
//  LocalModelsCatalogPage.swift
//  osaurus
//
//  Models → Local Models for one model kind: the shared header and kind
//  tabs, All / On This Mac / Available chips, search, the model table and
//  the detail panel beside it. Every kind renders through this page; its
//  `LocalModelCatalogSource` supplies the rows.
//

import AppKit
import SwiftUI

struct LocalModelsCatalogPage: View {
    @ObservedObject var source: LocalModelCatalogSource
    let kindTabs: AnyView
    let sourcesButton: AnyView
    /// Repo id from a `local-models` URL, applied once on first appear.
    var deeplinkModelId: String?

    @ObservedObject private var badgeStore = ManagementBadgeStore.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @Environment(\.theme) private var theme

    @State private var scope: LocalModelCatalogScope = .all
    @State private var searchText = ""
    @State private var query = ""
    @State private var queryDebounce: Task<Void, Never>?
    @State private var sort: SettingsDataTableSort<LocalModelSortKey>?
    @State private var selection: String?
    /// The build a deep link named when it is not the row's representative.
    @State private var inspectedModel: MLXModel?
    /// A model to select once its row appears (deep links, imports).
    @State private var pendingSelectionId: String?
    @State private var pendingConfirmation: LocalModelCatalogItem.Action?
    @State private var unsupportedModelName: String?
    @State private var showFilterPopover = false
    @State private var showImportSheet = false
    @State private var showTokenPromptForDeepLink = false
    @State private var hasAppeared = false
    @State private var regionWidth: CGFloat = 0

    private static let inspectorWidth: CGFloat = 420
    /// Narrower than this beside the panel, the panel covers the table.
    private static let minTableWidth: CGFloat = 480

    var body: some View {
        let searched = searchedItems
        let rows = LocalModelCatalogOrdering.sorted(searched.filter { scope.includes($0.status) }, by: sort)
        let selectedItem = selection.flatMap { id in source.items.first { $0.id == id } }
        let inspectorCovers = regionWidth > 0 && regionWidth - Self.inspectorWidth < Self.minTableWidth

        VStack(spacing: theme.space.s0) {
            header(searched: searched)
                .settingsHeaderEntrance(hasAppeared: hasAppeared)
            LiveSystemStatusBar()
                .opacity(hasAppeared ? 1 : 0)
            HStack(spacing: theme.space.s0) {
                ScrollView {
                    SettingsPageContent {
                        if let banner = source.banner(scope: scope) {
                            banner
                        }
                        content(rows: rows)
                        if let footnote = source.footnote {
                            Text(LocalizedStringKey(footnote), bundle: .module)
                                .font(SettingsFont.caption)
                                .foregroundColor(theme.text.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let selectedItem, !inspectorCovers {
                    ThemeHairlineDivider(axis: .vertical, color: theme.border.default)
                    inspector(for: selectedItem)
                        .frame(width: Self.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay {
                if let selectedItem, inspectorCovers {
                    inspector(for: selectedItem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.surface.canvas)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { regionWidth = $0 }
            .opacity(hasAppeared ? 1 : 0)
            .animation(theme.motion.quick, value: selectedItem?.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .onAppear {
            source.activate()
            withAnimation(theme.motion.standard.delay(0.05)) { hasAppeared = true }
            if let modelId = deeplinkModelId, !modelId.isEmpty, source.kind == .language {
                applyModelDeepLink(modelId)
            }
            DispatchQueue.main.async { applyPendingModelDetail() }
        }
        .onChange(of: searchText) { _, newValue in
            if source.kind == .language, ModelManager.parseHuggingFaceRepoId(from: newValue) != nil {
                scope = .all
            }
            queryDebounce?.cancel()
            queryDebounce = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                query = newValue
            }
        }
        .onChange(of: query) { _, newValue in source.setQuery(newValue) }
        .onChange(of: selection) { _, id in
            inspectedModel = nil
            guard let id, let item = source.items.first(where: { $0.id == id }), item.isUnsupported else { return }
            selection = nil
            unsupportedModelName = item.name
        }
        .onChange(of: source.items.map(\.id)) { _, ids in
            if let pending = pendingSelectionId {
                select(modelId: pending)
            } else if let selection, !ids.contains(selection) {
                closeInspector()
            }
        }
        // Replays on subscribe, so a link that arrived before this view
        // existed (cold launch) is applied on first render too.
        .onReceive(managementState.$pendingModelDeepLink) { request in
            guard let request, source.kind == .language else { return }
            managementState.pendingModelDeepLink = nil
            applyModelDeepLink(request.modelId)
        }
        .onReceive(managementState.$pendingModelDetailId) { _ in
            DispatchQueue.main.async { applyPendingModelDetail() }
        }
        .onReceive(managementState.$pendingHuggingFaceTokenPrompt) { requested in
            guard requested, source.kind == .language else { return }
            managementState.pendingHuggingFaceTokenPrompt = false
            // Presenting from inside the publisher callback is dropped
            // (replay lands mid-render), so hop a turn.
            DispatchQueue.main.async { showTokenPromptForDeepLink = true }
        }
        .sheet(isPresented: $showTokenPromptForDeepLink) {
            HuggingFaceTokenPromptSheet { retryDeepLinkAfterTokenSaved() }
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showImportSheet) {
            HuggingFaceImportSheet(
                onImported: { repoId in
                    showImportSheet = false
                    managementState.pendingModelDeepLink = .init(modelId: repoId, file: nil)
                    if source.kind != .language {
                        managementState.openLocalModels(kind: .language)
                    }
                },
                onImportedImage: { _ in
                    showImportSheet = false
                    if source.kind != .image {
                        managementState.openLocalModels(kind: .image)
                    }
                }
            )
            .environment(\.theme, theme)
        }
        .sheet(item: $source.sheetRequest) { request in
            request.content()
                .environment(\.theme, theme)
        }
        .themedAlert(
            pendingConfirmation.map { LCached($0.title) + "?" } ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            message: pendingConfirmation?.confirmation,
            primaryButton: .destructive(pendingConfirmation.map { LCached($0.title) } ?? "") {
                pendingConfirmation?.handler()
                pendingConfirmation = nil
            },
            secondaryButton: .cancel(L("Cancel")) { pendingConfirmation = nil }
        )
        .themedAlert(
            L("Model not supported"),
            isPresented: Binding(
                get: { unsupportedModelName != nil },
                set: { if !$0 { unsupportedModelName = nil } }
            ),
            message: L(
                "\(unsupportedModelName ?? "") isn't an MLX model, so it can't be used in Osaurus. The local engine runs MLX-format models only."
            ),
            primaryButton: .primary(L("OK")) { unsupportedModelName = nil }
        )
        .modifier(ModelDownloadAlertHost())
    }

    // MARK: - Header

    private func header(searched: [LocalModelCatalogItem]) -> some View {
        SettingsPageHeader(
            title: "Local Models",
            subtitle: source.headerSummary ?? source.kind.subtitle,
            verbatimSubtitle: true,
            count: badgeStore.headerCount(for: .models),
            onRefresh: source.refreshHelp == nil ? nil : { source.refresh() },
            refreshHelp: source.refreshHelp ?? "Refresh",
            isRefreshing: source.isRefreshing,
            secondary: { sourcesButton },
            primary: {
                if source.supportsImport {
                    SettingsButton(.primary, "Add Model", icon: "plus", help: "Import a model from Hugging Face") {
                        showImportSheet = true
                    }
                }
            },
            toolbar: {
                VStack(alignment: .leading, spacing: theme.settingsInlineGap) {
                    kindTabs
                    toolbar(searched: searched)
                }
            }
        )
    }

    private func toolbar(searched: [LocalModelCatalogItem]) -> some View {
        SettingsHeaderToolbar(searchText: $searchText, searchPlaceholder: "Search models") {
            FilterChipRow(
                LocalModelCatalogScope.allCases,
                selection: Binding(get: { scope }, set: { if let scope = $0 { self.scope = scope } }),
                allTitle: nil,
                allowsDeselect: false,
                title: \.title,
                count: { scope in searched.filter { scope.includes($0.status) }.count }
            )
        } trailing: {
            if let language = source as? LanguageCatalogSource {
                LanguageFilterChip(source: language, isPresented: $showFilterPopover)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(rows: [LocalModelCatalogItem]) -> some View {
        if rows.isEmpty && !source.isLoading {
            emptyState
        } else {
            let table = LocalModelsTable(
                columns: source.columns,
                items: rows,
                sort: $sort,
                selection: $selection,
                isLoading: source.isLoading,
                perform: perform
            )
            if let anchor = source.landingAnchorId {
                table.settingsLandingAnchor(anchor)
            } else {
                table
            }
        }
    }

    private var searchedItems: [LocalModelCatalogItem] {
        source.searchesItself ? source.items : LocalModelCatalogOrdering.search(source.items, query: query)
    }

    private var emptyState: some View {
        SettingsEmptyState(
            inline: searchLooksLikeAppleScript ? "applescript" : (scope == .onThisMac ? "internaldrive" : "cube.box"),
            title: emptyTitle,
            hint: searchLooksLikeAppleScript
                ? "AppleScript models are made exclusively for Mac automation, so they live under AppleScript instead of the chat catalog."
                : "",
            action: emptyAction,
            secondaryAction: searchText.isEmpty
                ? nil
                : SettingsEmptyState.Action(title: L("Clear search"), icon: "", handler: { searchText = "" })
        )
        .padding(.vertical, theme.settingsSectionGap)
    }

    private var emptyTitle: String {
        if searchLooksLikeAppleScript { return L("Looking for AppleScript models?") }
        if !query.isEmpty { return L("No models match your search") }
        switch scope {
        case .all: return L("No models available")
        case .onThisMac: return L("No models on this Mac yet")
        case .available: return L("Every model is already on this Mac")
        }
    }

    private var emptyAction: SettingsEmptyState.Action? {
        if searchLooksLikeAppleScript {
            return .init(title: L("Show AppleScript Models"), icon: "applescript") {
                managementState.openLocalModels(kind: .appleScript)
            }
        }
        guard query.isEmpty, scope == .onThisMac else { return nil }
        return .init(title: L("Browse Available"), icon: "square.grid.2x2") {
            withAnimation(theme.motion.quick) { scope = .available }
        }
    }

    /// AppleScript models are kept out of the language catalog (they only
    /// emit AppleScript), so a search for them points at their own kind.
    private var searchLooksLikeAppleScript: Bool {
        guard source.kind == .language else { return false }
        let lowered = query.lowercased()
        return lowered.contains("applescript") || lowered.contains("apple script")
    }

    // MARK: - Actions

    private func perform(_ action: LocalModelCatalogItem.Action) {
        if action.confirmation != nil {
            pendingConfirmation = action
        } else {
            action.handler()
        }
    }

    private func inspector(for item: LocalModelCatalogItem) -> some View {
        LocalModelInspector(item: item, model: inspectedModel, onClose: closeInspector, perform: perform)
    }

    private func closeInspector() {
        selection = nil
        inspectedModel = nil
    }

    /// Selects the row for `modelId` (a row id or one of a family's builds)
    /// and opens its panel; waits for the row when it hasn't loaded yet.
    private func select(modelId: String) {
        let lowered = modelId.lowercased()
        guard
            let item = source.items.first(where: { $0.id.lowercased() == lowered })
                ?? source.items.first(where: { $0.variants.contains { $0.id.lowercased() == lowered } })
        else {
            pendingSelectionId = modelId
            return
        }
        pendingSelectionId = nil
        if !scope.includes(item.status) { scope = .all }
        selection = item.id
        if item.id.lowercased() != lowered {
            inspectedModel = item.variants.first { $0.id.lowercased() == lowered }
        }
    }

    /// A Hugging Face model link: search for the repo, make sure it is in
    /// the catalog, and open its row once it lands.
    private func applyModelDeepLink(_ modelId: String) {
        guard let language = source as? LanguageCatalogSource else { return }
        searchText = modelId.split(separator: "/").last.map(String.init) ?? modelId
        query = searchText
        scope = .all
        language.reveal(repoId: modelId)
        select(modelId: modelId)
    }

    /// A one-shot request to open a model's panel (`pendingModelDetailId`).
    private func applyPendingModelDetail() {
        guard source.kind == .language, let pendingId = managementState.pendingModelDetailId else { return }
        guard let model = ModelManager.shared.resolveModel(byRepoId: pendingId) else { return }
        managementState.pendingModelDetailId = nil
        applyModelDeepLink(model.id)
    }

    /// A link that failed with 401/403 parked its repo id; now that a token
    /// exists, resolve it again and open it, or say why it is still refused.
    private func retryDeepLinkAfterTokenSaved() {
        guard let repoId = managementState.pendingDeepLinkRetryModelId else { return }
        managementState.pendingDeepLinkRetryModelId = nil
        Task { @MainActor in
            let resolution = await ModelManager.shared.resolveModelForDeepLink(byRepoId: repoId)
            if case .image = resolution {
                managementState.openLocalModels(kind: .image)
            } else if case .model(let model) = resolution {
                applyModelDeepLink(model.id)
            } else {
                HuggingFaceDeepLinkAlert.present(resolution, modelId: repoId)
            }
        }
    }
}

// MARK: - Language filter chip

private struct LanguageFilterChip: View {
    @ObservedObject var source: LanguageCatalogSource
    @Binding var isPresented: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let summary = LanguageModelFilterPopover.summary(source.filterState)
        FilterChip(
            summary.map { L("Filter: ") + $0 } ?? L("Filter"),
            icon: source.filterState.isActive
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            isSelected: source.filterState.isActive
        ) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            LanguageModelFilterPopover(source: source)
                .environment(\.theme, theme)
        }
        .localizedHelp("Filter models")
    }
}

// MARK: - Live System Status Bar

/// Scopes `SystemMonitorService` observation to the status bar, so the
/// monitor's periodic publishes re-render only this row.
private struct LiveSystemStatusBar: View {
    @ObservedObject private var systemMonitor = SystemMonitorService.shared

    var body: some View {
        SystemStatusBar(
            totalMemoryGB: systemMonitor.totalMemoryGB,
            usedMemoryGB: systemMonitor.usedMemoryGB,
            availableStorageGB: systemMonitor.availableStorageGB,
            totalStorageGB: systemMonitor.totalStorageGB
        )
    }
}

// MARK: - Download failure alert

/// The language download failure alert. Observes `ModelManager` here so its
/// progress publishes don't re-render the whole page.
private struct ModelDownloadAlertHost: ViewModifier {
    @ObservedObject private var modelManager = ModelManager.shared

    func body(content: Content) -> some View {
        content.themedAlert(
            modelManager.downloadAlert?.title ?? L("Model download failed"),
            isPresented: Binding(
                get: { modelManager.downloadAlert != nil },
                set: { if !$0 { modelManager.downloadAlert = nil } }
            ),
            message: modelManager.downloadAlert.map { info in
                "\(info.message)\n\nDetails (tap Copy to share):\n\(info.details)"
            },
            buttons: [
                .cancel(L("Copy details")) {
                    if let details = modelManager.downloadAlert?.details {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(details, forType: .string)
                    }
                    modelManager.downloadAlert = nil
                },
                .primary(L("OK")) { modelManager.downloadAlert = nil },
            ]
        )
    }
}
