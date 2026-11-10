//
//  CreditsTopUpSheet.swift
//  osaurus
//
//  Amount picker for adding Osaurus Router credits. Quick presets fill a single
//  amount field (the source of truth), then the chosen micro-USD amount is handed
//  to Stripe Checkout via `OsaurusRouterAccountService.createCheckout(amountMicro:)`.
//

import AppKit
import SwiftUI

struct CreditsTopUpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared

    /// Preset amounts in micro-USD: $5, $20, $100.
    private static let presetsMicro: [Int] = [5_000_000, 20_000_000, 100_000_000]
    private static let minimumMicro = OsaurusRouter.minimumTopUpMicro

    /// Single source of truth for the chosen amount (dollars, as typed). Presets
    /// write into this; a preset highlights only when the field equals it.
    @State private var amount: String = "20"
    @FocusState private var amountFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(
                icon: "creditcard.fill",
                title: "Add Credits",
                subtitle: "Choose how much to add. You'll finish payment in your browser.",
                onClose: { dismiss() }
            )

            VStack(alignment: .leading, spacing: theme.space.s16) {
                AssignedBaseSegmentedPicker(
                    selection: presetSelection,
                    options: Self.presetsMicro.map { .init(Optional($0), "$\($0 / 1_000_000)", verbatim: true) }
                )
                .accessibilityLabel(Text("Amount", bundle: .module))

                SettingsTextField(
                    placeholder: "0",
                    text: $amount,
                    icon: "dollarsign",
                    isInvalid: validationMessage != nil,
                    focus: $amountFocused,
                    onSubmit: { if isValid { Task { await performCheckout() } } }
                )

                validationRow

                if let error = accountService.lastError, !error.isEmpty {
                    Text(error)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                legalNotice
            }
            .padding(theme.settingsSheetInset)

            SettingsSheetFooter(
                primary: .init(
                    label: "Continue to Checkout",
                    isEnabled: isValid,
                    isLoading: accountService.isCreatingCheckout
                ) {
                    Task { await performCheckout() }
                },
                secondary: .init(label: "Cancel") { dismiss() }
            )
        }
        .frame(width: SettingsSheetWidth.compact)
        .settingsSheetSurface()
    }

    /// Presets write into the amount field so the field stays the single
    /// source of truth; a segment is selected only while the field equals it.
    private var presetSelection: Binding<Int?> {
        Binding(
            get: { currentMicro.flatMap { Self.presetsMicro.contains($0) ? $0 : nil } },
            set: { micro in
                guard let micro else { return }
                amount = String(micro / 1_000_000)
                amountFocused = false
            }
        )
    }

    @ViewBuilder
    private var validationRow: some View {
        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.circle")
                .font(SettingsFont.caption)
                .foregroundColor(theme.status.warning.foreground)
                .fixedSize(horizontal: false, vertical: true)
        } else if isValid, let micro = currentMicro {
            Label {
                // The purchase itself is in dollars (Stripe), so the credits
                // the user receives are shown next to the $ amount they pay.
                Text(
                    "You'll add \(OsaurusRouter.formatMicroAsCredits(String(micro))) (\(OsaurusRouter.formatMicroUSD(String(micro))))",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(theme.status.success.foreground)
            }
        } else {
            Label(localized: "Minimum top-up is $5.00", systemImage: "info.circle")
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
        }
    }

    /// Purchasing credits forms a payment agreement, so the credit-specific
    /// Terms (refunds, expiration, non-transferability) and the Privacy Policy
    /// are linked right where the charge is initiated.
    private var legalNotice: some View {
        MarkdownLinkText(
            markdown: OsaurusWebLinks.acceptanceMarkdown,
            style: .caption,
            textColor: theme.text.tertiary,
            linkColor: theme.text.link,
            alignment: .center
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Amount resolution

    private var amountTrimmed: String {
        amount.trimmingCharacters(in: .whitespaces)
    }

    /// Parse the amount field as a dollar amount into micro-USD. Tolerates a
    /// leading "$". Returns nil when empty or not a positive number.
    private var currentMicro: Int? {
        let trimmed = amountTrimmed
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.hasPrefix("$") ? String(trimmed.dropFirst()) : trimmed
        guard let dollars = Double(cleaned), dollars.isFinite, dollars > 0 else { return nil }
        let micro = (dollars * 1_000_000).rounded()
        guard micro <= Double(Int.max) else { return nil }
        return Int(micro)
    }

    private var isValid: Bool {
        (currentMicro ?? 0) >= Self.minimumMicro
    }

    private var validationMessage: String? {
        guard !amountTrimmed.isEmpty else { return nil }
        guard let micro = currentMicro else {
            return L("Enter a dollar amount, like 25.")
        }
        if micro < Self.minimumMicro {
            return L("Minimum top-up is $5.00")
        }
        return nil
    }

    // MARK: - Checkout

    private func performCheckout() async {
        guard isValid, let micro = currentMicro else { return }
        guard let url = await accountService.createCheckout(amountMicro: micro) else {
            // `createCheckout` set `accountService.lastError`; keep the sheet open
            // so the user can see why and retry.
            return
        }
        // Launching the browser blocks on an XPC round-trip to LaunchServices
        // that can stall for seconds, so hand the URL off the main actor. The
        // sheet dismisses immediately; the open completes in the background.
        Task.detached { NSWorkspace.shared.open(url) }
        dismiss()
    }
}
