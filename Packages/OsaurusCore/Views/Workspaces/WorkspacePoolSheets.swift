//
//  WorkspacePoolSheets.swift
//  osaurus
//
//  Owner-side money for a workspace's credit pool:
//
//  - `WorkspacePoolTopUpSheet` — a one-time top-up. Presets fill a single
//    dollar field (the source of truth), the router opens a Stripe Checkout
//    in the browser, and the sheet flips to a "finish in your browser" state
//    while the service polls the pool for the `workspace_topup` entry.
//  - `WorkspaceAutoReloadSheet` — the pool's auto-reload rule: below a
//    threshold, charge the card saved on the owner subscription for a reload
//    amount, capped per calendar month. Presets live here (the router only
//    enforces bounds). Saving clears a pause after declines.
//
//  Purchased credit never expires; the monthly grant does. Both sheets say so
//  where the money is committed.
//

import SwiftUI

// MARK: - Top-up

struct WorkspacePoolTopUpSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared

    let workspaceId: String
    let workspaceName: String

    @State private var amount: String = OsaurusRouterWorkspacePoolCredits.dollarsText(
        micro: OsaurusRouterWorkspacePoolCredits.topUpPresetsMicro[0]
    )
    @State private var checkoutOpened = false
    @State private var errorMessage: String?

    private var currentMicro: Int64? { OsaurusRouterWorkspacePoolCredits.micro(fromDollars: amount) }
    private var verdict: OsaurusRouterWorkspacePoolCredits.TopUpValidation? {
        currentMicro.map(OsaurusRouterWorkspacePoolCredits.validateTopUp)
    }
    private var isValid: Bool { verdict == .ok }

    var body: some View {
        WorkspaceSheetShell(
            icon: "creditcard.fill",
            title: checkoutOpened ? "Finish in your browser" : "Add pool credits",
            subtitle: subtitle,
            confirmTitle: checkoutOpened ? "Done" : "Continue to checkout",
            isBusy: service.isBusy("pool.topup"),
            isValid: checkoutOpened || isValid,
            onConfirm: { submit() },
            secondaryTitle: checkoutOpened ? "Close" : "Cancel",
            confirmDismisses: checkoutOpened,
            height: checkoutOpened ? 300 : 400
        ) {
            if checkoutOpened {
                waitingBody
            } else {
                composeBody
            }
        }
        .onChange(of: service.pendingConfirmation) { _, pending in
            // The webhook landed (or the user stopped waiting from the
            // overview): nothing left for this sheet to show.
            if checkoutOpened, pending == nil { dismiss() }
        }
    }

    private var subtitle: String {
        if checkoutOpened {
            return L("Finish the payment in your browser. The pool updates in Osaurus as soon as Stripe confirms it.")
        }
        return String(format: L("Purchased credits go to “%@”'s shared pool and never expire."), workspaceName)
    }

    @ViewBuilder
    private var composeBody: some View {
        AgentSheetSectionLabel("Amount")
        PoolAmountPicker(
            presetsMicro: OsaurusRouterWorkspacePoolCredits.topUpPresetsMicro,
            amount: $amount,
            autofocus: false
        )

        if let errorMessage {
            SheetHintRow(kind: .error, message: errorMessage)
        } else if let verdict, verdict != .ok {
            SheetHintRow(kind: .warning, message: WorkspacesService.topUpValidationMessage(verdict))
        } else if let micro = currentMicro {
            SheetHintRow(
                kind: .ok,
                message: String(
                    format: L("Adds %@ to the pool for %@ — no fee. Unlike the monthly grant, these credits don't expire."),
                    OsaurusRouter.formatMicroAsCredits(String(micro)),
                    OsaurusRouter.formatMicroUSD(String(micro))
                )
            )
        } else {
            SheetHintRow(kind: .info, message: L("Enter a dollar amount between $5 and $500."))
        }

        if service.billing?.paymentMethodOnFile != true {
            SheetHintRow(
                kind: .info,
                message: L("The card you use is saved to your workspace subscription, so you can turn on auto-reload afterwards.")
            )
        }

        MarkdownLinkText(
            markdown: OsaurusWebLinks.acceptanceMarkdown,
            font: .system(size: 11),
            textColor: theme.tertiaryText,
            linkColor: theme.accentColor,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var waitingBody: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: L("Waiting for Stripe to confirm %@"), currentMicro.map { OsaurusRouter.formatMicroUSD(String($0)) } ?? ""))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(L("Nothing is charged until you complete the checkout. Osaurus checks the pool each time you come back to it."))
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        SheetHintRow(
            kind: .info,
            message: L("Closed the browser tab without paying? Just close this — nothing was charged.")
        )
    }

    private func submit() {
        guard !checkoutOpened, isValid, let micro = currentMicro else { return }
        errorMessage = nil
        Task {
            if await service.topUpPool(workspaceId: workspaceId, amountMicro: micro) != nil {
                checkoutOpened = true
            } else {
                errorMessage = service.lastError
            }
        }
    }
}

// MARK: - Auto-reload

struct WorkspaceAutoReloadSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared

    let workspaceId: String
    let workspaceName: String

    @State private var enabled = false
    @State private var threshold: String = OsaurusRouterWorkspacePoolCredits.dollarsText(
        micro: OsaurusRouterWorkspacePoolCredits.defaultThresholdMicro
    )
    @State private var reload: String = OsaurusRouterWorkspacePoolCredits.dollarsText(
        micro: OsaurusRouterWorkspacePoolCredits.defaultReloadMicro
    )
    @State private var capEnabled = true
    @State private var cap: String = OsaurusRouterWorkspacePoolCredits.dollarsText(
        micro: OsaurusRouterWorkspacePoolCredits.defaultMonthlyCapMicro
    )
    @State private var loaded = false
    @State private var errorMessage: String?

    private var settings: OsaurusRouterWorkspaceAutoReload? { service.autoReload }
    private var thresholdMicro: Int64? { OsaurusRouterWorkspacePoolCredits.micro(fromDollars: threshold) }
    private var reloadMicro: Int64? { OsaurusRouterWorkspacePoolCredits.micro(fromDollars: reload) }
    private var capMicro: Int64? { OsaurusRouterWorkspacePoolCredits.micro(fromDollars: cap) }

    /// Client-side verdict before the router sees anything. Turning
    /// auto-reload off is always valid — the amounts are kept for next time.
    private var verdict: OsaurusRouterWorkspacePoolCredits.AutoReloadValidation? {
        guard let thresholdMicro, let reloadMicro else { return nil }
        if capEnabled, capMicro == nil { return nil }
        return OsaurusRouterWorkspacePoolCredits.validateAutoReload(
            thresholdMicro: thresholdMicro, amountMicro: reloadMicro,
            monthlyCapMicro: capEnabled ? capMicro : nil, bounds: settings?.bounds
        )
    }
    private var isValid: Bool { !enabled || verdict == .ok }
    private var hasCard: Bool {
        settings?.paymentMethodOnFile ?? service.billing?.paymentMethodOnFile ?? false
    }

    var body: some View {
        WorkspaceSheetShell(
            icon: "arrow.triangle.2.circlepath.circle.fill",
            title: "Auto-reload",
            subtitle: String(
                format: L("When “%@”'s pool runs low, charge your saved card so shared agents keep working."),
                workspaceName
            ),
            confirmTitle: "Save",
            isBusy: service.isBusy("pool.autoReload"),
            isValid: loaded && isValid,
            onConfirm: { submit() },
            height: enabled ? 620 : 380
        ) {
            statusRow

            SettingsToggle(
                title: "Reload automatically",
                description: "Charges the card on your workspace subscription when the pool drops below the threshold.",
                isOn: $enabled
            )

            if enabled {
                AgentSheetSectionLabel("When the pool falls below")
                PoolAmountPicker(
                    presetsMicro: OsaurusRouterWorkspacePoolCredits.thresholdPresetsMicro,
                    amount: $threshold
                )

                AgentSheetSectionLabel("Reload")
                PoolAmountPicker(
                    presetsMicro: OsaurusRouterWorkspacePoolCredits.reloadPresetsMicro,
                    amount: $reload
                )

                AgentSheetSectionLabel("Monthly cap")
                capRow
            }

            hintRow
        }
        .task { await load() }
    }

    /// Current router-side state: paused after declines, cap reached, or
    /// simply what has been reloaded this month.
    @ViewBuilder
    private var statusRow: some View {
        if let settings {
            if settings.paused {
                SheetHintRow(kind: .error, message: pausedMessage(settings))
            } else if settings.enabled, settings.isCapReached {
                SheetHintRow(
                    kind: .warning,
                    message: L("This month's cap is reached — reloads resume when the month rolls over or you raise the cap.")
                )
            } else if settings.enabled {
                SheetHintRow(
                    kind: .ok,
                    message: String(
                        format: L("On. Reloaded %@ so far this month."),
                        OsaurusRouter.formatMicroUSD(String(settings.monthReloaded))
                    )
                )
            } else if !hasCard {
                SheetHintRow(
                    kind: .info,
                    message: L("Needs a saved card. Add credits once (the card is saved) or update your card under Manage billing.")
                )
            }
        } else if !loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading auto-reload settings…", bundle: .module)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private func pausedMessage(_ settings: OsaurusRouterWorkspaceAutoReload) -> String {
        if settings.isChargebackPaused {
            return L("Paused after a chargeback on a pool purchase. Saving re-arms it.")
        }
        if let code = settings.lastError, !code.isEmpty {
            return String(
                format: L("Paused after %d failed charges (last: %@). Fix the card under Manage billing, then save to re-arm."),
                settings.consecutiveFailures ?? 3, code.replacingOccurrences(of: "_", with: " ")
            )
        }
        return L("Paused after repeated failed charges. Fix the card under Manage billing, then save to re-arm.")
    }

    @ViewBuilder
    private var capRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $capEnabled) {
                Text("Cap reloads per month", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if capEnabled {
                DollarField(amount: $cap, width: 110)
            } else {
                Text("No cap", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var hintRow: some View {
        if let errorMessage {
            SheetHintRow(kind: .error, message: errorMessage)
        } else if enabled, let verdict, verdict != .ok {
            SheetHintRow(kind: .warning, message: WorkspacesService.autoReloadValidationMessage(verdict))
        } else if enabled, verdict == nil {
            SheetHintRow(kind: .info, message: L("Enter dollar amounts for the threshold, the reload, and the cap."))
        } else if enabled, let thresholdMicro, let reloadMicro {
            SheetHintRow(kind: .ok, message: summary(thresholdMicro: thresholdMicro, reloadMicro: reloadMicro))
        } else if !enabled, settings?.enabled == true {
            SheetHintRow(kind: .info, message: L("Saving turns auto-reload off. Purchased credits stay on the pool."))
        } else {
            SheetHintRow(
                kind: .info,
                message: L("Reloads are charged off-session to the card saved on your subscription; after 3 declines auto-reload pauses until you save again.")
            )
        }
    }

    private func summary(thresholdMicro: Int64, reloadMicro: Int64) -> String {
        let below = OsaurusRouter.formatMicroUSD(String(thresholdMicro))
        let add = OsaurusRouter.formatMicroUSD(String(reloadMicro))
        let credits = OsaurusRouter.formatMicroAsCredits(String(reloadMicro))
        if capEnabled, let capMicro {
            return String(
                format: L("Below %@, charge %@ (%@) — at most %@ per month."),
                below, add, credits, OsaurusRouter.formatMicroUSD(String(capMicro))
            )
        }
        return String(format: L("Below %@, charge %@ (%@) — no monthly cap."), below, add, credits)
    }

    private func load() async {
        let fetched = await service.loadAutoReload(workspaceId: workspaceId)
        if let fetched {
            enabled = fetched.enabled
            if let t = fetched.threshold { threshold = OsaurusRouterWorkspacePoolCredits.dollarsText(micro: t) }
            if let a = fetched.amount { reload = OsaurusRouterWorkspacePoolCredits.dollarsText(micro: a) }
            // A saved rule with no cap means the owner chose "no cap"; an
            // unconfigured rule gets the client default cap.
            if fetched.enabled || fetched.threshold != nil {
                capEnabled = fetched.monthlyCap != nil
            }
            if let c = fetched.monthlyCap { cap = OsaurusRouterWorkspacePoolCredits.dollarsText(micro: c) }
        } else {
            errorMessage = service.lastError
        }
        loaded = true
    }

    private func submit() {
        guard loaded, isValid, let thresholdMicro, let reloadMicro else { return }
        errorMessage = nil
        let capValue = capEnabled ? capMicro : nil
        Task {
            let saved = await service.saveAutoReload(
                workspaceId: workspaceId, enabled: enabled,
                thresholdMicro: thresholdMicro, amountMicro: reloadMicro, monthlyCapMicro: capValue
            )
            if saved != nil {
                dismiss()
            } else {
                errorMessage = service.lastError
            }
        }
    }
}

// MARK: - Shared amount controls

/// Preset chips over a single dollar field (the field is the source of
/// truth; a chip highlights only while the field equals it).
private struct PoolAmountPicker: View {
    @Environment(\.theme) private var theme

    let presetsMicro: [Int64]
    @Binding var amount: String
    var autofocus: Bool = false

    private var currentMicro: Int64? { OsaurusRouterWorkspacePoolCredits.micro(fromDollars: amount) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presetsMicro, id: \.self) { micro in
                chip(micro)
            }
            DollarField(amount: $amount, width: 96, autofocus: autofocus)
        }
    }

    private func chip(_ micro: Int64) -> some View {
        let isSelected = currentMicro == micro
        return Button {
            amount = OsaurusRouterWorkspacePoolCredits.dollarsText(micro: micro)
        } label: {
            Text(verbatim: "$\(OsaurusRouterWorkspacePoolCredits.dollarsText(micro: micro))")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(
                    isSelected ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? theme.accentColor : theme.inputBackground.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.clear : theme.inputBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// `$ [   ]` dollar entry.
private struct DollarField: View {
    @Environment(\.theme) private var theme
    @Binding var amount: String
    var width: CGFloat = 96
    var autofocus: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "$")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)
            TextField("0", text: $amount)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .focused($focused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(focused ? theme.accentColor.opacity(0.6) : theme.inputBorder, lineWidth: 1)
                )
        )
        .onAppear { if autofocus { focused = true } }
    }
}
