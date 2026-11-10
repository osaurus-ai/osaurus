//
//  ClaudeCodeSetupStep.swift
//  osaurus
//
//  Sign-in surface for a Claude Code harness runtime (onboarding and
//  Settings → Runtimes). Claude Code runs the user's own `claude` binary, so
//  there is no host, no API key, and nothing to put in the Keychain — this
//  step only *reports* the CLI's state and offers to start its sign-in.
//
//  Authentication is delegated to the CLI itself (`claude auth login`), which is
//  the licensed first-party client for a Claude subscription. Osaurus never sees
//  or stores a credential.
//

import SwiftUI

struct ClaudeCodeSetupStep: View {
    /// What the probe found. `.probing` is the pre-result state; it is distinct
    /// from `.signedOut` so the UI never flashes a misleading "not signed in"
    /// before `claude auth status` has answered.
    enum Phase: Equatable {
        case probing
        case resolved(ClaudeCodeSetupState)
    }

    let onBack: () -> Void
    let onDone: () -> Void
    var completionTitle: LocalizedStringKey = "Done"
    var requiresUsableCLI = false
    /// The runtime whose executable and environment are checked; nil means
    /// the `claude` on PATH.
    var runtime: HarnessRuntime? = nil

    @Environment(\.theme) private var theme
    @State private var phase: Phase = .probing
    @State private var signInTask: Task<Void, Never>?

    private var isSigningIn: Bool { signInTask != nil }
    private var command: String { runtime?.executable ?? ClaudeCodeConfiguration.executableName }
    private var overlay: [String: String] { runtime?.environment ?? [:] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    backButton
                    title

                    switch phase {
                    case .probing:
                        probingCard
                    case .resolved(.notInstalled(let searchedPath)):
                        notInstalledCard(searchedPath: searchedPath)
                    case .resolved(.statusUnavailable(let cliVersion)):
                        statusUnavailableCard(cliVersion: cliVersion)
                    case .resolved(.signedOut):
                        signedOutCard
                    case .resolved(.signedIn(let status)):
                        signedInCard(status)
                    }
                }
                .padding(theme.space.s24)
            }

            footer
        }
        .task { await probe() }
        .onDisappear { signInTask?.cancel() }
    }

    // MARK: - Header

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .glyphSize(11, weight: .semibold)
                Text("Back", bundle: .module)
                    .font(SettingsFont.body)
            }
            .foregroundColor(theme.text.secondary)
        }
        .buttonStyle(.plain)
    }

    private var title: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: ClaudeCodeConfiguration.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: "terminal.fill")
                    .glyphSize(16, weight: .medium)
                    .foregroundColor(FixedPalette.onMedia)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code", bundle: .module)
                    .font(SettingsFont.pageTitle)
                    .foregroundColor(theme.text.primary)
                Text("Use your signed-in Claude Code CLI", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }
        }
    }

    // MARK: - State cards

    private var probingCard: some View {
        card {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Checking Claude Code…", bundle: .module)
                    .font(SettingsFont.body)
                    .foregroundColor(theme.text.secondary)
            }
        }
    }

    private func notInstalledCard(searchedPath: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: theme.status.warning.foreground,
                    title: Text("Claude Code isn't installed", bundle: .module),
                    detail: Text(
                        "Osaurus runs your local `claude` command, so Claude Code has to be installed first.",
                        bundle: .module
                    )
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Install it, then come back:", bundle: .module)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.secondary)

                Text(verbatim: "npm install -g @anthropic-ai/claude-code")
                    .font(SettingsFont.monoSmall)
                    .textSelection(.enabled)
                    .padding(theme.space.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.inset)
            }

            DisclosureGroup {
                Text(verbatim: searchedPath.replacingOccurrences(of: ":", with: "\n"))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, theme.space.s6)
            } label: {
                Text("Already installed? Show where Osaurus looked", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }

            Text(
                "A GUI app inherits a narrower PATH than your terminal. If `claude` lives somewhere unusual, symlink it into /usr/local/bin.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                statusRow(
                    icon: "person.crop.circle.badge.questionmark",
                    tint: theme.text.secondary,
                    title: Text("Claude Code isn't signed in", bundle: .module),
                    detail: Text(
                        "Sign in with the Anthropic account that has your Pro or Max subscription.",
                        bundle: .module
                    )
                )
            }

            Button(action: signIn) {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(
                        isSigningIn ? "Waiting for your browser…" : "Sign in with Claude",
                        bundle: .module
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .assignedSettingsButtonStyle(.primary)
            .disabled(isSigningIn)

            HStack(spacing: theme.space.s12) {
                if isSigningIn {
                    SettingsButton(.tertiary, "Cancel Sign-In", size: .compact, action: cancelSignIn)
                }
                SettingsButton(.tertiary, "Sign In from Terminal Instead", size: .compact, action: openTerminalSignIn)
            }

            Text(
                "This opens Claude Code's own sign-in in your browser. Osaurus never sees your credentials. If the browser flow stalls, sign in from Terminal, then choose Re-check.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusUnavailableCard(cliVersion: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                statusRow(
                    icon: "terminal.fill",
                    tint: theme.status.warning.foreground,
                    title: Text("Sign-in status needs a terminal check", bundle: .module),
                    detail: Text(
                        "This Claude Code version doesn't provide machine-readable sign-in status. Osaurus won't guess or inspect its credentials.",
                        bundle: .module
                    )
                )
            }

            if let cliVersion {
                detailRow(label: Text("Installed version", bundle: .module), value: cliVersion)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Open Claude Code and complete sign-in:", bundle: .module)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.secondary)
                Text(verbatim: "claude")
                    .font(SettingsFont.monoSmall)
                    .textSelection(.enabled)
                    .padding(theme.space.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.inset)
            }

            Text(
                "Agents on Claude Code can chat once it's signed in. Updating Claude Code enables status checks and browser sign-in from this screen.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signedInCard(_ status: ClaudeCodeAuthStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                statusRow(
                    icon: "checkmark.circle.fill",
                    tint: theme.status.success.foreground,
                    title: Text("Signed in and ready", bundle: .module),
                    detail: nil
                )
            }

            VStack(spacing: 0) {
                if let email = status.email {
                    detailRow(label: Text("Account", bundle: .module), value: email)
                }
                if let plan = status.displayPlan {
                    Divider().overlay(theme.border.subtle)
                    detailRow(label: Text("Plan", bundle: .module), value: plan)
                }
                if let org = status.orgName, org != status.email {
                    Divider().overlay(theme.border.subtle)
                    detailRow(label: Text("Organization", bundle: .module), value: org)
                }
            }
            .padding(.vertical, theme.space.s4)
            .settingsChrome(.card)

            if status.usesSubscription {
                Text(
                    "Agents on Claude Code can chat now. Requests draw on your subscription's limits, shared with your terminal sessions.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                // Signed in, but through an API key or enterprise gateway — the
                // models still work, they just aren't subscription-billed. Say so
                // rather than implying a subscription is active.
                Text(
                    "This sign-in isn't a Pro or Max subscription, so requests bill through whatever credential Claude Code is configured with. Osaurus removes ANTHROPIC_API_KEY from the environment it starts Claude Code with.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(action: { Task { await probe() } }) {
                Text("Re-check", bundle: .module)
                    .font(SettingsFont.body)
                    .foregroundColor(theme.text.secondary)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s8)
            }
            .buttonStyle(.plain)
            .disabled(phase == .probing || isSigningIn)

            Button(action: onDone) {
                Text(completionTitle, bundle: .module)
            }
            .assignedSettingsButtonStyle(.primary)
            .disabled(requiresUsableCLI && !canComplete)
            .opacity(requiresUsableCLI && !canComplete ? 0.5 : 1)
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(theme.surface.subtle)
    }

    // MARK: - Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.card)
    }

    private func statusRow(
        icon: String,
        tint: Color,
        title: Text,
        detail: Text?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .glyphSize(16, weight: .semibold)
                .foregroundColor(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                title
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                if let detail {
                    detail
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func detailRow(label: Text, value: String) -> some View {
        HStack {
            label
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
            Spacer()
            Text(verbatim: value)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    // MARK: - Actions

    private var canComplete: Bool {
        switch phase {
        case .resolved(.signedIn), .resolved(.statusUnavailable):
            return true
        case .probing, .resolved(.notInstalled), .resolved(.signedOut):
            return false
        }
    }

    private func probe() async {
        phase = .probing
        phase = .resolved(await ClaudeCodeConfiguration.setupState(command: command, overlay: overlay))
    }

    /// Run the CLI's sign-in and refresh in place. `claude auth login` blocks
    /// until the browser round trip finishes, so the button shows a spinner
    /// and Cancel stops the child.
    private func signIn() {
        guard signInTask == nil else { return }
        let command = command
        let overlay = overlay
        signInTask = Task {
            let status = await ClaudeCodeConfiguration.login(command: command, overlay: overlay)
            guard !Task.isCancelled else { return }
            signInTask = nil
            if let status, status.loggedIn {
                phase = .resolved(.signedIn(status))
            } else {
                // Cancelled or failed — re-probe so the UI reflects reality instead
                // of asserting a failure we can't actually distinguish.
                await probe()
            }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        Task { await probe() }
    }

    private func openTerminalSignIn() {
        cancelSignIn()
        Task { await ClaudeCodeConfiguration.openTerminalLogin(command: command, overlay: overlay) }
    }
}
