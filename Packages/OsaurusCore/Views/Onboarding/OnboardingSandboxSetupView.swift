//
//  OnboardingSandboxSetupView.swift
//  osaurus
//
//  Onboarding step 5 — offer the sandboxed Linux container as a one-click
//  safety net. Fire-and-forget: tapping the CTA persists CPU/RAM, kicks
//  off `SandboxManager.provision()` in the background, and advances to
//  the plugin picker immediately. The existing booting badge in chat and
//  the Sandbox tab's journey UI take over from there.
//
//  Availability is decided by the parent (`OnboardingView`) — when the
//  sandbox isn't available on this Mac we skip this step entirely rather
//  than rendering a dead-end "not available" card.
//

import SwiftUI

// MARK: - State

@MainActor
final class SandboxSetupState: ObservableObject {
    /// Mutable CPU/RAM payload. Seeded from the on-disk config so users
    /// who re-run onboarding don't lose tuning. The `SandboxConfiguration`
    /// default is 2 CPU / 2 GB.
    @Published var config: SandboxConfiguration

    /// "Resources" disclosure toggle. Hidden by default so the prompt
    /// reads as a single confident recommendation rather than a form.
    @Published var showAdvanced: Bool = false

    init() {
        self.config = SandboxConfigurationStore.load()
    }

    /// Persists the chosen CPU/RAM, kicks off provisioning in a detached
    /// task, and immediately invokes `onComplete` so onboarding advances.
    /// Provisioning is intentionally not awaited — downloads + container
    /// boot can take minutes; chat / sandbox tab show live progress later.
    func kickoffProvisioning(onComplete: @escaping () -> Void) {
        SandboxConfigurationStore.save(config)
        Task.detached(priority: .userInitiated) {
            _ = await SandboxManager.shared.checkAvailability()
            try? await SandboxManager.shared.provision()
        }
        onComplete()
    }
}

// MARK: - Body

struct SandboxSetupBody: View {
    @ObservedObject var state: SandboxSetupState

    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-sandbox",
            leftHeadline: "A safety net for your dino",
            leftBody:
                "When your dino installs packages, runs scripts, or fiddles with files, it does that in a tiny, walled-off workspace — separate from your Mac.",
            subtitle: "Where your dino runs anything that touches your system."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                explainerCard
                advancedDisclosure
                footnoteRow
            }
        }
    }

    // MARK: - Explainer card

    private var explainerCard: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    icon: "shippingbox.fill",
                    title: L("Walled off from your Mac"),
                    detail: L("Anything risky stays inside the box. Your files and apps don't see them.")
                )
                bulletRow(
                    icon: "terminal.fill",
                    title: L("Real code, safely"),
                    detail: L("Lets your dino install packages, run scripts, and work with files like a real machine.")
                )
                bulletRow(
                    icon: "arrow.uturn.backward.circle.fill",
                    title: L("Reset any time"),
                    detail: L("Throw it away and start fresh from the Sandbox tab — your Mac is untouched.")
                )
            }
            .padding(14)
        }
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

    // MARK: - Advanced disclosure (CPU / RAM)

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
                    if !state.showAdvanced {
                        Text("\(state.config.cpus) cores · \(state.config.memoryGB) GB memory")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if state.showAdvanced {
                resourceCard
            }
        }
    }

    private var resourceCard: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                resourceRow(
                    label: "Processor cores",
                    value: "\(state.config.cpus)",
                    binding: $state.config.cpus,
                    range: 1 ... 8
                )
                resourceRow(
                    label: "Memory",
                    value: "\(state.config.memoryGB) GB",
                    binding: $state.config.memoryGB,
                    range: 1 ... 8
                )
            }
            .padding(14)
        }
    }

    private func resourceRow(
        label: LocalizedStringKey,
        value: String,
        binding: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(label, bundle: .module)
                .font(theme.font(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .padding(.trailing, 6)
            Stepper("", value: binding, in: range)
                .labelsHidden()
        }
    }

    // MARK: - Footnote

    private var footnoteRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.successColor)
            Text(
                "Recommended. You can skip and add this later from the Sandbox tab.",
                bundle: .module
            )
            .font(theme.font(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 4)
    }
}

// MARK: - CTA

struct SandboxSetupCTA: View {
    @ObservedObject var state: SandboxSetupState
    let onComplete: () -> Void

    var body: some View {
        OnboardingBrandButton(title: "Set Up Sandbox") {
            state.kickoffProvisioning(onComplete: onComplete)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Secondary

struct SandboxSetupSecondary: View {
    let onSkip: () -> Void

    var body: some View {
        OnboardingTextButton(title: "Skip for now", action: onSkip)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingSandboxSetupView_Previews: PreviewProvider {
        static var previews: some View {
            let state = SandboxSetupState()
            return VStack {
                SandboxSetupBody(state: state).frame(height: 460)
                HStack {
                    SandboxSetupSecondary(onSkip: {})
                    Spacer()
                    SandboxSetupCTA(state: state, onComplete: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 640)
        }
    }
#endif
