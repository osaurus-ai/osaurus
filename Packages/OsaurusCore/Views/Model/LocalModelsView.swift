//
//  LocalModelsView.swift
//  osaurus
//
//  Models → Local Models: every on-device model kind in one place. The
//  header's tab row picks the kind; each kind renders the same table page
//  (`LocalModelsCatalogPage`) from its catalog source. **Sources** in the header pushes
//  the models folder and the other apps whose models Osaurus may use
//  (`ModelSourcesView`). Which model each job uses by default lives in
//  Models → Model Defaults.
//

import SwiftUI

/// The kinds of on-device model Osaurus downloads.
enum LocalModelKind: String, CaseIterable, Identifiable, Sendable, AnimatedTabItem {
    case language
    case image
    case speech
    case detection
    case appleScript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .language: L("Language")
        case .image: L("Image")
        case .speech: L("Speech")
        case .detection: L("Privacy Detection")
        case .appleScript: L("AppleScript")
        }
    }

    var icon: String {
        switch self {
        case .language: "text.bubble"
        case .image: "photo.on.rectangle.angled"
        case .speech: "waveform"
        case .detection: "eye.slash"
        case .appleScript: "applescript"
        }
    }

    var subtitle: String {
        switch self {
        case .language: L("Chat and vision models that run on this Mac")
        case .image: L("Image generation and editing bundles")
        case .speech: L("Speech-to-text models for voice input and transcription")
        case .detection: L("On-device models that find personal data before it leaves your Mac")
        case .appleScript: L("Models that write and run AppleScript to automate this Mac")
        }
    }
}

struct LocalModelsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    @AppStorage("localModelsKind") private var kindRaw: String = LocalModelKind.language.rawValue
    @StateObject private var sources = LocalModelCatalogSources()
    @State private var showSources = false
    @Environment(\.settingsLandingPending) private var pendingLanding

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var kind: LocalModelKind { LocalModelKind(rawValue: kindRaw) ?? .language }

    var body: some View {
        Group {
            if showSources {
                ModelSourcesView()
                    .settingsBackDestination(L("Local Models"), verbatim: true) { showSources = false }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface.canvas)
                .transition(.opacity)
            } else {
                kindPage
                    .transition(.opacity)
            }
        }
        .animation(theme.motion.quick, value: showSources)
        .onAppear {
            applyPendingKind()
            openSourcesIfLanding(pendingLanding)
        }
        .onChange(of: pendingLanding) { _, id in openSourcesIfLanding(id) }
        .onChange(of: managementState.pendingLocalModelsKind) { _, _ in applyPendingKind() }
        // A Hugging Face model link always targets the language catalog.
        .onChange(of: managementState.pendingModelDeepLink) { _, request in
            if request != nil {
                showSources = false
                kindRaw = LocalModelKind.language.rawValue
            }
        }
    }

    private var kindPage: some View {
        LocalModelsCatalogPage(
            source: sources.source(for: kind),
            kindTabs: AnyView(kindTabs),
            sourcesButton: AnyView(sourcesButton)
        )
        .id(kind)
    }

    private var sourcesButton: some View {
        SettingsButton(
            .secondary,
            "Sources",
            icon: "folder",
            help: "Models folder and models already on this Mac"
        ) {
            withAnimation(theme.motion.quick) { showSources = true }
        }
    }

    private func openSourcesIfLanding(_ id: String?) {
        guard let id, !showSources, ModelSourcesView.anchorIds.contains(id) else { return }
        showSources = true
    }

    private var kindTabs: some View {
        SettingsTabsRow(
            selection: Binding(
                get: { kind },
                set: { kindRaw = $0.rawValue }
            )
        )
        .accessibilityLabel(Text("Model kind", bundle: .module))
        .settingsLandingAnchor("models.kind")
    }

    private func applyPendingKind() {
        guard let requested = managementState.pendingLocalModelsKind else { return }
        managementState.pendingLocalModelsKind = nil
        kindRaw = requested.rawValue
    }
}
