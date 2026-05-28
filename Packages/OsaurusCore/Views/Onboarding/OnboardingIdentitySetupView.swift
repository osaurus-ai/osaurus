//
//  OnboardingIdentitySetupView.swift
//  osaurus
//
//  Onboarding step 4 — claim a personal signature. Three internal phases
//  (prompt → generating → done) swap inside the body slot so the chrome
//  stays still.
//
//  Copy avoids crypto/wallet vocabulary on purpose. The 24-word recovery
//  phrase is no longer surfaced here — it's persisted to iCloud Keychain
//  by `OsaurusIdentity.setup()` and viewable later from Settings.
//

import AppKit
import SwiftUI

// MARK: - Animation

/// Spring used for the in-step phase cross-fades (prompt → generating →
/// done → …). Lives at file scope so both `IdentityState` (which drives
/// the swap via `withAnimation`) and the in-body phase ZStack reach for
/// the same easing.
enum IdentityAnimation {
    static let layoutSwap: Animation = .spring(response: 0.5, dampingFraction: 0.85)
}

// MARK: - Phase

enum OnboardingIdentityPhase: Equatable {
    case prompt
    case generating
    /// Terminal confirmation beat shown for ~`autoAdvanceDelay` seconds
    /// after a successful setup, before the step auto-advances. Gives the
    /// user a "signature ready" frame instead of slamming them into the
    /// next slide mid-biometric.
    case done(IdentityInfo)
    case alreadyExists
    case error(String)

    static func == (lhs: OnboardingIdentityPhase, rhs: OnboardingIdentityPhase) -> Bool {
        switch (lhs, rhs) {
        case (.prompt, .prompt): return true
        case (.generating, .generating): return true
        case (.done(let a), .done(let b)): return a.osaurusId == b.osaurusId
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

    /// Whether the "Advanced" disclosure (hex address preview) is
    /// expanded. Lives on the state object so the toggle survives the
    /// prompt → error → prompt phase swap.
    @Published var showAdvanced: Bool = false

    /// How long the `.done` confirmation card hangs on screen before the
    /// step auto-advances. Long enough to register the success state,
    /// short enough to feel snappy.
    static let autoAdvanceDelay: TimeInterval = 0.6

    /// No footer caption on this step anymore. The recovery phrase that
    /// used to live behind "Shown once. Save it before continuing." now
    /// lives in iCloud Keychain.
    var footerCaption: LocalizedStringKey? { nil }

    func generate() {
        // If a master already exists, jump straight past identity setup —
        // re-running onboarding (e.g., after the version bump in
        // OnboardingService) must never silently regenerate the master and
        // strand all derived agent / access keys.
        if OsaurusIdentity.exists() {
            withAnimation(IdentityAnimation.layoutSwap) { phase = .alreadyExists }
            return
        }

        withAnimation(IdentityAnimation.layoutSwap) { phase = .generating }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let info = try await OsaurusIdentity.setup()
                withAnimation(IdentityAnimation.layoutSwap) { self.phase = .done(info) }
            } catch {
                withAnimation(IdentityAnimation.layoutSwap) {
                    self.phase = .error(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Body

struct IdentityBody: View {
    @ObservedObject var state: IdentityState

    @Environment(\.theme) private var theme

    /// Sample master address taken straight from `docs/IDENTITY.md`. Used
    /// only as a visual preview before the real one is generated, so the
    /// abstract "cryptographic address" idea has a concrete shape. Kept
    /// behind the "Advanced" disclosure so first-run users don't see
    /// hex-encoded wallet language.
    private static let previewMasterAddress =
        "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18"

    var body: some View {
        twoColumnBody
    }

    private var twoColumnBody: some View {
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
        }
    }

    // MARK: - Copy

    private var leftHeadline: LocalizedStringKey {
        switch state.phase {
        case .prompt, .generating, .error: return "Your secret signature"
        case .done: return "Signature ready"
        case .alreadyExists: return "You're already set up"
        }
    }

    private var leftBody: LocalizedStringKey {
        switch state.phase {
        case .prompt, .error:
            return
                "A short code that proves what you make is really yours. We back it up in iCloud Keychain so it follows you across your Apple devices."
        case .generating:
            return "Just a moment — making your signature now."
        case .done:
            return "Backed up in iCloud Keychain so it follows you across your Apple devices."
        case .alreadyExists:
            return "We're keeping the signature you have so nothing breaks."
        }
    }

    private var subtitle: LocalizedStringKey {
        switch state.phase {
        case .prompt, .error:
            return "A short code that proves what you make is really yours."
        case .generating: return "Making your signature…"
        case .done: return "All set. Carrying on…"
        case .alreadyExists: return "Picking up where you left off."
        }
    }

    private var phaseID: String {
        switch state.phase {
        case .prompt: return "prompt"
        case .generating: return "generating"
        case .done: return "done"
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
        case .done(let info):
            doneBody(info: info)
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
                    Text("Signature already saved", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "We're keeping the one you already have so nothing you've built breaks.",
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

    // MARK: - Prompt body (capabilities + advanced + footnote)

    private var promptBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            capabilityRows

            advancedDisclosure

            footnoteRow
        }
    }

    private var capabilityRows: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    icon: "checkmark.seal.fill",
                    title: L("Prove it's really you"),
                    detail: L("Stops anyone from pretending to be you.")
                )
                bulletRow(
                    icon: "key.horizontal.fill",
                    title: L("Let tools in without sharing your password"),
                    detail: L("Each one gets its own access, and you can take it back any time.")
                )
                bulletRow(
                    icon: "icloud.fill",
                    title: L("Backed up by Apple"),
                    detail: L(
                        "Stored in your iCloud Keychain, so a new Mac just picks up where you left off."
                    )
                )
            }
            .padding(14)
        }
    }

    /// Disclosure that exposes the hex address preview chip for users who
    /// actually want to see it. Hidden by default so non-crypto users on
    /// first run aren't confronted with wallet-style language.
    ///
    /// Implemented as a Button + conditional content rather than
    /// `DisclosureGroup` because the latter only registers its own
    /// invisible chevron as the hit target — the custom label content
    /// stays inert and clicking "Advanced" did nothing.
    @ViewBuilder
    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(theme.animationQuick()) {
                    state.showAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Text("Advanced", bundle: .module)
                        .font(theme.font(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .localizedHelp(state.showAdvanced ? "Hide details" : "Show details")

            if state.showAdvanced {
                addressChip(
                    Self.previewMasterAddress,
                    label: "Your signature (preview)",
                    trailingBadge: "Preview"
                )
            }
        }
    }

    private var footnoteRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(
                "Backed up in iCloud Keychain. You can manage this later in Settings.",
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

    // MARK: - Address chip (used by the Advanced preview)

    /// Renders an EIP-55 hex address as a labelled chip. The trailing
    /// "Preview" badge marks this as a sample value, not the user's own
    /// signature (which they'll see in Settings → Identity once setup
    /// completes).
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
                        .font(theme.font(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                    Text(truncated(address))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .help(Text(address))
                }

                Spacer(minLength: 8)

                if let badge = trailingBadge {
                    Text(LocalizedStringKey(badge), bundle: .module)
                        .font(theme.font(size: 10, weight: .semibold))
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

    // MARK: - Error / Generating / Done

    private func errorBanner(_ message: String) -> some View {
        OnboardingCalloutBanner.error(
            prefix: "Couldn't make your signature.",
            detail: message
        )
    }

    private var generatingBody: some View {
        OnboardingGlassCard {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.9)
                Text("Making your signature…", bundle: .module)
                    .font(theme.font(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(14)
        }
    }

    /// Confirmation card shown for one beat after a successful generate.
    /// The CTA observes the phase change and auto-advances after
    /// `IdentityState.autoAdvanceDelay`, so this view never owns its own
    /// continue action.
    private func doneBody(info _: IdentityInfo) -> some View {
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
                    Text("Signature ready", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Backed up in your iCloud Keychain. You can view it in Settings any time.",
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
}

// MARK: - CTA

struct IdentityCTA: View {
    @ObservedObject var state: IdentityState
    let onComplete: () -> Void

    @State private var hasAutoAdvanced = false

    var body: some View {
        ctaContent
            .onChange(of: state.phase) { _, newPhase in
                // Auto-advance after the .done confirmation card has had a
                // beat to register. Guarded so we don't fire twice if the
                // user rapidly bounces between phases.
                if case .done = newPhase, !hasAutoAdvanced {
                    hasAutoAdvanced = true
                    Task { @MainActor in
                        try? await Task.sleep(
                            nanoseconds: UInt64(IdentityState.autoAdvanceDelay * 1_000_000_000)
                        )
                        onComplete()
                    }
                }
            }
    }

    @ViewBuilder
    private var ctaContent: some View {
        switch state.phase {
        case .prompt, .error:
            OnboardingBrandButton(title: "Make My Signature", action: state.generate)
                .frame(width: OnboardingMetrics.ctaWidthCompact)

        case .generating, .done:
            // Reserve the CTA footprint so the action row doesn't twitch
            // when the phase advances. `.done` auto-advances via the
            // `onChange` observer above.
            Color.clear.frame(width: OnboardingMetrics.ctaWidthCompact, height: OnboardingMetrics.buttonHeight)

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
        case .generating, .done, .alreadyExists:
            EmptyView()
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
