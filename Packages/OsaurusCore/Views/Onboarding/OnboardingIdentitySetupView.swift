//
//  OnboardingIdentitySetupView.swift
//  osaurus
//
//  Onboarding step 4 — claim a cryptographic master identity. Three internal
//  phases (prompt → generating → recovery code) swap inside the body slot
//  so the chrome stays still.
//
//  Visual model: the master identity is the root of trust everything else
//  derives from (agents, devices, osk-v1 access keys, Bonjour pairing).
//  See docs/IDENTITY.md.
//

import AppKit
import SwiftUI

// MARK: - Phase

enum OnboardingIdentityPhase: Equatable {
    case prompt
    case generating
    case recovery(IdentityInfo)
    case alreadyExists
    case error(String)

    static func == (lhs: OnboardingIdentityPhase, rhs: OnboardingIdentityPhase) -> Bool {
        switch (lhs, rhs) {
        case (.prompt, .prompt): return true
        case (.generating, .generating): return true
        case (.recovery(let a), .recovery(let b)): return a.osaurusId == b.osaurusId
        case (.alreadyExists, .alreadyExists): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - State

@MainActor
final class IdentityState: ObservableObject {
    @Published var phase: OnboardingIdentityPhase = .prompt

    /// A footer caption that nudges the user about the recovery code rules
    /// only on the recovery phase. Other phases hide it.
    var footerCaption: LocalizedStringKey? {
        switch phase {
        case .recovery:
            return "Your recovery phrase is shown once. Save it before you continue."
        case .prompt, .generating, .alreadyExists, .error:
            return nil
        }
    }

    func generate() {
        // If a master already exists, jump straight past identity setup —
        // re-running onboarding (e.g., after the version bump in
        // OnboardingService) must never silently regenerate the master and
        // strand all derived agent / access keys.
        if OsaurusIdentity.exists() {
            phase = .alreadyExists
            return
        }

        phase = .generating
        // No `withAnimation` wrappers below — the body has its own
        // `.animation(value: phaseID)` modifier scoped to the phase ZStack.
        // Wrapping here would propagate to the CTA (which observes `phase`)
        // and morph the button between phases.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let info = try await OsaurusIdentity.setup()
                if info.mnemonic == nil {
                    // setup() short-circuited because a key already exists.
                    // Surface that state explicitly rather than rendering a
                    // blank recovery card.
                    self.phase = .alreadyExists
                } else {
                    self.phase = .recovery(info)
                }
            } catch {
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    /// Persist the user-facing acknowledgement that they have saved the BIP39
    /// recovery phrase. Drives the banner in `IdentityView.MasterAddressSection`
    /// on subsequent launches.
    func acknowledgeBackup() {
        UserDefaults.standard.set(true, forKey: IdentityDefaultsKey.masterMnemonicAcknowledged)
    }
}

// MARK: - Body

struct IdentityBody: View {
    @ObservedObject var state: IdentityState

    @Environment(\.theme) private var theme

    /// Sample master address taken straight from `docs/IDENTITY.md`. Used
    /// only as a visual preview before the real one is generated, so the
    /// abstract "cryptographic address" idea has a concrete shape.
    private static let previewMasterAddress =
        "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18"

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-identity",
            leftHeadline: leftHeadline,
            leftBody: leftBody,
            subtitle: subtitle
        ) {
            ZStack {
                phaseBody
                    .id(phaseID)
                    .transition(phaseTransition)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: phaseID)
        }
    }

    // MARK: - Copy

    private var leftHeadline: LocalizedStringKey {
        switch state.phase {
        case .prompt, .generating, .error: return "Your root identity"
        case .recovery: return "Save your recovery phrase"
        case .alreadyExists: return "Identity already set up"
        }
    }

    private var leftBody: LocalizedStringKey {
        switch state.phase {
        case .prompt, .error:
            return
                "The master key for everything you do here. Agents derive from it, devices pair through it, and signed messages all trace back to it. Stored in iCloud Keychain — never in plain text."
        case .generating:
            return "Generating a fresh keypair. This only takes a moment."
        case .recovery:
            return
                "Write down the 24-word phrase below. It's the only way to restore your master key if it's ever lost or replaced. Osaurus cannot recover it for you."
        case .alreadyExists:
            return
                "We found an existing identity in your iCloud Keychain. Onboarding will not create a new one — your existing master, agents, and access keys are preserved."
        }
    }

    private var subtitle: LocalizedStringKey {
        switch state.phase {
        case .prompt, .error:
            return "The root of trust your agents, devices, and tools all derive from."
        case .generating: return "Creating your keypair…"
        case .recovery: return "Shown once. Copy it before you continue."
        case .alreadyExists: return "Continuing with the existing identity."
        }
    }

    private var phaseID: String {
        switch state.phase {
        case .prompt: return "prompt"
        case .generating: return "generating"
        case .recovery: return "recovery"
        case .alreadyExists: return "alreadyExists"
        case .error: return "error"
        }
    }

    private var phaseTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 24)),
            removal: .opacity.combined(with: .offset(x: -24))
        )
    }

    // MARK: - Phase body

    @ViewBuilder
    private var phaseBody: some View {
        switch state.phase {
        case .prompt:
            promptBody
        case .generating:
            generatingBody
        case .recovery(let info):
            recoveryBody(info: info)
        case .alreadyExists:
            alreadyExistsBody
        case .error(let message):
            VStack(alignment: .leading, spacing: 12) {
                errorBanner(message)
                promptBody
            }
        }
    }

    private var alreadyExistsBody: some View {
        OnboardingGlassCard {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.successColor.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.successColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Existing identity detected", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Skipping master key creation to protect existing agents and access keys.",
                        bundle: .module
                    )
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Prompt body (hero chip + capabilities + footnote)

    private var promptBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            addressChip(
                Self.previewMasterAddress,
                label: "Your master address (preview)",
                trailingBadge: "PREVIEW"
            )

            capabilityRows

            footnoteRow
        }
    }

    private var capabilityRows: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    icon: "rectangle.connected.to.line.below",
                    title: L("Pair other devices"),
                    detail: L("Bonjour discovery; the connector you tap shows up in your list.")
                )
                bulletRow(
                    icon: "person.line.dotted.person.fill",
                    title: L("Agent-to-agent verify"),
                    detail: L("Recipients can verify a message really came from your agent.")
                )
                bulletRow(
                    icon: "key.horizontal.fill",
                    title: L("External tool access"),
                    detail: L("Mint osk-v1 keys for MCP, plugins, and remote agents — revocable any time.")
                )
            }
            .padding(14)
        }
    }

    private var footnoteRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(
                "Stored in iCloud Keychain. Skippable, addable later from Settings.",
                bundle: .module
            )
            .font(theme.font(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 4)
    }

    private func bulletRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Address chip (shared by prompt preview and recovery card)

    /// Renders an EIP-55 hex address as a labelled chip. Used for the
    /// prompt-phase preview (with a `PREVIEW` badge) and the recovery-phase
    /// real master address (no badge).
    private func addressChip(
        _ address: String,
        label: LocalizedStringKey,
        trailingBadge: String? = nil
    ) -> some View {
        OnboardingGlassCard {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label, bundle: .module)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.6)
                        .textCase(.uppercase)
                    Text(truncated(address))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .help(Text(address))
                }

                Spacer(minLength: 8)

                if let badge = trailingBadge {
                    Text(LocalizedStringKey(badge), bundle: .module)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(theme.tertiaryBackground)
                                .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 1))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// First 10 + last 6 hex characters with a middle ellipsis, matching
    /// the chip preview format from `docs/IDENTITY.md` examples.
    private func truncated(_ address: String) -> String {
        guard address.count > 18 else { return address }
        let head = address.prefix(10)
        let tail = address.suffix(6)
        return "\(head)…\(tail)"
    }

    // MARK: - Error / Generating

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.errorColor)
            Text(message)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.errorColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.10))
        )
    }

    private var generatingBody: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)
            Text("Generating identity…", bundle: .module)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: OnboardingMetrics.cardCornerRadius, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.glassEnabled ? 0.5 : 1.0))
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingMetrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Recovery body

    private func recoveryBody(info: IdentityInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Lost phrases cannot be recovered.", bundle: .module)
                    .font(theme.font(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.warningColor.opacity(0.10))
            )

            if let mnemonic = info.mnemonic {
                MasterMnemonicCard(words: mnemonic)
            }

            addressChip(info.osaurusId, label: "Master address")

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(
                    "Write the 24 words down or save them in a password manager.",
                    bundle: .module
                )
                .font(theme.font(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 4)
        }
    }

}

// MARK: - CTA

struct IdentityCTA: View {
    @ObservedObject var state: IdentityState
    let onComplete: () -> Void

    var body: some View {
        switch state.phase {
        case .prompt, .error:
            OnboardingBrandButton(title: "Create Identity", action: state.generate)
                .frame(width: OnboardingMetrics.ctaWidthCompact)

        case .generating:
            // Reserve the CTA footprint so the action row doesn't twitch
            // when the phase advances.
            Color.clear.frame(width: OnboardingMetrics.ctaWidthCompact, height: OnboardingMetrics.buttonHeight)

        case .recovery:
            OnboardingBrandButton(title: "I've Saved It") {
                state.acknowledgeBackup()
                onComplete()
            }
            .frame(width: OnboardingMetrics.ctaWidthCompact)

        case .alreadyExists:
            OnboardingBrandButton(title: "Continue", action: onComplete)
                .frame(width: OnboardingMetrics.ctaWidthCompact)
        }
    }
}

// MARK: - Secondary

struct IdentitySecondary: View {
    @ObservedObject var state: IdentityState
    let onSkip: () -> Void

    var body: some View {
        switch state.phase {
        case .prompt, .error:
            OnboardingTextButton(title: "Skip for now", action: onSkip)
        case .generating, .alreadyExists:
            EmptyView()
        case .recovery(let info):
            OnboardingTextButton(title: "Copy phrase") {
                guard let mnemonic = info.mnemonic else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mnemonic.joined(separator: " "), forType: .string)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingIdentitySetupView_Previews: PreviewProvider {
        static var previews: some View {
            let state = IdentityState()
            return VStack {
                IdentityBody(state: state).frame(height: 460)
                HStack {
                    IdentitySecondary(state: state, onSkip: {})
                    Spacer()
                    IdentityCTA(state: state, onComplete: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 640)
        }
    }
#endif
