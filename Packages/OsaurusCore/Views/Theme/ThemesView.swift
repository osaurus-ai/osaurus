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

private enum ThemeLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case imported
    case shared
    case needsReview
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .local: return "Local"
        case .imported: return "Imported"
        case .shared: return "Shared"
        case .needsReview: return "Needs Review"
        case .duplicates: return "Duplicates"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .local: return "paintbrush.pointed"
        case .imported: return "tray.and.arrow.down"
        case .shared: return "link"
        case .needsReview: return "exclamationmark.triangle"
        case .duplicates: return "doc.on.doc"
        }
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

    /// Cached partitions of `themeManager.installedThemes`. Recomputed only
    /// when the publisher fires, not on every parent body redraw, so
    /// scroll-induced re-evaluations no longer re-sort + re-filter the
    /// full theme list.
    @State private var installedThemes: [CustomTheme] = []
    @State private var builtInThemes: [CustomTheme] = []
    @State private var customThemes: [CustomTheme] = []
    @State private var libraryFilter: ThemeLibraryFilter = .all
    @State private var validationReports: [UUID: ThemeValidationReport] = [:]
    @State private var duplicateGroups: [ThemeDuplicateGroup] = []
    @State private var librarySummary: ThemeLibrarySummary = .empty
    @State private var previewCacheHealth: ThemePreviewCacheHealth = .empty
    @State private var showRollbackConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            ZStack {
                if isLoading {
                    loadingView
                } else if let error = loadError {
                    errorView(error)
                } else if installedThemes.isEmpty {
                    noThemesView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            let visibleBuiltInThemes = filteredThemes(builtInThemes)
                            let visibleCustomThemes = filteredThemes(customThemes)

                            themeLibraryManagementCenter
                                .transition(.opacity)

                            // Active theme indicator
                            if let activeTheme = themeManager.activeCustomTheme {
                                activeThemeSection(activeTheme)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // Built-in themes
                            if !visibleBuiltInThemes.isEmpty {
                                themesSection(
                                    title: L("Built-in Themes"),
                                    count: visibleBuiltInThemes.count,
                                    themes: visibleBuiltInThemes
                                )
                                .transition(.opacity)
                            }

                            // Custom themes
                            if !visibleCustomThemes.isEmpty {
                                themesSection(
                                    title: customSectionTitle,
                                    count: visibleCustomThemes.count,
                                    themes: visibleCustomThemes
                                )
                                .transition(.opacity)
                            }

                            // Community gallery discovery banner
                            communityThemesBanner
                                .transition(.opacity)

                            // Empty state for custom themes
                            if customThemes.isEmpty && !builtInThemes.isEmpty && libraryFilter == .all {
                                emptyCustomThemesView
                            }

                            if libraryFilter != .all && visibleBuiltInThemes.isEmpty && visibleCustomThemes.isEmpty {
                                emptyFilteredThemesView
                            }
                        }
                        .padding(24)
                    }
                }

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

    // MARK: - Delete Helper

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

    // MARK: - Header

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

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Themes"),
            subtitle: L("Customize the look and feel of your chat interface"),
            count: isLoading || installedThemes.isEmpty ? nil : installedThemes.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh themes") {
                loadThemes()
            }
            importMenuButton
            HeaderPrimaryButton("Create Theme", icon: "plus") {
                createNewTheme()
            }
        }
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
                    themeManager.forceReinstallBuiltInThemes(); loadThemes()
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
                themeManager.forceReinstallBuiltInThemes(); loadThemes()
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

    // MARK: - Library Management Center

    private var themeLibraryManagementCenter: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Theme Library", bundle: .module)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Validate, filter, deduplicate, and recover installed themes.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    libraryActionButton(
                        title: "Rollback",
                        icon: "arrow.uturn.backward",
                        disabled: themeManager.activeCustomTheme == nil
                    ) {
                        showRollbackConfirmation = true
                    }

                    libraryActionButton(title: "Clear Cache", icon: "trash") {
                        clearPreviewCache()
                    }
                }
            }

            libraryStatGrid
            previewCacheHealthRow
            libraryFilterBar

            if !duplicateGroups.isEmpty {
                duplicateOverview
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.primaryBorder.opacity(0.55), lineWidth: 1)
                )
        )
    }

    private var libraryStatGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)],
            spacing: 10
        ) {
            libraryStatTile("Local", count: librarySummary.localCount, icon: "paintbrush.pointed", color: theme.accentColor)
            libraryStatTile("Imported", count: librarySummary.importedCount, icon: "tray.and.arrow.down", color: theme.infoColor)
            libraryStatTile("Shared", count: librarySummary.sharedCount, icon: "link", color: theme.successColor)
            libraryStatTile("Issues", count: librarySummary.validationErrorCount + librarySummary.validationWarningCount, icon: "exclamationmark.triangle", color: issueStatColor)
            libraryStatTile("Duplicate Sets", count: librarySummary.duplicateGroupCount, icon: "doc.on.doc", color: duplicateGroups.isEmpty ? theme.tertiaryText : theme.warningColor)
        }
    }

    private func libraryStatTile(_ title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(color.opacity(0.14)))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)", bundle: .module)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.cardBorder.opacity(0.8), lineWidth: 1)
                )
        )
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
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.cardBorder.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private var libraryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ThemeLibraryFilter.allCases) { filter in
                    Button {
                        withAnimation(theme.animationQuick()) {
                            libraryFilter = filter
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(LocalizedStringKey(filter.title), bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(libraryFilter == filter ? Color.white : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(libraryFilter == filter ? theme.accentColor : theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var duplicateOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.warningColor)
                Text("Duplicate detection", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button {
                    withAnimation(theme.animationQuick()) {
                        libraryFilter = .duplicates
                    }
                } label: {
                    Text("Review", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }

            ForEach(duplicateGroups.prefix(2)) { group in
                Text(group.members.map(\.name).joined(separator: "  •  "))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.warningColor.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private var emptyFilteredThemesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30))
                .foregroundColor(theme.tertiaryText)
            Text("No themes match this filter", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Button {
                withAnimation(theme.animationQuick()) {
                    libraryFilter = .all
                }
            } label: {
                Text("Show All Themes", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func libraryActionButton(
        title: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(disabled ? theme.tertiaryText : theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder.opacity(disabled ? 0.35 : 1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
        return "\(previewCacheHealth.cachedEntryCount) images, \(cost) tracked of \(limit), \(previewCacheHealth.inFlightDecodeCount) decoding, \(previewCacheHealth.failedDecodeCount) failed decodes"
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

    private var customSectionTitle: String {
        switch libraryFilter {
        case .all: return L("Custom Themes")
        case .local: return "Local Themes"
        case .imported: return "Imported Themes"
        case .shared: return "Shared Themes"
        case .needsReview: return "Themes Needing Review"
        case .duplicates: return "Duplicate Themes"
        }
    }

    /// Sort once, partition once. Called on initial load and whenever
    /// `ThemeManager` republishes its installed list.
    private func refreshPartitions(from themes: [CustomTheme]) {
        let sorted = themes.sorted { $0.metadata.name < $1.metadata.name }
        installedThemes = sorted
        builtInThemes = sorted.filter { $0.isBuiltIn }
        customThemes = sorted.filter { !$0.isBuiltIn }
        let reports = ThemeLibraryManagementService.validationReports(for: sorted)
        let reportMap = Dictionary(uniqueKeysWithValues: reports.map { ($0.themeID, $0) })
        let duplicates = ThemeLibraryManagementService.duplicateGroups(in: sorted)
        validationReports = reportMap
        duplicateGroups = duplicates
        librarySummary = ThemeLibraryManagementService.summary(
            for: sorted,
            reports: reports,
            duplicateGroups: duplicates
        )
        refreshPreviewCacheHealth()
    }

    private func filteredThemes(_ themes: [CustomTheme]) -> [CustomTheme] {
        themes.filter(shouldShowTheme(_:))
    }

    private func shouldShowTheme(_ themeItem: CustomTheme) -> Bool {
        switch libraryFilter {
        case .all:
            return true
        case .local:
            return ThemeLibraryManagementService.source(for: themeItem) == .local
        case .imported:
            return ThemeLibraryManagementService.source(for: themeItem) == .imported
        case .shared:
            return ThemeLibraryManagementService.source(for: themeItem) == .shared
        case .needsReview:
            return validationReports[themeItem.metadata.id]?.needsReview == true
        case .duplicates:
            return duplicateThemeIDs.contains(themeItem.metadata.id)
        }
    }

    private var duplicateThemeIDs: Set<UUID> {
        Set(duplicateGroups.flatMap { $0.members.map(\.id) })
    }

    private func duplicateGroupSize(for themeItem: CustomTheme) -> Int {
        duplicateGroups.first { group in
            group.members.contains { $0.id == themeItem.metadata.id }
        }?.count ?? 0
    }

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

    // MARK: - Active Theme Section

    private func activeThemeSection(_ activeTheme: CustomTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
    }

    // MARK: - Themes Section

    private func themesSection(title: String, count: Int, themes: [CustomTheme]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("\(count)", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.tertiaryBackground)
                    )

                Spacer()
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 280, maximum: 350), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(themes, id: \.metadata.id) { themeItem in
                    let isActive = themeManager.activeCustomTheme?.metadata.id == themeItem.metadata.id

                    ThemePreviewCard(
                        theme: themeItem,
                        isActive: isActive,
                        source: ThemeLibraryManagementService.source(for: themeItem),
                        validationReport: validationReports[themeItem.metadata.id],
                        duplicateGroupSize: duplicateGroupSize(for: themeItem),
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
            }
        }
    }

    // MARK: - Empty State

    private var emptyCustomThemesView: some View {
        VStack(spacing: 20) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.15), theme.accentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 32))
                    .foregroundColor(theme.accentColor)
            }

            VStack(spacing: 6) {
                Text("Create Your First Custom Theme", bundle: .module)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(
                    "Design a unique look for your chat interface with custom colors, fonts, and effects",
                    bundle: .module
                )
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            }

            HStack(spacing: 14) {
                Button(action: { showingImporter = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                        Text("Import", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: createNewTheme) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Create Theme", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.primaryBorder.opacity(0.6), lineWidth: 1)
                )
        )
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

    // MARK: - Actions

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
    let duplicateGroupSize: Int
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
        duplicateGroupSize: Int,
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
        self.duplicateGroupSize = duplicateGroupSize
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
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: isActive ? 2 : 1)
        )
        // Static shadow (no hover-driven radius/offset). Dynamic shadow
        // forces an offscreen render pass per state change and was a
        // significant scroll cost when `onHover` fires while the cursor
        // crosses cells.
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
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
        .frame(height: 120)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { onApply() }
        }
    }

    private var cardInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                titleBlock
                Spacer(minLength: 8)
                cardActionMenu
            }
            swatchRow
        }
        .padding(12)
        .background(currentTheme.cardBackground)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(theme.metadata.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(currentTheme.primaryText)
                    .lineLimit(1)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(currentTheme.successColor)
                }

                if theme.isBuiltIn {
                    sourceBadge("Built-in", color: currentTheme.secondaryText)
                } else {
                    sourceBadge(sourceLabel(source), color: sourceColor(source))
                }

                if let validationReport, validationReport.needsReview {
                    validationBadge(validationReport)
                }

                if duplicateGroupSize > 1 {
                    sourceBadge("Duplicate", color: currentTheme.warningColor)
                }
            }

            Text("by \(theme.metadata.author)", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(currentTheme.tertiaryText)
                .lineLimit(1)
        }
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
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12
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
