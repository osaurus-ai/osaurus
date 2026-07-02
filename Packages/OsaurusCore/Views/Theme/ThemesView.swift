//
//  ThemesView.swift
//  osaurus
//
//  Theme gallery and management view with import/export functionality
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Wrapper to make CustomTheme work with sheet(item:)
struct IdentifiableTheme: Identifiable {
    let id: UUID
    let theme: CustomTheme

    init(_ theme: CustomTheme) {
        self.id = theme.metadata.id
        self.theme = theme
    }
}

// MARK: - Theme Filter

/// Single source of truth for the gallery's filtering taxonomy. Replaces the
/// previous dual system (non-interactive stat tiles + a separate chip row with
/// mismatched names). Counts live on the tabs themselves.
enum ThemeFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case builtIn
    case local
    case imported
    case shared
    case needsReview
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("All")
        case .builtIn: return L("Built-in")
        case .local: return L("Local")
        case .imported: return L("Imported")
        case .shared: return L("Shared")
        case .needsReview: return L("Needs Review")
        case .duplicates: return L("Duplicates")
        }
    }

    /// Filters that flag library problems get a warning-styled badge instead
    /// of a neutral count.
    var isAttentionFilter: Bool { self == .needsReview || self == .duplicates }
}

/// Drives the header `AnimatedTabSelector`, so the Themes filter row matches
/// the segmented control used by every other settings tab. `title` and the
/// `Hashable`/`CaseIterable` conformances above satisfy the protocol.
extension ThemeFilter: AnimatedTabItem {}

/// Precomputed membership used by `themeMatches`. Built once per data change so
/// the per-theme predicate never rebuilds sets.
struct ThemeFilterContext {
    let needsReviewIDs: Set<UUID>
    let duplicateIDs: Set<UUID>

    static let empty = ThemeFilterContext(needsReviewIDs: [], duplicateIDs: [])
}

/// Pure, side-effect-free predicate deciding whether a theme is visible under
/// the current filter + search. Extracted so the filtering rules are unit
/// testable and computed exactly once per change rather than inside `body`.
func themeMatches(
    _ theme: CustomTheme,
    filter: ThemeFilter,
    search: String,
    context: ThemeFilterContext
) -> Bool {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        let matchesName = theme.metadata.name.range(of: trimmed, options: .caseInsensitive) != nil
        let matchesAuthor = theme.metadata.author.range(of: trimmed, options: .caseInsensitive) != nil
        if !matchesName && !matchesAuthor { return false }
    }

    switch filter {
    case .all:
        return true
    case .builtIn:
        return theme.isBuiltIn
    case .local:
        return ThemeLibraryManagementService.source(for: theme) == .local
    case .imported:
        return ThemeLibraryManagementService.source(for: theme) == .imported
    case .shared:
        return ThemeLibraryManagementService.source(for: theme) == .shared
    case .needsReview:
        return context.needsReviewIDs.contains(theme.metadata.id)
    case .duplicates:
        return context.duplicateIDs.contains(theme.metadata.id)
    }
}

struct ThemesView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var editingTheme: IdentifiableTheme?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var themeToExport: CustomTheme?
    @State private var showDeleteConfirmation = false
    @State private var themeToDelete: CustomTheme?
    @State private var toastMessage: String?
    @State private var toastType: SimpleToastType = .success
    @State private var sharingTheme: IdentifiableTheme?
    @State private var showingImportByIdSheet = false
    @State private var importByIdInitialHash: String?
    /// When true, the next successful Import-by-ID completion should also
    /// apply the imported theme. Set by the deeplink flow so users land on
    /// the theme they just clicked to install.
    @State private var applyAfterImportById = false

    // MARK: Filtering / search

    @State private var selectedFilter: ThemeFilter = .all
    @State private var searchText: String = ""
    @State private var showLibraryHealth = false

    // MARK: Cached partitions + derived state
    //
    // Recomputed only when `ThemeManager` republishes (not on every parent
    // body redraw), so scroll-induced re-evaluations no longer re-sort,
    // re-validate, or re-filter the full theme list.
    @State private var installedThemes: [CustomTheme] = []
    @State private var builtInThemes: [CustomTheme] = []
    @State private var customThemes: [CustomTheme] = []
    @State private var visibleThemes: [CustomTheme] = []
    @State private var validationByID: [UUID: ThemeValidationReport] = [:]
    @State private var needsReviewIDs: Set<UUID> = []
    @State private var duplicateIDs: Set<UUID> = []
    @State private var librarySummary: ThemeLibrarySummary = .empty
    @State private var filterCounts: [ThemeFilter: Int] = [:]
    @State private var previewCacheHealth: ThemePreviewCacheHealth = .empty
    @State private var showRollbackConfirmation = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ZStack {
                contentView
                    .settingsLandingAnchor("themes.appearance")

                if let message = toastMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(message, type: toastType)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadThemes()
            applyPendingThemeInstall()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(item: $editingTheme) { identifiableTheme in
            ThemeEditorView(
                theme: identifiableTheme.theme,
                onDismiss: {
                    editingTheme = nil
                }
            )
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, UTType(filenameExtension: "osaurus-theme") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: themeToExport.map { ThemeDocument(theme: $0) },
            contentType: .json,
            defaultFilename: themeToExport?.metadata.name ?? "theme"
        ) { result in
            handleExport(result)
        }
        .sheet(item: $sharingTheme) { identifiable in
            ShareThemeSheet(themeToShare: identifiable.theme) { outcome in
                markThemeShared(identifiable.theme, outcome: outcome)
                showToast(L("Theme shared"))
            }
        }
        .sheet(isPresented: $showingImportByIdSheet) {
            ImportThemeByIdSheet(
                initialInput: importByIdInitialHash,
                onCompleted: { imported in
                    if applyAfterImportById {
                        themeManager.applyCustomTheme(imported)
                        showToast(L("Applied \"\(imported.metadata.name)\""))
                    } else {
                        showToast(L("Imported \"\(imported.metadata.name)\""))
                    }
                    importByIdInitialHash = nil
                    applyAfterImportById = false
                },
                onError: { message in
                    showToast(L("Import failed: \(message)"), type: .error)
                    importByIdInitialHash = nil
                    applyAfterImportById = false
                }
            )
        }
        .onReceive(managementState.$pendingThemeInstallHash) { _ in
            applyPendingThemeInstall()
        }
        .onReceive(themeManager.$installedThemes) { latest in
            refreshPartitions(from: latest)
        }
        .onChange(of: selectedFilter) { _, _ in
            withAnimation(theme.animationQuick()) {
                recomputeVisible()
            }
        }
        .onChange(of: searchText) { _, _ in
            recomputeVisible()
        }
        .themedAlert(
            L("Delete Theme"),
            isPresented: Binding(
                get: { showDeleteConfirmation && themeToDelete != nil },
                set: { newValue in
                    if !newValue {
                        showDeleteConfirmation = false
                        themeToDelete = nil
                    }
                }
            ),
            message: themeToDelete.map {
                L("Are you sure you want to delete \"\($0.metadata.name)\"? This action cannot be undone.")
            },
            primaryButton: .destructive(L("Delete")) {
                if let theme = themeToDelete {
                    performDelete(theme)
                }
                showDeleteConfirmation = false
                themeToDelete = nil
            },
            secondaryButton: .cancel(L("Cancel")) {
                showDeleteConfirmation = false
                themeToDelete = nil
            }
        )
        .themedAlert(
            String(localized: "Rollback to Default", bundle: .module),
            isPresented: $showRollbackConfirmation,
            message: String(
                localized:
                    "Clear the active custom theme and return to the built-in theme for the current appearance mode? Installed themes will stay in the library.",
                bundle: .module
            ),
            primaryButton: .destructive(String(localized: "Rollback", bundle: .module)) {
                rollbackToDefaultTheme()
            },
            secondaryButton: .cancel(L("Cancel")) {}
        )
    }

    // MARK: - Content Switch

    @ViewBuilder
    private var contentView: some View {
        if isLoading {
            loadingView
        } else if let error = loadError {
            errorView(error)
        } else if installedThemes.isEmpty {
            noThemesView
        } else {
            themeBrowser
        }
    }

    // MARK: - Header

    private var showsFilterToolbar: Bool {
        !isLoading && loadError == nil && !installedThemes.isEmpty
    }

    @ViewBuilder
    private var headerView: some View {
        if showsFilterToolbar {
            ManagerHeaderWithTabs(
                title: L("Themes"),
                subtitle: L("Customize the look and feel of your chat interface"),
                count: installedThemes.count
            ) {
                headerActions
            } tabsRow: {
                filterToolbar
            }
        } else {
            ManagerHeaderWithActions(
                title: L("Themes"),
                subtitle: L("Customize the look and feel of your chat interface"),
                count: installedThemes.isEmpty ? nil : installedThemes.count
            ) {
                headerActions
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HeaderIconButton("arrow.clockwise", help: "Refresh themes") {
            loadThemes()
        }
        manageMenuButton
        importMenuButton
        HeaderPrimaryButton("Create Theme", icon: "plus") {
            createNewTheme()
        }
    }

    /// Combined "Import" entry point. A single menu so the header row fits
    /// even on narrow window widths and the two import flavours sit
    /// together semantically.
    private var importMenuButton: some View {
        Menu {
            Button {
                showingImporter = true
            } label: {
                Label {
                    Text("From File…", bundle: .module)
                } icon: {
                    Image(systemName: "doc")
                }
            }
            Button {
                importByIdInitialHash = nil
                applyAfterImportById = false
                showingImportByIdSheet = true
            } label: {
                Label {
                    Text("From Link or ID…", bundle: .module)
                } icon: {
                    Image(systemName: "link")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                Text("Import", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Overflow menu housing the library maintenance tools that used to clutter
    /// the gallery. Keeps every feature reachable while the default view stays
    /// clean.
    private var manageMenuButton: some View {
        Menu {
            Button {
                clearPreviewCache()
            } label: {
                Label {
                    Text("Clear Preview Cache", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }

            Button {
                showRollbackConfirmation = true
            } label: {
                Label {
                    Text("Rollback to Default", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
            .disabled(themeManager.activeCustomTheme == nil)

            Button {
                themeManager.forceReinstallBuiltInThemes()
                loadThemes()
            } label: {
                Label {
                    Text("Reinstall Built-in Themes", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }

            Divider()

            Toggle(isOn: $showLibraryHealth.animation(theme.animationQuick())) {
                Label {
                    Text("Library Health", bundle: .module)
                } icon: {
                    Image(systemName: "waveform.path.ecg")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Manage library", bundle: .module))
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        // Mirror the segmented control every other settings tab uses. Neutral
        // counts ride the `counts` slot; the library-health filters (Needs
        // Review, Duplicates) ride `badges` so they keep their warning accent.
        let neutralCounts = filterCounts.filter { !$0.key.isAttentionFilter }
        let attentionBadges = filterCounts.filter { $0.key.isAttentionFilter && $0.value > 0 }
        return HStack(spacing: 12) {
            AnimatedTabSelector(
                selection: $selectedFilter,
                tabs: availableFilters,
                counts: neutralCounts,
                badges: attentionBadges.isEmpty ? nil : attentionBadges
            )

            Spacer(minLength: 12)

            SearchField(text: $searchText, placeholder: "Search themes", width: 220, compact: true)
        }
    }

    /// Only surface filters that currently have results (All is always shown).
    /// A theme that just lost its last imported/shared member therefore can't
    /// strand the user on an empty tab.
    private func availableFilters(from counts: [ThemeFilter: Int]) -> [ThemeFilter] {
        // `allCases` is declared in tab order (all, builtIn, local, …), so a
        // straight filter preserves the layout while dropping empty tabs.
        ThemeFilter.allCases.filter { $0 == .all || (counts[$0] ?? 0) > 0 }
    }

    private var availableFilters: [ThemeFilter] {
        availableFilters(from: filterCounts)
    }

    // MARK: - Theme Browser

    private var isDefaultBrowsing: Bool {
        selectedFilter == .all && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var themeBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showLibraryHealth {
                    libraryHealthPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let activeTheme = themeManager.activeCustomTheme {
                    activeThemeSection(activeTheme)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isDefaultBrowsing {
                    defaultBrowsingContent
                } else {
                    filteredContent
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var defaultBrowsingContent: some View {
        if !builtInThemes.isEmpty {
            themesSection(
                title: L("Built-in Themes"),
                count: builtInThemes.count,
                themes: builtInThemes
            )
            .transition(.opacity)
        }

        if !customThemes.isEmpty {
            themesSection(
                title: L("Custom Themes"),
                count: customThemes.count,
                themes: customThemes
            )
            .transition(.opacity)
        } else {
            firstThemeCTA
        }

        communityThemesBanner
            .transition(.opacity)
    }

    @ViewBuilder
    private var filteredContent: some View {
        if visibleThemes.isEmpty {
            noResultsView
        } else {
            themesSection(
                title: searchActive ? L("Search Results") : sectionTitle(for: selectedFilter),
                count: visibleThemes.count,
                subtitle: resultsSubtitle,
                themes: visibleThemes
            )
            .transition(.opacity)
        }
    }

    private func sectionTitle(for filter: ThemeFilter) -> String {
        switch filter {
        case .all: return L("All Themes")
        case .builtIn: return L("Built-in Themes")
        case .local: return L("Local Themes")
        case .imported: return L("Imported Themes")
        case .shared: return L("Shared Themes")
        case .needsReview: return L("Themes Needing Review")
        case .duplicates: return L("Duplicate Themes")
        }
    }

    private var resultsSubtitle: String {
        L("\(visibleThemes.count) of \(installedThemes.count) themes")
    }

    // MARK: - Loading & Error States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading themes...", bundle: .module)
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(theme.warningColor)

            VStack(spacing: 4) {
                Text("Failed to Load Themes", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: { loadThemes() }) {
                    Label {
                        Text("Retry", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    themeManager.forceReinstallBuiltInThemes()
                    loadThemes()
                }) {
                    Label {
                        Text("Reinstall Built-ins", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noThemesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 48))
                .foregroundColor(theme.tertiaryText)

            VStack(spacing: 4) {
                Text("No Themes Found", bundle: .module)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Themes could not be loaded. Try reinstalling the built-in themes.", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                themeManager.forceReinstallBuiltInThemes()
                loadThemes()
            }) {
                Label {
                    Text("Install Built-in Themes", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Library Health Panel

    private var libraryHealthPanel: some View {
        SettingsSection(title: "Library Health", icon: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 12) {
                previewCacheHealthRow

                HStack(spacing: 10) {
                    healthStat(
                        icon: "exclamationmark.triangle",
                        title: "Issues",
                        value: librarySummary.validationErrorCount + librarySummary.validationWarningCount,
                        color: issueStatColor,
                        reviewFilter: .needsReview
                    )
                    healthStat(
                        icon: "doc.on.doc",
                        title: "Duplicate Sets",
                        value: librarySummary.duplicateGroupCount,
                        color: librarySummary.duplicateGroupCount == 0 ? theme.tertiaryText : theme.warningColor,
                        reviewFilter: .duplicates
                    )
                }
            }
        }
    }

    private var previewCacheHealthRow: some View {
        HStack(spacing: 10) {
            Image(systemName: previewCacheHealth.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(previewCacheHealth.isHealthy ? theme.successColor : theme.warningColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Preview cache health", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(verbatim: cacheHealthSummary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                refreshPreviewCacheHealth()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(.plain)
            .help(Text("Refresh cache health", bundle: .module))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
    }

    private func healthStat(
        icon: String,
        title: String,
        value: Int,
        color: Color,
        reviewFilter: ThemeFilter
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color.opacity(0.14)))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(value)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if value > 0 && (filterCounts[reviewFilter] ?? 0) > 0 {
                Button {
                    withAnimation(theme.animationQuick()) {
                        selectedFilter = reviewFilter
                    }
                } label: {
                    Text("Review", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
    }

    private var issueStatColor: Color {
        if librarySummary.validationErrorCount > 0 { return theme.errorColor }
        if librarySummary.validationWarningCount > 0 { return theme.warningColor }
        return theme.successColor
    }

    private var cacheHealthSummary: String {
        let cost = ByteCountFormatter.string(
            fromByteCount: Int64(previewCacheHealth.cachedCostBytes),
            countStyle: .file
        )
        let limit = ByteCountFormatter.string(
            fromByteCount: Int64(previewCacheHealth.totalCostLimit),
            countStyle: .file
        )
        return
            L(
                "\(previewCacheHealth.cachedEntryCount) images, \(cost) tracked of \(limit), \(previewCacheHealth.inFlightDecodeCount) decoding, \(previewCacheHealth.failedDecodeCount) failed decodes"
            )
    }

    // MARK: - Active Theme Section

    private func activeThemeSection(_ activeTheme: CustomTheme) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.successColor)

                Text("Currently Active", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(activeTheme.metadata.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(theme.successColor.opacity(0.15))
                    )
            }

            Spacer()

            Button(action: {
                themeManager.clearCustomTheme()
                showToast(L("Reset to default theme"))
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Reset to Default", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.successColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.successColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Themes Section

    private func themesSection(
        title: String,
        count: Int,
        subtitle: String? = nil,
        themes: [CustomTheme]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.tertiaryBackground)
                    )

                Spacer()

                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(themes, id: \.metadata.id) { themeItem in
                    card(for: themeItem)
                }
            }
        }
    }

    private func card(for themeItem: CustomTheme) -> some View {
        let isActive = themeManager.activeCustomTheme?.metadata.id == themeItem.metadata.id
        return ThemePreviewCard(
            theme: themeItem,
            isActive: isActive,
            source: ThemeLibraryManagementService.source(for: themeItem),
            validationReport: validationByID[themeItem.metadata.id],
            isDuplicate: duplicateIDs.contains(themeItem.metadata.id),
            onApply: {
                themeManager.applyCustomTheme(themeItem)
                showToast(L("Applied \"\(themeItem.metadata.name)\""))
            },
            onEdit: { openEditor(for: themeItem) },
            onExport: { exportTheme(themeItem) },
            onShare: { shareTheme(themeItem) },
            onDuplicate: { duplicateTheme(themeItem) },
            onDelete: themeItem.isBuiltIn ? nil : { confirmDelete(themeItem) }
        )
    }

    // MARK: - Empty / No-result States

    /// Compact first-run call to action shown beneath the built-in grid when
    /// the user has no custom themes yet. Built-ins stay visible above so a
    /// fresh user can apply one immediately while being nudged to create.
    private var firstThemeCTA: some View {
        SettingsEmptyState(
            icon: "paintbrush.pointed.fill",
            title: L("Create Your First Theme"),
            subtitle: L("Design a unique look for your chat with custom colors, fonts, and backgrounds."),
            examples: [
                .init(
                    icon: "paintpalette.fill",
                    title: L("Pick a Palette"),
                    description: L("Colors and accents")
                ),
                .init(
                    icon: "photo.fill",
                    title: L("Set a Backdrop"),
                    description: L("Solid, gradient, or image")
                ),
                .init(
                    icon: "sparkles",
                    title: L("Share It"),
                    description: L("Publish to the community")
                ),
            ],
            primaryAction: .init(
                title: L("Create Theme"),
                icon: "plus",
                handler: { createNewTheme() }
            ),
            secondaryAction: .init(
                title: L("Import"),
                icon: "square.and.arrow.down",
                handler: { showingImporter = true }
            ),
            hasAppeared: hasAppeared
        )
        .frame(minHeight: 440)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.primaryBorder.opacity(0.6), lineWidth: 1)
                )
        )
    }

    private var noResultsView: some View {
        VStack(spacing: 14) {
            Image(systemName: searchActive ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(theme.tertiaryText)

            VStack(spacing: 6) {
                Text(searchActive ? "No themes found" : "No themes match this filter", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(verbatim: noResultsSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                clearFiltersAndSearch()
            } label: {
                Text(searchActive ? "Clear Search" : "Show All Themes", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var noResultsSubtitle: String {
        if searchActive {
            return L("No themes match \"\(searchText)\". Try a different search.")
        }
        return L("Nothing here yet for this category.")
    }

    private func clearFiltersAndSearch() {
        withAnimation(theme.animationQuick()) {
            searchText = ""
            selectedFilter = .all
            recomputeVisible()
        }
    }

    // MARK: - Community Themes Banner

    /// Footer call-to-action linking out to the community theme gallery.
    /// Placed at the end of the list so it reads as "get more" rather than
    /// competing with the header's primary Import / Create actions.
    private var communityThemesBanner: some View {
        Button(action: openCommunityThemes) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.18), theme.accentColor.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse Community Themes", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Discover and install more themes shared by the Osaurus community", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.secondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.primaryBorder.opacity(0.6), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("Open osaurus.ai/themes", bundle: .module))
    }

    private func openCommunityThemes() {
        if let url = URL(string: "https://osaurus.ai/themes") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Data: partitions + filtering

    /// Sort once, validate once, partition once, and precompute every set the
    /// filter predicate needs. Called on initial load and whenever
    /// `ThemeManager` republishes its installed list. Everything is computed
    /// into locals first, then assigned to `@State` in one pass so the active
    /// filter + visible list never read stale derived state.
    private func refreshPartitions(from themes: [CustomTheme]) {
        let sorted = themes.sorted {
            $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending
        }
        let built = sorted.filter { $0.isBuiltIn }
        let custom = sorted.filter { !$0.isBuiltIn }

        let reports = ThemeLibraryManagementService.validationReports(for: sorted)
        let reportMap = Dictionary(uniqueKeysWithValues: reports.map { ($0.themeID, $0) })
        let reviewIDs = Set(reports.filter { $0.needsReview }.map { $0.themeID })

        let groups = ThemeLibraryManagementService.duplicateGroups(in: sorted)
        let dupIDs = Set(groups.flatMap { $0.members.map(\.id) })

        let summary = ThemeLibraryManagementService.summary(
            for: sorted,
            reports: reports,
            duplicateGroups: groups
        )
        let counts = computeFilterCounts(sorted, reviewIDs: reviewIDs, duplicateIDs: dupIDs)

        var nextFilter = selectedFilter
        if !availableFilters(from: counts).contains(nextFilter) {
            nextFilter = .all
        }

        let context = ThemeFilterContext(needsReviewIDs: reviewIDs, duplicateIDs: dupIDs)
        let visible = sorted.filter {
            themeMatches($0, filter: nextFilter, search: searchText, context: context)
        }

        installedThemes = sorted
        builtInThemes = built
        customThemes = custom
        validationByID = reportMap
        needsReviewIDs = reviewIDs
        duplicateIDs = dupIDs
        librarySummary = summary
        filterCounts = counts
        selectedFilter = nextFilter
        visibleThemes = visible

        refreshPreviewCacheHealth()
    }

    private func computeFilterCounts(
        _ themes: [CustomTheme],
        reviewIDs: Set<UUID>,
        duplicateIDs: Set<UUID>
    ) -> [ThemeFilter: Int] {
        var counts: [ThemeFilter: Int] = [
            .all: themes.count,
            .needsReview: reviewIDs.count,
            .duplicates: duplicateIDs.count,
        ]
        for theme in themes {
            switch ThemeLibraryManagementService.source(for: theme) {
            case .builtIn: counts[.builtIn, default: 0] += 1
            case .local: counts[.local, default: 0] += 1
            case .imported: counts[.imported, default: 0] += 1
            case .shared: counts[.shared, default: 0] += 1
            }
        }
        return counts
    }

    /// Recompute the visible list from already-published caches. Used by the
    /// filter/search `onChange` handlers (the data set itself is unchanged).
    private func recomputeVisible() {
        let context = ThemeFilterContext(needsReviewIDs: needsReviewIDs, duplicateIDs: duplicateIDs)
        visibleThemes = installedThemes.filter {
            themeMatches($0, filter: selectedFilter, search: searchText, context: context)
        }
    }

    // MARK: - Cache / maintenance

    private func refreshPreviewCacheHealth() {
        Task {
            let snapshot = await ThemePreviewImageCache.shared.healthSnapshot()
            await MainActor.run {
                previewCacheHealth = snapshot
            }
        }
    }

    private func clearPreviewCache() {
        Task {
            await ThemePreviewImageCache.shared.removeAll()
            let snapshot = await ThemePreviewImageCache.shared.healthSnapshot()
            await MainActor.run {
                previewCacheHealth = snapshot
                showToast(String(localized: "Preview cache cleared", bundle: .module))
            }
        }
    }

    private func rollbackToDefaultTheme() {
        ThemeConfigurationStore.rollbackActiveThemeToDefault()
        themeManager.clearCustomTheme()
        themeManager.refreshInstalledThemes()
        refreshPartitions(from: themeManager.installedThemes)
        showToast(String(localized: "Rolled back to the default theme", bundle: .module))
    }

    private func markThemeShared(_ themeItem: CustomTheme, outcome: ThemeShareOutcome) {
        guard !themeItem.isBuiltIn else { return }
        _ = ThemeConfigurationStore.markThemeShared(
            id: themeItem.metadata.id,
            hash: outcome.hash,
            serverURL: outcome.serverURL
        )
        themeManager.refreshInstalledThemes()
    }

    private func loadThemes() {
        isLoading = true
        loadError = nil

        // Small delay for visual feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            themeManager.refreshInstalledThemes()
            refreshPartitions(from: themeManager.installedThemes)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
                if themeManager.installedThemes.isEmpty {
                    loadError = "No themes could be loaded from disk."
                }
            }
        }
    }

    // MARK: - Actions

    private func performDelete(_ theme: CustomTheme) {
        let themeName = theme.metadata.name
        let success = themeManager.deleteTheme(id: theme.metadata.id)
        if success {
            print("[Osaurus] Successfully deleted theme: \(themeName)")
            showToast(L("Deleted \"\(themeName)\""))
        } else {
            print("[Osaurus] Failed to delete theme: \(themeName)")
        }
        themeToDelete = nil
    }

    private func showToast(_ message: String, type: SimpleToastType = .success) {
        withAnimation(theme.springAnimation()) {
            toastType = type
            toastMessage = message
        }
        let duration: Double = type == .error ? 4.0 : 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(theme.animationQuick()) {
                toastMessage = nil
            }
        }
    }

    private func createNewTheme() {
        var newTheme = CustomTheme.darkDefault
        newTheme.metadata = ThemeMetadata(
            id: UUID(),
            name: uniqueThemeName(base: "My Theme"),
            author: "User"
        )
        newTheme.isBuiltIn = false
        newTheme.library = ThemeLibraryInfo(source: .local)
        openEditor(for: newTheme)
    }

    /// Dismiss any open editor, then re-present with the requested theme on
    /// the next runloop tick. The brief detour avoids a SwiftUI glitch where
    /// presenting a new sheet while an old one is still tearing down can
    /// leave the editor hidden behind the parent.
    private func openEditor(for theme: CustomTheme) {
        editingTheme = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingTheme = IdentifiableTheme(theme)
        }
    }

    private func exportTheme(_ theme: CustomTheme) {
        themeToExport = theme
        showingExporter = true
    }

    private func shareTheme(_ theme: CustomTheme) {
        sharingTheme = IdentifiableTheme(theme)
    }

    /// Honor a pending `osaurus://themes-install?hash=…` deeplink request.
    /// Opens the Import-by-ID sheet pre-populated with the hash so the
    /// user can confirm before the network round-trip.
    private func applyPendingThemeInstall() {
        guard let hash = managementState.pendingThemeInstallHash, !hash.isEmpty else { return }
        importByIdInitialHash = hash
        applyAfterImportById = true
        showingImportByIdSheet = true
        managementState.pendingThemeInstallHash = nil
    }

    private func duplicateTheme(_ themeItem: CustomTheme) {
        let newName = uniqueThemeName(base: "\(themeItem.metadata.name) Copy")
        let duplicated = ThemeConfigurationStore.duplicateTheme(themeItem, newName: newName)
        themeManager.refreshInstalledThemes()
        showToast(L("Duplicated as \"\(newName)\""))
        openEditor(for: duplicated)
    }

    private func confirmDelete(_ theme: CustomTheme) {
        guard !theme.isBuiltIn else {
            print("[Osaurus] Cannot delete built-in theme: \(theme.metadata.name)")
            return
        }
        themeToDelete = theme
        showDeleteConfirmation = true
    }

    /// Returns `base` if it isn't already in use, otherwise `<base> N` where
    /// N is the smallest integer ≥ 2 yielding an unused name.
    private func uniqueThemeName(base: String) -> String {
        let existing = Set(installedThemes.map { $0.metadata.name })
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let imported = try ThemeConfigurationStore.importTheme(from: url)
                themeManager.refreshInstalledThemes()
                showToast(L("Imported \"\(imported.metadata.name)\""))
            } catch {
                print("[Osaurus] Failed to import theme: \(error)")
                showToast(L("Import failed: \(error.localizedDescription)"), type: .error)
            }
        case .failure(let error):
            print("[Osaurus] Import failed: \(error)")
            showToast(L("Import failed: \(error.localizedDescription)"), type: .error)
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if let exported = themeToExport {
                showToast(L("Exported \"\(exported.metadata.name)\""))
            }
            themeToExport = nil
        case .failure(let error):
            print("[Osaurus] Export failed: \(error)")
        }
    }
}

// MARK: - Theme Preview Card

struct ThemePreviewCard: View {
    let theme: CustomTheme
    let isActive: Bool
    let source: ThemeLibrarySource
    let validationReport: ThemeValidationReport?
    let isDuplicate: Bool
    let onApply: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?

    @Environment(\.theme) private var currentTheme
    @State private var isHovered = false
    @State private var cachedImage: NSImage?

    /// Pre-resolved `Color` values for the previewed theme. Built once per
    /// card construction so the heavy preview body doesn't re-parse hex
    /// strings (15+ per render) on every scroll-induced re-evaluation.
    private let resolved: ResolvedThemePreviewColors
    private let backgroundDescriptor: ThemePreviewArt.BackgroundDescriptor

    init(
        theme: CustomTheme,
        isActive: Bool,
        source: ThemeLibrarySource,
        validationReport: ThemeValidationReport?,
        isDuplicate: Bool,
        onApply: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onDelete: (() -> Void)?
    ) {
        self.theme = theme
        self.isActive = isActive
        self.source = source
        self.validationReport = validationReport
        self.isDuplicate = isDuplicate
        self.onApply = onApply
        self.onEdit = onEdit
        self.onExport = onExport
        self.onShare = onShare
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.resolved = ResolvedThemePreviewColors(theme)
        self.backgroundDescriptor = ThemePreviewArt.BackgroundDescriptor(theme: theme)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArt
            cardInfo
        }
        .background(currentTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: isActive ? 2 : 1)
        )
        // Static shadow (no hover-driven radius/offset). Dynamic shadow
        // forces an offscreen render pass per state change and was a
        // significant scroll cost when `onHover` fires while the cursor
        // crosses cells.
        .shadow(
            color: Color.black.opacity(isActive ? 0.12 : 0.07),
            radius: isActive ? 10 : 6,
            x: 0,
            y: isActive ? 4 : 2
        )
        .onHover { isHovered = $0 }
        .task(id: theme.metadata.id) {
            cachedImage = await ThemePreviewImageCache.shared.image(for: theme)
        }
    }

    /// The chat-mockup hero area. Wrapped in `.equatable()` so SwiftUI can
    /// skip re-rendering its heavy subtree when only hover state changes.
    private var previewArt: some View {
        ThemePreviewArt(
            themeID: theme.metadata.id,
            resolved: resolved,
            background: backgroundDescriptor,
            cachedImage: cachedImage
        )
        .equatable()
        .frame(height: 124)
        .overlay(alignment: .topTrailing) {
            if isActive {
                activePill
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { onApply() }
        }
    }

    private var activePill: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Active", bundle: .module)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(currentTheme.accentColor))
        .padding(8)
    }

    private var cardInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleBlock
                Spacer(minLength: 8)
                cardActionMenu
            }
            badgeRow
            swatchRow
            applyButton
        }
        .padding(12)
        .background(currentTheme.cardBackground)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(theme.metadata.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(currentTheme.primaryText)
                .lineLimit(1)

            Text("by \(theme.metadata.author)", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(currentTheme.tertiaryText)
                .lineLimit(1)
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            if theme.isBuiltIn {
                sourceBadge("Built-in", color: currentTheme.secondaryText)
            } else {
                sourceBadge(sourceLabel(source), color: sourceColor(source))
            }

            if let validationReport, validationReport.needsReview {
                validationBadge(validationReport)
            }

            if isDuplicate {
                sourceBadge("Duplicate", color: currentTheme.warningColor)
            }

            Spacer(minLength: 0)
        }
    }

    private var applyButton: some View {
        Button(action: { if !isActive { onApply() } }) {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "paintbrush.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(isActive ? "Active" : "Apply Theme", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(isActive ? currentTheme.successColor : Color.white)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? currentTheme.successColor.opacity(0.14) : currentTheme.accentColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isActive)
    }

    private var cardActionMenu: some View {
        Menu {
            if !isActive {
                Button(action: onApply) {
                    Label {
                        Text("Apply Theme", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button(action: onEdit) {
                Label {
                    Text("Edit", bundle: .module)
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            Button(action: onDuplicate) {
                Label {
                    Text("Duplicate", bundle: .module)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            Button(action: onExport) {
                Label {
                    Text("Export", bundle: .module)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Button(action: onShare) {
                Label {
                    Text("Share", bundle: .module)
                } icon: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
            }
            if let onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label {
                        Text("Delete", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
                .foregroundColor(currentTheme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var swatchRow: some View {
        HStack(spacing: 4) {
            colorSwatch(resolved.primaryBackground)
            colorSwatch(resolved.accent)
            colorSwatch(resolved.success)
            colorSwatch(resolved.warning)
            colorSwatch(resolved.error)
        }
    }

    private var borderColor: Color {
        if isActive { return currentTheme.accentColor }
        if isHovered { return currentTheme.accentColor.opacity(0.5) }
        return currentTheme.cardBorder
    }

    private func colorSwatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(currentTheme.primaryBorder, lineWidth: 1)
            )
    }

    private func sourceBadge(_ label: String, color: Color) -> some View {
        Text(LocalizedStringKey(label), bundle: .module)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
    }

    private func validationBadge(_ report: ThemeValidationReport) -> some View {
        HStack(spacing: 3) {
            Image(systemName: report.errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
            Text(LocalizedStringKey(report.errorCount > 0 ? "Invalid" : "Review"), bundle: .module)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(report.errorCount > 0 ? currentTheme.errorColor : currentTheme.warningColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill((report.errorCount > 0 ? currentTheme.errorColor : currentTheme.warningColor).opacity(0.14))
        )
        .help(Text(verbatim: validationHelp(report)))
    }

    private func sourceLabel(_ source: ThemeLibrarySource) -> String {
        switch source {
        case .builtIn: return "Built-in"
        case .local: return "Local"
        case .imported: return "Imported"
        case .shared: return "Shared"
        }
    }

    private func sourceColor(_ source: ThemeLibrarySource) -> Color {
        switch source {
        case .builtIn: return currentTheme.secondaryText
        case .local: return currentTheme.accentColor
        case .imported: return currentTheme.infoColor
        case .shared: return currentTheme.successColor
        }
    }

    private func validationHelp(_ report: ThemeValidationReport) -> String {
        if let first = report.issues.first {
            return "\(first.field): \(first.message)"
        }
        return "Theme validation passed"
    }
}

// MARK: - Resolved Preview Colors

/// Pre-resolved `Color` values used by `ThemePreviewArt` and the swatch
/// row. Building this once per card construction avoids re-parsing the
/// same hex strings on every body re-evaluation. `Color` is `Equatable`,
/// so this struct is trivially `Equatable` and cheap to compare.
private struct ResolvedThemePreviewColors: Equatable {
    let primaryBackground: Color
    let secondaryBackground: Color
    let inputBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let success: Color
    let warning: Color
    let error: Color
    let glassEdgeLight: Color

    init(_ theme: CustomTheme) {
        self.primaryBackground = Color(themeHex: theme.colors.primaryBackground)
        self.secondaryBackground = Color(themeHex: theme.colors.secondaryBackground)
        self.inputBackground = Color(themeHex: theme.colors.inputBackground)
        self.primaryText = Color(themeHex: theme.colors.primaryText)
        self.secondaryText = Color(themeHex: theme.colors.secondaryText)
        self.tertiaryText = Color(themeHex: theme.colors.tertiaryText)
        self.accent = Color(themeHex: theme.colors.accentColor)
        self.success = Color(themeHex: theme.colors.successColor)
        self.warning = Color(themeHex: theme.colors.warningColor)
        self.error = Color(themeHex: theme.colors.errorColor)
        self.glassEdgeLight = Color(themeHex: theme.glass.edgeLight)
    }
}

// MARK: - Theme Preview Art

/// The heavy chat-mockup preview rendered above each card. Conforms to
/// `Equatable` so a parent `.equatable()` wrapper can short-circuit
/// re-rendering when only the card's hover state changes.
private struct ThemePreviewArt: View, Equatable {
    let themeID: UUID
    let resolved: ResolvedThemePreviewColors
    let background: BackgroundDescriptor
    let cachedImage: NSImage?

    nonisolated static func == (lhs: ThemePreviewArt, rhs: ThemePreviewArt) -> Bool {
        lhs.themeID == rhs.themeID
            && lhs.resolved == rhs.resolved
            && lhs.background == rhs.background
            && lhs.cachedImage === rhs.cachedImage
    }

    var body: some View {
        ZStack {
            previewBackground

            // Static, cheap sheen replacing the previous `.ultraThinMaterial`
            // overlay. The material forced a per-frame backdrop blur on
            // every visible card, which dominated scroll cost.
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.black.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 6) {
                headerBar
                messageStack
                Spacer()
                inputCard
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 14
            )
        )
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(resolved.success)
                    .frame(width: 5, height: 5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(resolved.secondaryText.opacity(0.3))
                    .frame(width: 40, height: 8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(resolved.secondaryBackground.opacity(0.8))
            )

            Spacer()

            Circle()
                .fill(resolved.secondaryBackground.opacity(0.8))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(resolved.secondaryText)
                )
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var messageStack: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(resolved.accent)
                    .frame(width: 2, height: 20)

                RoundedRectangle(cornerRadius: 4)
                    .fill(resolved.secondaryBackground.opacity(0.5))
                    .frame(width: 70, height: 20)
                    .padding(.leading, 6)

                Spacer()
            }

            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(resolved.tertiaryText.opacity(0.4))
                    .frame(width: 2, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(resolved.primaryText.opacity(0.2))
                        .frame(width: 90, height: 8)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(resolved.primaryText.opacity(0.15))
                        .frame(width: 60, height: 8)
                }
                .padding(.leading, 6)

                Spacer()
            }
        }
        .padding(.horizontal, 10)
    }

    private var inputCard: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(resolved.tertiaryText.opacity(0.3))
                .frame(width: 60, height: 8)

            Spacer()

            Circle()
                .fill(resolved.accent)
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(resolved.inputBackground.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(resolved.glassEdgeLight.opacity(0.3), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var previewBackground: some View {
        switch background.kind {
        case .solid(let color):
            color
        case .gradient(let colors):
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        case .image:
            if let cachedImage {
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(background.imageOpacity)
            } else {
                resolved.primaryBackground
            }
        }
    }

    /// Stable, small description of the theme background. We pre-resolve
    /// the color cases here so the body never re-parses hex strings, and
    /// we avoid storing the (potentially huge) base64 image payload in
    /// the view's identity – the decoded `NSImage` is delivered out-of-band
    /// via `cachedImage`.
    struct BackgroundDescriptor: Equatable {
        enum Kind: Equatable {
            case solid(Color)
            case gradient([Color])
            case image
        }

        let kind: Kind
        let imageOpacity: Double

        init(theme: CustomTheme) {
            self.imageOpacity = theme.background.imageOpacity ?? 1.0
            switch theme.background.type {
            case .solid:
                let hex = theme.background.solidColor ?? theme.colors.primaryBackground
                self.kind = .solid(Color(themeHex: hex))
            case .gradient:
                let hexes =
                    theme.background.gradientColors
                    ?? [theme.colors.primaryBackground, theme.colors.secondaryBackground]
                self.kind = .gradient(hexes.map { Color(themeHex: $0) })
            case .image:
                self.kind = .image
            }
        }
    }
}

// MARK: - Theme Document for Export

struct ThemeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var theme: CustomTheme

    init(theme: CustomTheme) {
        self.theme = theme
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        theme = try decoder.decode(CustomTheme.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(theme)
        return FileWrapper(regularFileWithContents: data)
    }
}
