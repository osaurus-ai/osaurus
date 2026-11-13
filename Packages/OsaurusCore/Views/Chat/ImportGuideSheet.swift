//
//  ImportGuideSheet.swift
//  osaurus
//
//  Pre-import guide presented as themed-alert custom content. Shows
//  non-technical users how to obtain an export from each supported
//  provider before the file open panel appears. A persisted "don't
//  show again" toggle skips straight to the panel on later imports.
//

import AppKit
import SwiftUI

/// Persisted opt-out for the pre-import guide. Unlike the delete
/// confirmation's session-scoped skip, this survives relaunches: once a
/// user knows how to export, the guide is pure friction.
@MainActor
final class ImportGuidePreference: ObservableObject {
    static let shared = ImportGuidePreference()
    private static let key = "ImportGuideSkip"

    @Published var skip: Bool {
        didSet { UserDefaults.standard.set(skip, forKey: Self.key) }
    }

    private init() {
        skip = UserDefaults.standard.bool(forKey: Self.key)
    }
}

struct ImportGuideSheet: View {
    /// Whether the "Don't show this again" checkbox is rendered. The
    /// sidebar's repeatable Import button keeps it; the one-time
    /// post-onboarding prompt hides it because that prompt can never
    /// appear a second time anyway.
    var showsSkipToggle: Bool = true

    /// Invoked when the user taps Choose File. The caller is
    /// responsible for dismissing the alert and opening the panel.
    let onChooseFile: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var pref = ImportGuidePreference.shared
    /// Accordion state: the one provider whose export recipe is expanded.
    @State private var expandedProviderId: String?

    private let contentWidth: CGFloat = 420

    private struct Provider: Identifiable {
        let id: String
        let name: String
        let recipe: LocalizedStringKey
        let exportURL: URL?
    }

    private var providers: [Provider] {
        [
            Provider(
                id: "chatgpt",
                name: "ChatGPT",
                recipe: "Settings → Data controls → Export data. The download link arrives by email as a zip file.",
                exportURL: URL(string: "https://chatgpt.com/#settings/DataControls")
            ),
            Provider(
                id: "claude",
                name: "Claude",
                recipe:
                    "Settings → Privacy → Export data. The download link arrives by email. Large accounts are split into several batch zip files plus an index JSON: import each batch zip, not the index.",
                exportURL: URL(string: "https://claude.ai/settings/data-privacy-controls")
            ),
            Provider(
                id: "grok",
                name: "Grok",
                recipe: "Settings → Data controls → Export account data. The download link arrives by email.",
                exportURL: URL(string: "https://grok.com/settings")
            ),
            Provider(
                id: "gemini",
                name: "Gemini",
                recipe: "In Google Takeout, select My Activity → Gemini Apps and create the export. The zip contains MyActivity.json.",
                exportURL: URL(string: "https://takeout.google.com/")
            ),
            Provider(
                id: "openwebui",
                name: "Open WebUI",
                recipe: "Settings → Data Controls → Export Chats downloads a JSON file right away. A single chat can also be exported from its own menu via Download → Export as JSON.",
                exportURL: nil
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            Text(
                "Bring conversations from other AI apps into Osaurus and continue them with any model. Export your chats first:",
                bundle: .module
            )
            .textStyle(.bodySmall)
            .foregroundColor(theme.text.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.bottom, theme.space.s12)

            VStack(spacing: theme.space.s6) {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            }

            Text(
                "Then choose the downloaded file below. You can select several files at once.",
                bundle: .module
            )
            .textStyle(.caption)
            .foregroundColor(theme.text.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, theme.space.s12)

            ThemeHairlineDivider()
                .padding(.top, theme.space.s14)

            HStack {
                if showsSkipToggle {
                    Toggle(isOn: $pref.skip) {
                        Text("Don't show this again", bundle: .module)
                            .textStyle(.caption)
                            .foregroundColor(theme.text.secondary)
                    }
                    .toggleStyle(.checkbox)
                }

                Spacer()

                SettingsButton(.primary, "Choose File…", action: onChooseFile)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, theme.space.s12)
        }
        .frame(width: contentWidth)
    }

    private func providerRow(_ provider: Provider) -> some View {
        let isExpanded = expandedProviderId == provider.id
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            Button {
                withAnimation(theme.motion.springAnimation) {
                    expandedProviderId = isExpanded ? nil : provider.id
                }
            } label: {
                HStack(spacing: theme.space.s10) {
                    Text(provider.name)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                HStack(alignment: .top, spacing: theme.space.s10) {
                    Text(provider.recipe, bundle: .module)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let url = provider.exportURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .glyphSize(.label, weight: .medium)
                                .foregroundColor(theme.text.link)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .localizedHelp("Open export page")
                    }
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.bottom, theme.space.s10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(theme.surface.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .stroke(isExpanded ? theme.border.strong : theme.border.default, lineWidth: theme.stroke.default)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
    }
}
