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
    @State private var hoveredButton: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 420)
        .background(theme.secondaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accentColor.opacity(0.14))
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Add credits", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Choose how much to add. You'll finish payment in your browser.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Self.presetsMicro, id: \.self) { micro in
                    presetButton(micro)
                }
            }

            amountField

            validationRow

            if let error = accountService.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    /// Segmented preset chip. Tapping writes the value into the amount field so
    /// the field stays the single source of truth; the chip is filled (accent)
    /// only while the field equals it.
    private func presetButton(_ micro: Int) -> some View {
        let isSelected = currentMicro == micro
        return Button {
            amount = String(micro / 1_000_000)
            amountFocused = false
        } label: {
            Text(verbatim: "$\(micro / 1_000_000)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(
                    isSelected ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            isSelected ? theme.accentColor : theme.tertiaryBackground.opacity(0.5)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isSelected ? Color.clear : theme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var amountField: some View {
        HStack(spacing: 8) {
            Text(verbatim: "$")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)
            TextField("0", text: $amount)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .focused($amountFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.primaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            amountFocused ? theme.accentColor.opacity(0.6) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    @ViewBuilder
    private var validationRow: some View {
        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        } else if isValid, let micro = currentMicro {
            Label {
                Text(
                    "You'll add \(OsaurusRouter.formatMicroUSD(String(micro)))",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(theme.successColor)
            }
        } else {
            Label(localized: "Minimum top-up is $5.00", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            legalNotice

            HStack(spacing: 12) {
                footerButton(title: L("Cancel"), isPrimary: false) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                footerButton(
                    title: L("Continue to checkout"),
                    isPrimary: true,
                    isEnabled: isValid && !accountService.isCreatingCheckout,
                    isLoading: accountService.isCreatingCheckout
                ) {
                    Task { await performCheckout() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .padding(.top, 2)
    }

    /// Purchasing credits forms a payment agreement, so the credit-specific
    /// Terms (refunds, expiration, non-transferability) and the Privacy Policy
    /// are linked right where the charge is initiated.
    private var legalNotice: some View {
        MarkdownLinkText(
            markdown: OsaurusWebLinks.acceptanceMarkdown,
            font: .system(size: 11),
            textColor: theme.tertiaryText,
            linkColor: theme.accentColor,
            alignment: .center
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    /// Footer button styled to match the themed dialog: primary is an accent
    /// fill, secondary is a subtle tertiary surface.
    private func footerButton(
        title: String,
        isPrimary: Bool,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredButton == title && isEnabled
        let foreground: Color =
            isPrimary ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText
        return Button(action: action) {
            // Keep the label in the layout (just hidden) while loading so the
            // spinner overlays in place instead of resizing the button.
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(foreground)
                .opacity(isLoading ? 0 : 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isPrimary
                                ? theme.accentColor.opacity(isHovered ? 0.9 : 1.0)
                                : theme.tertiaryBackground.opacity(isHovered ? 0.8 : 0.5)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isPrimary ? Color.clear : theme.cardBorder, lineWidth: 1)
                )
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(foreground)
                    }
                }
                .opacity(isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            hoveredButton = (hovering && isEnabled) ? title : nil
        }
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
        return Int((dollars * 1_000_000).rounded())
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
