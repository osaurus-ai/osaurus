//
//  WorkspacesSheets.swift
//  osaurus
//
//  Modal sheets for the Workspaces tab: create a workspace, activate a
//  web-purchased workspace from a deep-linked code, join through an invite
//  link, create an invite link, and share an agent (with agent-key proof).
//  Every sheet is `AgentSheetHeader` + scrolling body + `AgentSheetFooter`
//  in a `fittedSheetFrame`, with `StyledTextField`s and `SettingsField`-style
//  hint rows — the same chrome as the Agents tab's sheets.
//

import AppKit
import SwiftUI

// MARK: - Shared sheet shell

/// Header · scrolling body · pinned footer, sized with `fittedSheetFrame`
/// so the confirm button stays reachable on small displays.
struct WorkspaceSheetShell<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let icon: String
    let title: LocalizedStringKey
    /// Already-localized subtitle (may be built with `String(format:)`).
    let subtitle: String
    let confirmTitle: LocalizedStringKey
    let isBusy: Bool
    let isValid: Bool
    let onConfirm: () -> Void
    var secondaryTitle: LocalizedStringKey = "Cancel"
    /// When true the primary button dismisses instead of confirming (result
    /// states such as "Invite link ready").
    var confirmDismisses: Bool = false
    var width: CGFloat = 460
    var height: CGFloat = 420
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: icon,
                title: title,
                subtitleText: subtitle,
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            AgentSheetFooter(
                primary: .init(
                    label: confirmTitle,
                    isEnabled: isValid,
                    isLoading: isBusy,
                    handler: {
                        if confirmDismisses { dismiss() } else { onConfirm() }
                    }
                ),
                secondary: .init(label: secondaryTitle, handler: { dismiss() }),
                hint: confirmDismisses ? nil : "Enter to confirm"
            )
        }
        .fittedSheetFrame(width: width, height: height)
        .background(theme.primaryBackground)
    }
}

/// Inline check/warn/info line under a field (`SettingsField` hint style).
struct SheetHintRow: View {
    @Environment(\.theme) private var theme

    enum Kind {
        case ok
        case warning
        case info
        case error
    }

    let kind: Kind
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(iconColor)
        }
    }

    private var iconName: String {
        switch kind {
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.circle"
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch kind {
        case .ok: return theme.successColor
        case .warning: return theme.warningColor
        case .info: return theme.tertiaryText
        case .error: return theme.errorColor
        }
    }

    private var textColor: Color {
        switch kind {
        case .warning: return theme.warningColor
        case .error: return theme.errorColor
        case .ok, .info: return theme.secondaryText
        }
    }
}

/// Read-only monospaced value row (a deep-linked code the user shouldn't
/// retype).
private struct SheetReadOnlyValue: View {
    @Environment(\.theme) private var theme
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }
}

/// Shared 1–80 character workspace-name validation used by Create/Activate.
enum WorkspaceNameValidation {
    static let maxLength = 80

    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxLength
    }
}

// MARK: - Create workspace

/// Buys a workspace. Three shapes, decided by the owner's subscription:
/// - **Live subscription** (not trialing): name only; `Create` adds one
///   workspace to the subscription and lands on it.
/// - **Trialing with a workspace already**: the router answers
///   `TRIAL_WORKSPACE_LIMIT`; shown as a dated hint, not an error.
/// - **No live subscription**: name + billing interval; `Start free trial` /
///   `Continue to checkout` opens Stripe in the browser and the sheet flips
///   to a "finish in your browser" state while the service polls for the
///   webhook-created workspace.
struct CreateWorkspaceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared

    var onCreated: (OsaurusRouterWorkspaceDetail) -> Void = { _ in }

    @State private var name = ""
    @State private var selectedPriceId: String?
    @State private var errorMessage: String?
    @State private var hitTrialLimit = false
    @State private var checkoutOpened = false
    /// Workspace ids known when Checkout opened, so the sheet recognizes the
    /// webhook-created one when the service lands on it.
    @State private var idsBeforeCheckout: Set<String> = []

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameIsValid: Bool { WorkspaceNameValidation.isValid(name) }
    /// Whether the router will bounce through Stripe Checkout (no live
    /// subscription) — decides the interval picker and the CTA copy.
    private var needsCheckout: Bool { !service.hasLiveSubscription }
    private var plan: OsaurusRouterWorkspacePlan? { service.prices?.plan }
    private var livePrices: [OsaurusRouterWorkspacePrice] { service.prices?.livePrices ?? [] }
    private var selectedPrice: OsaurusRouterWorkspacePrice? {
        livePrices.first { $0.id == selectedPriceId } ?? service.prices?.monthly ?? livePrices.first
    }

    private var confirmTitle: LocalizedStringKey {
        if checkoutOpened { return "Done" }
        if !needsCheckout { return "Create" }
        return service.trialEligible ? "Start free trial" : "Continue to checkout"
    }

    private var subtitle: String {
        if checkoutOpened {
            return L("Finish the payment in your browser. The workspace appears in Osaurus as soon as Stripe confirms it.")
        }
        if !needsCheckout {
            return L("Give it a name. It's added to your subscription and ready right away.")
        }
        if service.trialEligible, let days = service.trialDays, days > 0 {
            return String(
                format: L("Name it and pick a billing interval. Your first %d days are free; you can cancel anytime before then."),
                days
            )
        }
        return L("Name it and pick a billing interval. You'll finish the purchase in your browser.")
    }

    var body: some View {
        WorkspaceSheetShell(
            icon: checkoutOpened ? "creditcard.fill" : "rectangle.3.group.fill",
            title: checkoutOpened ? "Finish in your browser" : "New workspace",
            subtitle: subtitle,
            confirmTitle: confirmTitle,
            isBusy: service.isBusy("workspace.create"),
            isValid: checkoutOpened || (nameIsValid && !hitTrialLimit),
            onConfirm: { submit() },
            secondaryTitle: checkoutOpened ? "Close" : "Cancel",
            confirmDismisses: checkoutOpened,
            height: needsCheckout && !checkoutOpened ? 470 : 320
        ) {
            if checkoutOpened {
                checkoutOpenedBody
            } else {
                composeBody
            }
        }
        .onAppear {
            name = WorkspacesService.defaultActivationName
            if selectedPriceId == nil { selectedPriceId = service.prices?.monthly?.id ?? livePrices.first?.id }
            // Prices/billing may be stale or missing on first open.
            Task { await service.refreshBilling() }
        }
        .onChange(of: service.prices) { _, prices in
            if selectedPriceId == nil { selectedPriceId = prices?.monthly?.id ?? prices?.livePrices.first?.id }
        }
        .onChange(of: service.pendingConfirmation) { _, pending in
            // The webhook landed while this sheet was open: the service
            // already selected the new workspace; close the sheet onto it.
            // (A "Stop waiting" also clears `pending` — then there is no new
            // owner-role workspace to land on, and the sheet just stays.)
            if checkoutOpened, pending == nil, let detail = service.detail,
                detail.typedRole == .owner, !idsBeforeCheckout.contains(detail.id)
            {
                dismiss()
                onCreated(detail)
            }
        }
    }

    @ViewBuilder
    private var composeBody: some View {
        AgentSheetSectionLabel("Workspace name")
        StyledTextField(
            placeholder: L("Workspace name"),
            text: $name,
            icon: "rectangle.3.group",
            autofocus: true
        )
        .onSubmit { if nameIsValid && !hitTrialLimit { submit() } }

        if needsCheckout, livePrices.count > 1 {
            AgentSheetSectionLabel("Billing")
            Picker(selection: $selectedPriceId) {
                ForEach(livePrices) { price in
                    Text(price.displayLabel ?? price.billingInterval ?? price.id).tag(Optional(price.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        planSummary

        if hitTrialLimit {
            SheetHintRow(kind: .warning, message: trialLimitMessage)
        } else if let errorMessage {
            SheetHintRow(kind: .error, message: errorMessage)
        } else if trimmedName.count > WorkspaceNameValidation.maxLength {
            SheetHintRow(
                kind: .warning,
                message: String(
                    format: L("Workspace names are capped at 80 characters (currently %d)."),
                    trimmedName.count
                )
            )
        } else if trimmedName.isEmpty {
            SheetHintRow(kind: .info, message: L("Name it after your group — you can rename it anytime."))
        } else if needsCheckout {
            SheetHintRow(kind: .info, message: checkoutHint)
        } else {
            SheetHintRow(
                kind: .ok,
                message: String(format: L("\"%@\" it is. You'll be the owner."), trimmedName)
            )
        }
    }

    /// What every workspace includes, from the public plan (quiet when the
    /// router hasn't answered).
    @ViewBuilder
    private var planSummary: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 6) {
                if let monthly = plan.monthlyCreditMicro, monthly != "0" {
                    planLine(
                        icon: "creditcard.fill",
                        text: String(
                            format: L("%@ shared credits every month — no rollover"),
                            OsaurusRouter.formatMicroAsCreditsValue(monthly)
                        )
                    )
                }
                planLine(
                    icon: "person.2.fill",
                    text: plan.seats.map { String(format: L("Up to %d members"), $0) } ?? L("Unlimited members")
                )
                planLine(
                    icon: "antenna.radiowaves.left.and.right",
                    text: plan.maxSharedAgents.map { String(format: L("Up to %d shared agents"), $0) }
                        ?? L("Unlimited shared agents")
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground.opacity(0.5))
            )
        }
    }

    private func planLine(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
        }
    }

    /// "14 days free, then $20/month. Card collected now; first charge on
    /// the trial end." / "$20/month, billed by Stripe in your browser."
    private var checkoutHint: String {
        let priceText = selectedPrice?.displayLabel
        if service.trialEligible, let days = service.trialDays, days > 0 {
            if let priceText {
                return String(
                    format: L("%d days free, then %@. Your card is collected now and first charged when the trial ends."),
                    days, priceText
                )
            }
            return String(format: L("%d days free. Your card is collected now and first charged when the trial ends."), days)
        }
        if let priceText {
            return String(format: L("%@, billed by Stripe. You'll finish the purchase in your browser."), priceText)
        }
        return L("You'll finish the purchase with Stripe in your browser.")
    }

    private var trialLimitMessage: String {
        if let raw = service.trialEndsAt, let date = WorkspacesFormatting.date(raw) {
            return String(
                format: L("Your free trial covers one workspace. You can add more after it converts on %@."), date
            )
        }
        return L("Your free trial covers one workspace. You can add more once the trial converts to a paid subscription.")
    }

    @ViewBuilder
    private var checkoutOpenedBody: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: L("Waiting for Stripe to confirm “%@”"), trimmedName))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    L(
                        "Nothing is charged until you complete the checkout. Osaurus checks for the new workspace each time you come back to it; you can also close this and refresh the list."
                    )
                )
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground.opacity(0.5))
        )
        SheetHintRow(
            kind: .info,
            message: L("Closed the browser tab without paying? Just close this — nothing was created or charged.")
        )
    }

    private func submit() {
        guard !checkoutOpened, nameIsValid else { return }
        let priceId = needsCheckout ? selectedPrice?.id : nil
        idsBeforeCheckout = Set(service.workspaces.map(\.id))
        Task {
            if let outcome = await service.createWorkspace(name: name, priceId: priceId) {
                switch outcome {
                case .ready(let detail):
                    dismiss()
                    onCreated(detail)
                case .checkoutOpened:
                    withAnimation(.easeOut(duration: 0.2)) { checkoutOpened = true }
                }
            } else {
                // Scope the failure to this sheet: the page banner behind it
                // must not double-surface (and outlive) the same message.
                if service.lastErrorCode == .trialWorkspaceLimit {
                    hitTrialLimit = true
                    errorMessage = nil
                } else {
                    errorMessage = service.lastError
                }
                service.lastError = nil
            }
        }
    }
}

// MARK: - Activate web-purchased workspace

/// Redeems a subscription purchased on osaurus.ai. Two entry modes:
/// - Deeplink (`pending` set): the code is fixed and shown read-only, the
///   name is prefilled from the web when it collected one. One confirm.
/// - Manual (`pending == nil`): the user pastes the code — the fallback for
///   a deeplink that didn't open (browser blocked the scheme, wrong
///   machine, etc.).
/// On success the router has created the workspace; the caller navigates to it.
struct ActivateWorkspaceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared

    let pending: PendingWorkspaceActivation?
    var onActivated: (OsaurusRouterWorkspaceDetail) -> Void = { _ in }

    @State private var code = ""
    @State private var name = ""
    @State private var errorMessage: String?

    private var isDeeplink: Bool { pending != nil }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var codeLooksValid: Bool { PendingWorkspaceActivation.isPlausibleCode(trimmedCode) }
    private var nameIsValid: Bool { WorkspaceNameValidation.isValid(name) }

    var body: some View {
        WorkspaceSheetShell(
            icon: "checkmark.seal.fill",
            title: "Activate your workspace",
            subtitle: isDeeplink
                ? L("Your subscription from osaurus.ai is ready. Name the workspace and you're in.")
                : L("Paste the activation code from osaurus.ai to create your workspace here."),
            confirmTitle: "Activate",
            isBusy: service.isBusy("workspace.activate"),
            isValid: codeLooksValid && nameIsValid,
            onConfirm: { submit() },
            height: 400
        ) {
            if let plan = pending?.planLabel, !plan.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                    Text(String(format: L("Plan: %@"), plan))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer(minLength: 0)
                }
            }

            AgentSheetSectionLabel("Activation code")
            if isDeeplink {
                // Read-only code row: the deeplink fixed it; retyping would
                // only invite typos.
                SheetReadOnlyValue(icon: "key.fill", value: code)
            } else {
                StyledTextField(
                    placeholder: L("Activation code"),
                    text: $code,
                    icon: "key.fill",
                    monospaced: true,
                    autofocus: true
                )
            }

            AgentSheetSectionLabel("Workspace name")
            StyledTextField(
                placeholder: L("Workspace name"),
                text: $name,
                icon: "rectangle.3.group",
                autofocus: isDeeplink
            )
            .onSubmit { if codeLooksValid && nameIsValid { submit() } }

            if let errorMessage {
                SheetHintRow(kind: .error, message: errorMessage)
            } else if !isDeeplink, !trimmedCode.isEmpty, !codeLooksValid {
                SheetHintRow(kind: .warning, message: L("That doesn't look like an activation code yet."))
            } else if trimmedName.count > WorkspaceNameValidation.maxLength {
                SheetHintRow(
                    kind: .warning,
                    message: String(
                        format: L("Workspace names are capped at 80 characters (currently %d)."),
                        trimmedName.count
                    )
                )
            } else if trimmedName.isEmpty {
                SheetHintRow(kind: .info, message: L("Name it after your group — you can rename it anytime."))
            } else if codeLooksValid {
                SheetHintRow(
                    kind: .ok,
                    message: String(format: L("\"%@\" it is. You'll be the owner."), trimmedName)
                )
            } else {
                SheetHintRow(kind: .info, message: L("The code is on your osaurus.ai receipt and account page."))
            }
        }
        .onAppear {
            if let pending {
                code = pending.code
                name = pending.suggestedName ?? WorkspacesService.defaultActivationName
            } else {
                name = WorkspacesService.defaultActivationName
            }
        }
    }

    private func submit() {
        guard codeLooksValid, nameIsValid else { return }
        Task {
            if let detail = await service.activate(code: code, name: name) {
                dismiss()
                onActivated(detail)
            } else {
                // Scope the failure to this sheet: the page banner behind it
                // must not double-surface (and outlive) the same message.
                errorMessage = service.lastError
                service.lastError = nil
            }
        }
    }
}

// MARK: - Join workspace

/// Redeems an invite link. Two entry modes mirroring `ActivateWorkspaceSheet`:
/// - Deeplink (`pending` set): code shown read-only; tapping Join is the
///   consent step (a link is never redeemed just by opening it).
/// - Manual (`pending == nil`): the user pastes the code from a link that
///   didn't open.
struct JoinWorkspaceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared

    let pending: PendingWorkspaceJoin?
    var onJoined: (OsaurusRouterWorkspaceDetail) -> Void = { _ in }

    @State private var code = ""
    @State private var errorMessage: String?

    private var isDeeplink: Bool { pending != nil }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var codeLooksValid: Bool { OsaurusRouterWorkspaceCode.isPlausible(trimmedCode) }

    var body: some View {
        WorkspaceSheetShell(
            icon: "person.badge.plus",
            title: "Join workspace",
            subtitle: isDeeplink
                ? L("A teammate invited you. Joining adds you to their workspace with the role they chose.")
                : L("Paste the code from an invite link — the part after \"code=\" — or the whole link."),
            confirmTitle: "Join",
            isBusy: service.isBusy("workspace.join"),
            isValid: codeLooksValid,
            onConfirm: { submit() },
            height: 300
        ) {
            AgentSheetSectionLabel("Invite code")
            if isDeeplink {
                SheetReadOnlyValue(icon: "link", value: code)
            } else {
                StyledTextField(
                    placeholder: L("Invite code or link"),
                    text: $code,
                    icon: "link",
                    monospaced: true,
                    autofocus: true
                )
                .onSubmit { if codeLooksValid { submit() } }
                .onChange(of: code) { _, raw in
                    // Pasting the whole `osaurus://workspaces/join?code=…` link is
                    // the common case; reduce it to the code.
                    if let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                        let parsed = WorkspacesDeepLinkRouter.parseJoin(url)
                    {
                        code = parsed.code
                    }
                }
            }

            if let errorMessage {
                SheetHintRow(kind: .error, message: errorMessage)
            } else if !isDeeplink, !trimmedCode.isEmpty, !codeLooksValid {
                SheetHintRow(kind: .warning, message: L("That doesn't look like an invite code yet."))
            } else if codeLooksValid {
                SheetHintRow(kind: .ok, message: L("You'll see the workspace's shared agents right away."))
            } else {
                SheetHintRow(kind: .info, message: L("Invite links look like osaurus://workspaces/join?code=…"))
            }
        }
        .onAppear {
            if let pending { code = pending.code }
        }
    }

    private func submit() {
        guard codeLooksValid else { return }
        Task {
            if let detail = await service.join(code: trimmedCode) {
                dismiss()
                onJoined(detail)
            } else {
                errorMessage = service.lastError
                service.lastError = nil
            }
        }
    }
}

// MARK: - Create invite link

/// Mints an invite link, then flips to a result state with the link and a
/// Copy button — the owner shares it however they like (chat, email).
struct CreateInviteLinkSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared

    let workspaceId: String
    /// Only owners can mint admin links.
    let isOwner: Bool
    /// Seats left under the plan's seat cap (`nil` when unlimited or unknown).
    var seatsRemaining: Int? = nil
    var onCreated: (OsaurusRouterWorkspaceInvite) -> Void = { _ in }

    @State private var role: OsaurusRouterWorkspaceRole = .member
    @State private var maxUses = 1
    @State private var minted: OsaurusRouterWorkspaceInvite?
    @State private var errorMessage: String?

    private static let usesRange = 1...100

    private var roleExplainer: String {
        switch role {
        case .viewer:
            return L("Viewers can use the workspace's shared agents but can't share their own.")
        case .admin:
            return L("Admins can invite and remove members and manage shared agents.")
        case .member, .owner:
            return L("Members can use shared agents, share their own, and spend from the pool.")
        }
    }

    var body: some View {
        if let minted {
            resultFrame(minted)
        } else {
            composeFrame
        }
    }

    private var composeFrame: some View {
        WorkspaceSheetShell(
            icon: "link.badge.plus",
            title: "Create invite link",
            subtitle: String(
                format: L("Anyone who opens this link in Osaurus joins as %@. Links expire in 14 days."),
                role.displayName.lowercased()
            ),
            confirmTitle: "Create link",
            isBusy: service.isBusy("invite.create"),
            isValid: seatsRemaining != 0,
            onConfirm: { submit() },
            height: 360
        ) {
            AgentSheetSectionLabel("Role")
            Picker(selection: $role) {
                Text("Viewer", bundle: .module).tag(OsaurusRouterWorkspaceRole.viewer)
                Text("Member", bundle: .module).tag(OsaurusRouterWorkspaceRole.member)
                if isOwner {
                    Text("Admin", bundle: .module).tag(OsaurusRouterWorkspaceRole.admin)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(roleExplainer)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            AgentSheetSectionLabel("Uses")
            HStack(spacing: 10) {
                Stepper(value: $maxUses, in: Self.usesRange) {
                    Text(
                        maxUses == 1
                            ? L("1 person")
                            : String(format: L("Up to %d people"), maxUses)
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            if let seatsRemaining {
                SheetHintRow(
                    kind: seatsRemaining == 0 || maxUses > seatsRemaining ? .warning : .info,
                    message: seatsRemaining == 0
                        ? L("No seats left in this workspace — free a seat before inviting.")
                        : maxUses > seatsRemaining
                            ? String(
                                format: L("Only %d seats left — extra joins will fail until a seat is freed."),
                                seatsRemaining
                            )
                            : seatsRemaining == 1
                                ? L("1 seat left in this workspace.")
                                : String(format: L("%d seats left in this workspace."), seatsRemaining)
                )
            }

            if let errorMessage {
                SheetHintRow(kind: .error, message: errorMessage)
            }
        }
    }

    private func resultFrame(_ invite: OsaurusRouterWorkspaceInvite) -> some View {
        WorkspaceSheetShell(
            icon: "checkmark.circle.fill",
            title: "Invite link ready",
            subtitle: String(
                format: L("Share it with your teammate. Anyone who opens it in Osaurus joins as %@."),
                (invite.role.flatMap(OsaurusRouterWorkspaceRole.init(rawValue:)) ?? role)
                    .displayName.lowercased()
            ),
            confirmTitle: "Done",
            isBusy: false,
            isValid: true,
            onConfirm: {},
            secondaryTitle: "Close",
            confirmDismisses: true,
            height: 280
        ) {
            CopyableURLField(label: L("Invite link"), url: invite.url ?? invite.code ?? "")

            SheetHintRow(kind: .info, message: inviteFooter(invite))
        }
        .onAppear {
            // Copying is what the user opened this sheet to do; save a click.
            copyLink(invite)
        }
    }

    private func inviteFooter(_ invite: OsaurusRouterWorkspaceInvite) -> String {
        var parts: [String] = []
        let uses = invite.maxUses ?? maxUses
        parts.append(uses == 1 ? L("Single use") : String(format: L("Up to %d uses"), uses))
        if let expires = invite.expiresAt, let date = WorkspacesFormatting.date(expires) {
            parts.append(String(format: L("expires %@"), date))
        }
        parts.append(L("copied to your clipboard — you can copy it again or revoke it from Members."))
        return parts.joined(separator: " · ")
    }

    private func copyLink(_ invite: OsaurusRouterWorkspaceInvite) {
        guard let payload = invite.url ?? invite.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    private func submit() {
        Task {
            if let invite = await service.mintInvite(workspaceId: workspaceId, role: role, maxUses: maxUses) {
                onCreated(invite)
                withAnimation(.easeOut(duration: 0.2)) { minted = invite }
            } else {
                errorMessage = service.lastError
                service.lastError = nil
            }
        }
    }
}

// MARK: - Share agent

struct WorkspaceShareAgentSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WorkspacesService.shared
    @ObservedObject private var agentManager = AgentManager.shared

    let workspaceId: String
    var onSuccess: () -> Void = {}

    @State private var selectedAgentId: UUID?
    @State private var displayName = ""
    /// The last value we auto-filled into `displayName` from an agent's name.
    /// Lets a later selection replace an untouched prefill while leaving a
    /// name the user typed alone.
    @State private var prefilledName: String?
    @State private var descriptionText = ""
    @State private var errorMessage: String?
    @State private var isPreparing = false

    static let displayNameMaxLength = 120

    /// Display name to show after the user picks `selectedAgentName`.
    /// Follows the selection when the field is empty or still holds the
    /// previous auto-fill; preserves anything the user typed themselves.
    static func nextDisplayName(
        current: String,
        prefilled: String?,
        selectedAgentName: String
    ) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == prefilled {
            return selectedAgentName
        }
        return current
    }

    /// Lowercased addresses already on this workspace's roster — those rows
    /// render disabled with "Already shared" instead of failing on submit.
    static func alreadySharedAddresses(
        roster: [OsaurusRouterWorkspaceAgent]
    ) -> Set<String> {
        Set(roster.map { $0.agentAddress.lowercased() })
    }

    /// 1–120 characters after trimming.
    static func displayNameIsValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= displayNameMaxLength
    }

    /// Every agent the user built. Sharing needs an agent key (the ownership
    /// proof is signed by that derived key) and the relay tunnel (teammates
    /// reach the agent through it); both are turned on as part of sharing
    /// when missing, so a share is one click rather than a detour through
    /// the Agents tab. Built-in agents have no key and can't be shared.
    private var shareableAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    private var alreadyShared: Set<String> {
        Self.alreadySharedAddresses(roster: service.workspaceAgents)
    }

    private func isAlreadyShared(_ agent: Agent) -> Bool {
        guard let address = agent.agentAddress?.lowercased() else { return false }
        return alreadyShared.contains(address)
    }

    private var selectedAgent: Agent? {
        shareableAgents.first { $0.id == selectedAgentId }
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        guard let agent = selectedAgent, !isAlreadyShared(agent) else { return false }
        return Self.displayNameIsValid(displayName) && !isPreparing
    }

    /// What sharing will switch on for the selected agent, if anything.
    private var setupNeeded: (identity: Bool, relay: Bool)? {
        guard let agent = selectedAgent else { return nil }
        let identity = agent.agentAddress == nil || agent.agentIndex == nil
        let relay = !RelayTunnelManager.shared.isTunnelEnabled(for: agent.id)
        return (identity || relay) ? (identity, relay) : nil
    }

    var body: some View {
        WorkspaceSheetShell(
            icon: "person.2.fill",
            title: "Share agent",
            subtitle: L(
                "Teammates chat with it from their own Osaurus while it keeps running on this Mac. Its billing stays yours unless you enable workspace billing."
            ),
            confirmTitle: "Share agent",
            isBusy: service.isBusy("agent.share") || isPreparing,
            isValid: isValid,
            onConfirm: { submit() },
            height: 560
        ) {
            if shareableAgents.isEmpty {
                AgentSectionEmptyState(
                    icon: "theatermasks",
                    title: "No agents to share yet",
                    hint: "Create one in the Agents tab, then share it here."
                )
            } else {
                AgentSheetSectionLabel("Agent")
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(shareableAgents, id: \.id) { agent in
                            agentRow(agent)
                        }
                    }
                }
                .frame(maxHeight: 220)

                if let setup = setupNeeded {
                    SheetHintRow(kind: .info, message: setupMessage(setup))
                }

                AgentSheetSectionLabel("Shown to teammates as")
                StyledTextField(
                    placeholder: L("Display name for the workspace"),
                    text: $displayName,
                    icon: "textformat"
                )
                if !trimmedDisplayName.isEmpty, !Self.displayNameIsValid(displayName) {
                    SheetHintRow(
                        kind: .warning,
                        message: String(
                            format: L("Display names are capped at 120 characters (currently %d)."),
                            trimmedDisplayName.count
                        )
                    )
                } else if selectedAgent != nil, trimmedDisplayName.isEmpty {
                    SheetHintRow(kind: .info, message: L("Teammates see this name in their sidebar."))
                }

                AgentSheetSectionLabel("Description (optional)")
                StyledTextField(
                    placeholder: L("What this agent is good at"),
                    text: $descriptionText,
                    icon: "text.alignleft"
                )
            }

            if let errorMessage {
                SheetHintRow(kind: .error, message: errorMessage)
            }
        }
    }

    /// Same consent copy the Agents tab's relay toggle uses: the relay
    /// exposes the agent to the internet (through Osaurus' relay), not just
    /// to the workspace.
    private func setupMessage(_ setup: (identity: Bool, relay: Bool)) -> String {
        switch (setup.identity, setup.relay) {
        case (true, true):
            return L(
                "Sharing gives this agent its own identity key and turns on its relay tunnel. The relay makes the agent reachable over the internet; only workspace members can authenticate to it. It keeps running on this Mac."
            )
        case (true, false):
            return L("Sharing gives this agent its own identity key, which signs the ownership proof.")
        default:
            return L(
                "Sharing turns on this agent's relay tunnel. The relay makes the agent reachable over the internet; only workspace members can authenticate to it. It keeps running on this Mac."
            )
        }
    }

    /// Makes sure the agent has an identity key and the relay tunnel enabled,
    /// returning the (address, index) to sign with. Nil when no master key
    /// exists to derive from (the tab's Identity gate normally prevents this).
    private func prepareForSharing(_ agent: Agent) -> (address: String, index: UInt32)? {
        var current = agent
        if current.agentAddress == nil || current.agentIndex == nil {
            try? AgentManager.shared.assignAddress(to: current)
            guard let refreshed = AgentManager.shared.agent(for: agent.id) else { return nil }
            current = refreshed
        }
        guard let address = current.agentAddress, let index = current.agentIndex else {
            return nil
        }
        if !RelayTunnelManager.shared.isTunnelEnabled(for: current.id) {
            RelayTunnelManager.shared.setTunnelEnabled(true, for: current.id)
        }
        return (address, index)
    }

    private func submit() {
        guard let agent = selectedAgent, isValid else { return }
        isPreparing = true
        guard let signer = prepareForSharing(agent) else {
            isPreparing = false
            errorMessage = L(
                "Couldn't give this agent an identity key. Set up your Osaurus Identity in the Identity tab, then try again."
            )
            return
        }
        isPreparing = false
        Task {
            let ok = await service.shareAgent(
                workspaceId: workspaceId,
                agentAddress: signer.address,
                agentIndex: signer.index,
                displayName: displayName,
                description: descriptionText.isEmpty ? nil : descriptionText
            )
            if ok {
                onSuccess()
                dismiss()
            } else {
                errorMessage = service.lastError
                service.lastError = nil
            }
        }
    }

    private func agentRow(_ agent: Agent) -> some View {
        let isSelected = selectedAgentId == agent.id
        let shared = isAlreadyShared(agent)
        return Button(action: {
            guard !shared else { return }
            selectedAgentId = agent.id
            let next = Self.nextDisplayName(
                current: displayName,
                prefilled: prefilledName,
                selectedAgentName: agent.name
            )
            if next == agent.name {
                prefilledName = agent.name
            }
            displayName = next
        }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                AgentAvatarView(
                    mascotId: agent.avatar,
                    name: agent.name,
                    tint: agentColorFor(agent.name),
                    diameter: 26,
                    customImageURL: agent.customAvatarURL,
                    monogramFontSize: 11,
                    borderWidth: 1.5
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if let address = agent.agentAddress {
                        Text(SharedAgentIdentity.shortAddress(address))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .help(address)
                    } else {
                        Text("Identity key and relay are set up when you share", bundle: .module)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if shared {
                    CapsuleBadge(L("Already shared"), tint: theme.successColor, icon: "checkmark")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? theme.accentColor.opacity(0.08)
                            : theme.inputBackground.opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isSelected ? theme.accentColor.opacity(0.5) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(shared ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(shared)
        .help(shared ? L("This agent is already shared with the workspace.") : "")
    }
}
