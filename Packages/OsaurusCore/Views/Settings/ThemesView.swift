//
//  ThemesView.swift
//  osaurus
//
//  General → Appearance → Theme. The bundled presets and the user's themes
//  as a card grid: pick one, make a new one, duplicate, edit (simple
//  editor or JSON), import and export. Files live in
//  `~/.osaurus/themes/library`; external edits are picked up when the
//  window regains focus.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = ThemeLibraryStore.shared
    @StateObject private var previews = ThemePreviewCache()

    let onBack: () -> Void

    @State private var editing: ThemeEditorRequest?
    @State private var editingJSON: ThemeDocument?
    /// Opened once the editor sheet has finished dismissing.
    @State private var pendingJSON: ThemeDocument?
    @State private var pendingDelete: ThemeDocument?
    @State private var errorMessage: String?
    @State private var hasAppeared = false

    private var activeId: UUID { themeManager.activeThemeId ?? ThemePresets.osaurusID }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Themes",
                subtitle: "Colors, type and readability for every window",
                count: store.all.count,
                primary: {
                    SettingsButton(.primary, "New Theme", icon: "plus") {
                        editing = ThemeEditorRequest(document: store.makeNew(basedOn: themeManager.activeTheme), isNew: true)
                    }
                },
                overflow: {
                    Button(L("Import Theme…")) { importTheme() }
                    Button(L("Export Active Theme…")) { export(themeManager.activeTheme) }
                    Divider()
                    Button(L("Show Themes Folder")) {
                        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.directory)
                    }
                }
            )
        } content: {
            if themeManager.systemIncreaseContrast {
                SettingsCallout(
                    icon: "circle.lefthalf.filled",
                    title: L("Increase Contrast is on"),
                    message: L("macOS Increase Contrast is on, so every theme uses its high-contrast colors.")
                )
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: theme.libraryGridGap, alignment: .top)],
                spacing: theme.libraryGridGap
            ) {
                ForEach(Array(store.all.enumerated()), id: \.element.id) { index, document in
                    card(document, index: index)
                }
            }
            .settingsLandingAnchor("settings.general.themes")
        }
        .settingsBackDestination("General") { onBack() }
        .sheet(item: $editing, onDismiss: {
            editingJSON = pendingJSON
            pendingJSON = nil
        }) { request in
            ThemeEditorSheet(
                original: request.document,
                isNew: request.isNew,
                onEditJSON: { saved in
                    pendingJSON = saved
                    editing = nil
                },
                onClose: { editing = nil }
            )
        }
        .sheet(item: $editingJSON) { document in
            ThemeJSONSheet(original: document, onClose: { editingJSON = nil })
        }
        .themedAlert(
            L("Delete Theme?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            message: pendingDelete.map { L("“\($0.name)” will be moved to the Trash.") },
            primaryButton: .destructive(L("Delete")) {
                if let document = pendingDelete { delete(document) }
                pendingDelete = nil
            },
            secondaryButton: .cancel(L("Cancel")) { pendingDelete = nil }
        )
        .themedAlert(
            L("Theme Error"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            message: errorMessage,
            primaryButton: .cancel(L("OK")) { errorMessage = nil }
        )
        .onAppear {
            store.reload()
            hasAppeared = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
        .task(id: PreviewKey(documents: store.all, highContrast: themeManager.systemIncreaseContrast)) {
            await previews.refresh(store.all, highContrast: themeManager.systemIncreaseContrast)
        }
    }

    private struct PreviewKey: Equatable {
        let documents: [ThemeDocument]
        let highContrast: Bool
    }

    // MARK: Card

    private func card(_ document: ThemeDocument, index: Int) -> some View {
        let isPreset = store.isPreset(document.id)
        let isActive = document.id == activeId
        let entry = previews.entry(for: document)
        return LibraryCard(
            title: document.name,
            subtitle: summary(document),
            isSelected: isActive,
            minHeight: 0,
            help: L("Use this theme"),
            animationDelay: Double(index) * 0.03,
            hasAppeared: hasAppeared,
            action: { themeManager.setActiveTheme(document.id) },
            hero: {
                if let entry {
                    SettingsThemeCardHero(modes: entry.modes)
                } else {
                    SettingsThemeCardHero(modes: [theme])
                }
            },
            leading: { EmptyView() },
            badges: {
                if isActive { StatusChip(L("Active"), tone: .accent) }
                if isPreset { StatusChip(L("Built-in")) }
                if let entry, !entry.contrastFindings.isEmpty {
                    StatusChip(
                        L("Low contrast"), tone: .warning, icon: "exclamationmark.triangle",
                        help: entry.contrastFindings.prefix(3).map(\.message).joined(separator: "\n")
                    )
                }
            },
            menu: {
                if !isPreset {
                    Button(L("Edit…")) { editing = ThemeEditorRequest(document: document, isNew: false) }
                }
                Button(L("Duplicate")) { duplicate(document) }
                if !isPreset {
                    Button(L("Edit JSON…")) { editingJSON = document }
                }
                Button(L("Export…")) { export(document) }
                if !isPreset {
                    Button(L("Reveal in Finder")) { store.revealInFinder(id: document.id) }
                    Divider()
                    Button(L("Delete…"), role: .destructive) { pendingDelete = document }
                }
            }
        )
    }

    private func summary(_ document: ThemeDocument) -> String {
        var parts: [String] = []
        switch document.appearance {
        case .both: parts.append(L("Light and dark"))
        case .light: parts.append(L("Light only"))
        case .dark: parts.append(L("Dark only"))
        }
        parts.append(document.preferences.tone.label)
        switch document.preferences.accent {
        case .swatch(let swatch): parts.append(swatch.label)
        case .custom: parts.append(L("Custom accent"))
        }
        if document.preferences.contrast == .high { parts.append(L("High contrast")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func duplicate(_ document: ThemeDocument) {
        do {
            let copy = try store.duplicate(id: document.id)
            editing = ThemeEditorRequest(document: copy, isNew: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ document: ThemeDocument) {
        do {
            try store.delete(id: document.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose Osaurus theme files to import")
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        var lastImported: ThemeDocument?
        for url in panel.urls {
            do {
                lastImported = try store.importTheme(from: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let lastImported, failures.isEmpty, panel.urls.count == 1 {
            themeManager.setActiveTheme(lastImported.id)
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private func export(_ document: ThemeDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(document.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(id: document.id, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ThemeEditorRequest: Identifiable {
    let document: ThemeDocument
    let isNew: Bool
    var id: UUID { document.id }
}

// MARK: - Preview Cache

/// Compiled light/dark themes for the cards, built off the main actor.
@MainActor
final class ThemePreviewCache: ObservableObject {
    struct Entry {
        let modes: [any ThemeProtocol]
        let contrastFindings: [ThemeContrastFinding]
    }

    @Published private var entries: [ThemeDocument: Entry] = [:]
    private var highContrast = false

    func entry(for document: ThemeDocument) -> Entry? { entries[document] }

    func refresh(_ documents: [ThemeDocument], highContrast: Bool) async {
        if highContrast != self.highContrast {
            entries = [:]
            self.highContrast = highContrast
        }
        let wanted = Set(documents)
        entries = entries.filter { wanted.contains($0.key) }
        for document in documents where entries[document] == nil {
            guard !Task.isCancelled else { return }
            guard let compiled = try? await ThemeCompiler.compileDetached(document, highContrast: highContrast) else {
                continue
            }
            entries[document] = Self.entry(document, compiled)
        }
    }

    static func entry(_ document: ThemeDocument, _ compiled: ThemeCompiledTheme) -> Entry {
        let scale = ThemeManager.fontScale
        let light = CustomizableTheme(resolved: compiled.snapshot.light, fontScale: scale)
        let dark = CustomizableTheme(resolved: compiled.snapshot.dark, fontScale: scale)
        let modes: [any ThemeProtocol]
        switch document.appearance {
        case .both: modes = [light, dark]
        case .light: modes = [light]
        case .dark: modes = [dark]
        }
        return Entry(modes: modes, contrastFindings: compiled.contrastFindings)
    }
}
