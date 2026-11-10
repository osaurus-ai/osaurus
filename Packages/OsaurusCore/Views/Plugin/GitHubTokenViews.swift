//
//  GitHubTokenViews.swift
//  osaurus
//
//  UI for the optional GitHub API token. Anonymous GitHub is capped at
//  60 req/hr per IP, so browsing, importing, or updating plugins fans out
//  enough Contents-API calls to hit a 403. A free token (no scopes needed for
//  public repos) raises the limit to 5,000/hr. A single card at the top of the
//  Plugins tabs is the permanent home: it offers an Add flow when no token is
//  set and lets the user replace or remove an existing one.
//

import SwiftUI

// MARK: - Add-token sheet

/// Sheet presented from the Plugins card's Add button. Explains the benefit,
/// links to GitHub's new-token form, and saves the pasted token to the
/// Keychain.
struct GitHubTokenPromptSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Called after a token is saved so the host can reflect the new state.
    let onSaved: () -> Void

    @State private var tokenInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .glyphSize(20)
                    .foregroundColor(theme.text.link)
                Text("Connect GitHub to update plugins", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
            }

            Text(
                "GitHub limits how often this app can browse and update plugins before it starts showing errors. Connecting a free GitHub account raises that limit so updates keep working.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, text: Text("Sign in (or sign up free) at github.com", bundle: .module))
                // Markdown link deep-links straight to GitHub's new-token form.
                // No scopes are needed to read public plugin repositories.
                stepRow(
                    2,
                    text: Text(
                        .init(
                            L(
                                "Create a token using [this link](https://github.com/settings/tokens/new?description=Osaurus) (no scopes needed)"
                            )
                        )
                    )
                )
                stepRow(3, text: Text("Paste it below. It stays in your macOS Keychain", bundle: .module))
            }

            GitHubTokenField(tokenInput: $tokenInput) { save() }

            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Text("Cancel", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: save) {
                    Label(L("Save token"), systemImage: "checkmark.circle")
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(trimmedToken.isEmpty)
            }
        }
        .padding(theme.space.s24)
        .frame(width: 460)
        .background(theme.surface.canvas)
    }

    private func stepRow(_ number: Int, text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.link)
                .frame(width: 16, height: 16)
                .background(Circle().fill(theme.status.info.background))
            text
                .textStyle(.caption)
                .foregroundColor(theme.text.primary)
                .tint(theme.action.primary.default.background)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedToken.isEmpty else { return }
        GitHubAuth.setToken(trimmedToken)
        // Rebuild the shared service's session so the new token authenticates
        // the very next request instead of after an app restart.
        GitHubSkillService.shared.reloadAuthentication()
        onSaved()
        dismiss()
    }
}

// MARK: - Plugins tab card

/// Permanent card at the top of the Plugins tabs. Offers an Add flow when no
/// token is configured, and Replace / Remove when one is. Owns its own
/// token-presence state so it can flip in place.
struct GitHubTokenCard: View {
    @Environment(\.theme) private var theme

    /// Token presence, seeded synchronously at init. `GitHubAuth` caches the
    /// token in memory and is preloaded off-main at app launch, so this read is
    /// warm by the time Plugins opens — no keychain hit on the render path. The
    /// value only changes through this card's own actions, which set it
    /// directly.
    @State private var hasToken: Bool
    @State private var showAddSheet = false
    @State private var isReplacing = false
    @State private var replaceInput: String = ""

    init() {
        _hasToken = State(initialValue: GitHubAuth.hasToken)
    }

    var body: some View {
        Group {
            if hasToken {
                connectedCard
            } else {
                disconnectedCard
            }
        }
        .sheet(isPresented: $showAddSheet) {
            GitHubTokenPromptSheet {
                hasToken = true
            }
            .environment(\.theme, theme)
        }
    }

    // MARK: Disconnected

    private var disconnectedCard: some View {
        cardSurface {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .glyphSize(15)
                    .foregroundColor(theme.text.link)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop plugin update errors", bundle: .module)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "GitHub limits how often this app can check for updates. Connect a free GitHub account to update plugins without hitting that limit.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button { showAddSheet = true } label: {
                    Label(L("Add Token"), systemImage: "plus.circle")
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
            }
        }
    }

    // MARK: Connected

    private var connectedCard: some View {
        cardSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .glyphSize(15)
                        .foregroundColor(theme.status.success.foreground)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub connected", bundle: .module)
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        Text(
                            "Plugins can now browse and update reliably without hitting GitHub's limit.",
                            bundle: .module
                        )
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        withAnimation(theme.motion.quick) {
                            isReplacing.toggle()
                            replaceInput = ""
                        }
                    } label: {
                        Text(isReplacing ? "Cancel" : "Replace…", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.secondary)
                            .padding(.horizontal, theme.space.s8)
                            .padding(.vertical, theme.space.s6)
                            .settingsChrome(.inset)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button {
                        GitHubAuth.setToken(nil)
                        GitHubSkillService.shared.reloadAuthentication()
                        withAnimation(theme.motion.quick) {
                            isReplacing = false
                            hasToken = false
                        }
                    } label: {
                        Text("Remove", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.destructive)
                }

                if isReplacing {
                    HStack(spacing: 8) {
                        GitHubTokenField(tokenInput: $replaceInput) { replaceToken() }

                        Button(action: replaceToken) {
                            Text("Save", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.primary, size: .compact)
                        .disabled(trimmedReplace.isEmpty)
                    }
                }
            }
        }
    }

    private func cardSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s12)
            .settingsChrome(.subtle)
    }

    private var trimmedReplace: String {
        replaceInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceToken() {
        guard !trimmedReplace.isEmpty else { return }
        GitHubAuth.setToken(trimmedReplace)
        GitHubSkillService.shared.reloadAuthentication()
        withAnimation(theme.motion.quick) {
            isReplacing = false
            replaceInput = ""
        }
    }
}

// MARK: - Shared token field

/// Masked token input shared by the add sheet and the card's replace row.
struct GitHubTokenField: View {
    @Environment(\.theme) private var theme

    @Binding var tokenInput: String
    let onSubmit: () -> Void

    var body: some View {
        SettingsTextField(
            placeholder: "ghp_…",
            text: $tokenInput,
            monospaced: true,
            isSecure: true,
            onSubmit: onSubmit
        )
    }
}
