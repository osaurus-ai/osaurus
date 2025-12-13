//
//  ThemesView.swift
//  osaurus
//
//  Theme gallery and management view with import/export functionality
//

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

struct ThemesView: View {
    @StateObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedThemeId: UUID?
    @State private var editingTheme: IdentifiableTheme?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var themeToExport: CustomTheme?
    @State private var showDeleteConfirmation = false
    @State private var themeToDelete: CustomTheme?
    @State private var successMessage: String?

    private var installedThemes: [CustomTheme] {
        themeManager.installedThemes.sorted { $0.metadata.name < $1.metadata.name }
    }

    private var builtInThemes: [CustomTheme] {
        installedThemes.filter { $0.isBuiltIn }
    }

    private var customThemes: [CustomTheme] {
        installedThemes.filter { !$0.isBuiltIn }
    }

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
                            // Active theme indicator
                            if let activeTheme = themeManager.activeCustomTheme {
                                activeThemeSection(activeTheme)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // Built-in themes
                            if !builtInThemes.isEmpty {
                                themesSection(
                                    title: "Built-in Themes",
                                    count: builtInThemes.count,
                                    themes: builtInThemes
                                )
                                .transition(.opacity)
                            }

                            // Custom themes
                            if !customThemes.isEmpty {
                                themesSection(title: "Custom Themes", count: customThemes.count, themes: customThemes)
                                    .transition(.opacity)
                            }

                            // Empty state for custom themes
                            if customThemes.isEmpty && !builtInThemes.isEmpty {
                                emptyCustomThemesView
                            }
                        }
                        .padding(24)
                    }
                }

                // Success toast
                if let message = successMessage {
                    VStack {
                        Spacer()
                        successToast(message)
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
        .alert("Delete Theme", isPresented: $showDeleteConfirmation, presenting: themeToDelete) { themeToDeleteItem in
            Button("Cancel", role: .cancel) {
                themeToDelete = nil
            }
            Button("Delete", role: .destructive) {
                performDelete(themeToDeleteItem)
            }
        } message: { themeToDeleteItem in
            Text(
                "Are you sure you want to delete \"\(themeToDeleteItem.metadata.name)\"? This action cannot be undone."
            )
        }
    }

    // MARK: - Delete Helper

    private func performDelete(_ theme: CustomTheme) {
        let themeName = theme.metadata.name
        let success = themeManager.deleteTheme(id: theme.metadata.id)
        if success {
            print("[Osaurus] Successfully deleted theme: \(themeName)")
            showSuccess("Deleted \"\(themeName)\"")
        } else {
            print("[Osaurus] Failed to delete theme: \(themeName)")
        }
        themeToDelete = nil
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Themes")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(theme.primaryText)

                        // Total count badge
                        if !isLoading && !installedThemes.isEmpty {
                            Text("\(installedThemes.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                    }

                    Text("Customize the look and feel of your chat interface")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                HStack(spacing: 12) {
                    // Refresh button
                    Button(action: { loadThemes() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 36, height: 36)
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
                    .help("Refresh themes")

                    // Import button
                    Button(action: { showingImporter = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .medium))
                            Text("Import")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 14)
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

                    // Create new theme button
                    Button(action: createNewTheme) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Create Theme")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Loading & Error States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading themes...")
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
                Text("Failed to Load Themes")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: { loadThemes() }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    themeManager.forceReinstallBuiltInThemes(); loadThemes()
                }) {
                    Label("Reinstall Built-ins", systemImage: "arrow.triangle.2.circlepath")
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
                Text("No Themes Found")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Themes could not be loaded. Try reinstalling the built-in themes.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                themeManager.forceReinstallBuiltInThemes(); loadThemes()
            }) {
                Label("Install Built-in Themes", systemImage: "arrow.down.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.successColor)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(theme.cardBackground)
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(theme.successColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func showSuccess(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                successMessage = nil
            }
        }
    }

    private func loadThemes() {
        isLoading = true
        loadError = nil

        // Small delay for visual feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            themeManager.refreshInstalledThemes()

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
                if themeManager.installedThemes.isEmpty {
                    loadError = "No themes could be loaded from disk."
                }
            }
        }
    }

    // MARK: - Active Theme Section

    private func activeThemeSection(_ activeTheme: CustomTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.successColor)

                    Text("Currently Active")
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
                    showSuccess("Reset to default theme")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Reset to Default")
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

                Text("\(count)")
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
                        onApply: {
                            themeManager.applyCustomTheme(themeItem)
                            showSuccess("Applied \"\(themeItem.metadata.name)\"")
                        },
                        onEdit: { openEditor(for: themeItem) },
                        onExport: { exportTheme(themeItem) },
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
                Text("Create Your First Custom Theme")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Design a unique look for your chat interface with custom colors, fonts, and effects")
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
                        Text("Import")
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
                        Text("Create Theme")
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

    // MARK: - Actions

    private func createNewTheme() {
        // Generate unique name
        let baseName = "My Theme"
        let existingNames = Set(installedThemes.map { $0.metadata.name })
        var newName = baseName
        var counter = 1

        while existingNames.contains(newName) {
            counter += 1
            newName = "\(baseName) \(counter)"
        }

        // Start with dark theme as base with unique ID and name
        var newTheme = CustomTheme.darkDefault
        newTheme.metadata = ThemeMetadata(
            id: UUID(),
            name: newName,
            author: "User"
        )
        newTheme.isBuiltIn = false

        // Dismiss any existing editor first, then open new one
        editingTheme = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingTheme = IdentifiableTheme(newTheme)
        }
    }

    private func openEditor(for theme: CustomTheme) {
        // Dismiss any existing editor first
        editingTheme = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editingTheme = IdentifiableTheme(theme)
        }
    }

    private func exportTheme(_ theme: CustomTheme) {
        themeToExport = theme
        showingExporter = true
    }

    private func duplicateTheme(_ themeItem: CustomTheme) {
        // Generate unique copy name
        let baseName = "\(themeItem.metadata.name) Copy"
        let existingNames = Set(installedThemes.map { $0.metadata.name })
        var newName = baseName
        var counter = 1

        while existingNames.contains(newName) {
            counter += 1
            newName = "\(themeItem.metadata.name) Copy \(counter)"
        }

        let duplicated = ThemeConfigurationStore.duplicateTheme(themeItem, newName: newName)
        themeManager.refreshInstalledThemes()
        showSuccess("Duplicated as \"\(newName)\"")
        openEditor(for: duplicated)
    }

    private func confirmDelete(_ theme: CustomTheme) {
        // Don't allow deleting built-in themes
        guard !theme.isBuiltIn else {
            print("[Osaurus] Cannot delete built-in theme: \(theme.metadata.name)")
            return
        }
        themeToDelete = theme
        showDeleteConfirmation = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let imported = try ThemeConfigurationStore.importTheme(from: url)
                themeManager.refreshInstalledThemes()
                showSuccess("Imported \"\(imported.metadata.name)\"")
            } catch {
                print("[Osaurus] Failed to import theme: \(error)")
            }
        case .failure(let error):
            print("[Osaurus] Import failed: \(error)")
        }
    }

    private func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            if let exported = themeToExport {
                showSuccess("Exported \"\(exported.metadata.name)\"")
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
    let onApply: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?

    @Environment(\.theme) private var currentTheme
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Preview area - clickable to apply theme
            previewArea
                .frame(height: 120)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isActive {
                        onApply()
                    }
                }

            // Info and actions
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
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
                                Text("Built-in")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(currentTheme.secondaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(currentTheme.tertiaryBackground)
                                    )
                            }
                        }

                        Text("by \(theme.metadata.author)")
                            .font(.system(size: 11))
                            .foregroundColor(currentTheme.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // Context menu
                    Menu {
                        if !isActive {
                            Button(action: onApply) {
                                Label("Apply Theme", systemImage: "checkmark")
                            }
                        }
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(action: onDuplicate) {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        Button(action: onExport) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        if let onDelete = onDelete {
                            Divider()
                            Button(role: .destructive, action: onDelete) {
                                Label("Delete", systemImage: "trash")
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

                // Color palette preview
                HStack(spacing: 4) {
                    colorSwatch(theme.colors.primaryBackground)
                    colorSwatch(theme.colors.accentColor)
                    colorSwatch(theme.colors.successColor)
                    colorSwatch(theme.colors.warningColor)
                    colorSwatch(theme.colors.errorColor)
                }
            }
            .padding(12)
            .background(currentTheme.cardBackground)
        }
        .background(currentTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive ? currentTheme.accentColor : currentTheme.cardBorder,
                    lineWidth: isActive ? 2 : 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.15 : 0.08),
            radius: isHovered ? 12 : 6,
            x: 0,
            y: isHovered ? 4 : 2
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var previewArea: some View {
        ZStack {
            // Background layer - properly shows solid/gradient/image
            previewBackground

            // Glass overlay simulation
            RoundedRectangle(cornerRadius: 0)
                .fill(.ultraThinMaterial.opacity(0.3))

            // Mock chat UI preview
            VStack(spacing: 6) {
                // Mock header bar
                HStack(spacing: 8) {
                    // Model chip
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(themeHex: theme.colors.successColor))
                            .frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(themeHex: theme.colors.secondaryText).opacity(0.3))
                            .frame(width: 40, height: 8)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.8))
                    )

                    Spacer()

                    // Close button
                    Circle()
                        .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.8))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(Color(themeHex: theme.colors.secondaryText))
                        )
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                // Mock messages with accent bar style
                VStack(spacing: 4) {
                    // User message
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(themeHex: theme.colors.accentColor))
                            .frame(width: 2, height: 20)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(themeHex: theme.colors.secondaryBackground).opacity(0.5))
                            .frame(width: 70, height: 20)
                            .padding(.leading, 6)

                        Spacer()
                    }

                    // Assistant message
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(themeHex: theme.colors.tertiaryText).opacity(0.4))
                            .frame(width: 2, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(themeHex: theme.colors.primaryText).opacity(0.2))
                                .frame(width: 90, height: 8)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(themeHex: theme.colors.primaryText).opacity(0.15))
                                .frame(width: 60, height: 8)
                        }
                        .padding(.leading, 6)

                        Spacer()
                    }
                }
                .padding(.horizontal, 10)

                Spacer()

                // Mock input card
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(themeHex: theme.colors.tertiaryText).opacity(0.3))
                        .frame(width: 60, height: 8)

                    Spacer()

                    Circle()
                        .fill(Color(themeHex: theme.colors.accentColor))
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
                        .fill(Color(themeHex: theme.colors.inputBackground).opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(themeHex: theme.glass.edgeLight).opacity(0.3), lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
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

    @ViewBuilder
    private var previewBackground: some View {
        switch theme.background.type {
        case .solid:
            Color(themeHex: theme.background.solidColor ?? theme.colors.primaryBackground)

        case .gradient:
            let colors =
                (theme.background.gradientColors ?? [theme.colors.primaryBackground, theme.colors.secondaryBackground])
                .map { Color(themeHex: $0) }
            LinearGradient(
                colors: colors,
                startPoint: .top,
                endPoint: .bottom
            )

        case .image:
            if let imageData = theme.background.imageData,
                let data = Data(base64Encoded: imageData),
                let nsImage = NSImage(data: data)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(theme.background.imageOpacity ?? 1.0)
            } else {
                Color(themeHex: theme.colors.primaryBackground)
            }
        }
    }

    private func colorSwatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(themeHex: hex))
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(currentTheme.primaryBorder, lineWidth: 1)
            )
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
