import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !OsaurusIdentity.exists() {
                        identityRequiredCard
                    }
                    balanceCard
                    usageCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .task { await accountService.refreshAll() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Dashboard"),
            subtitle: L("Credits, top-ups, and router inference history")
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: accountService.isLoadingBalance || accountService.isLoadingUsage,
                help: "Refresh"
            ) {
                Task { await accountService.refreshAll() }
            }
            HeaderPrimaryButton("Load balance", icon: "creditcard.fill") {
                Task { await openCheckout() }
            }
            .disabled(!OsaurusIdentity.exists() || accountService.isCreatingCheckout)
            .opacity((!OsaurusIdentity.exists() || accountService.isCreatingCheckout) ? 0.55 : 1)
        }
    }

    private var identityRequiredCard: some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up your Osaurus Identity", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "The router uses your identity master key as your billing account. Create or restore an identity before adding balance or calling Osaurus models.",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        ManagementStateManager.shared.selectedTab = .identity
                    } label: {
                        Text("Open Identity", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private var balanceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Credit balance", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: accountService.formattedBalance)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(theme.primaryText)
                            if accountService.isLoadingBalance {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }
                    }

                    Spacer()

                    if accountService.isFrozen {
                        statusPill("Frozen", icon: "pause.circle.fill", color: theme.warningColor)
                    } else {
                        statusPill("Active", icon: "checkmark.circle.fill", color: theme.successColor)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Label("Minimum top-up is $5.00", systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    if accountService.isCreatingCheckout {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Button {
                        Task { await openCheckout() }
                    } label: {
                        Label("Load $5.00", systemImage: "creditcard.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!OsaurusIdentity.exists() || accountService.isCreatingCheckout)
                }

                if let error = accountService.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var usageCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inference history", bundle: .module)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Billed router calls from this identity", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Text("\(accountService.usage.count)", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }

                if accountService.usage.isEmpty {
                    emptyUsageState
                } else {
                    VStack(spacing: 0) {
                        usageHeader
                        ForEach(accountService.usage) { item in
                            usageRow(item)
                            if item.id != accountService.usage.last?.id {
                                Divider()
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
                }

                if accountService.nextUsageCursor != nil {
                    HStack {
                        Spacer()
                        Button {
                            Task { await accountService.loadMoreUsage() }
                        } label: {
                            if accountService.isLoadingUsage {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("Load more", bundle: .module)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(accountService.isLoadingUsage)
                    }
                }
            }
        }
    }

    private var usageHeader: some View {
        HStack(spacing: 12) {
            tableHeader("Model", width: nil)
            tableHeader("Tokens", width: 100)
            tableHeader("Cost", width: 90)
            tableHeader("Status", width: 90)
            tableHeader("Time", width: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.tertiaryBackground)
    }

    private var emptyUsageState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No router inference yet", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Calls made through the Osaurus provider will appear here with cost and token details.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func usageRow(_ item: OsaurusRouterUsageItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.model)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(item.provider)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(item.inputTokens) / \(item.outputTokens)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .frame(width: 100, alignment: .leading)

            Text(OsaurusRouter.formatMicroUSD(item.costMicro))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .frame(width: 90, alignment: .leading)

            Text(item.status.capitalized)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor(item.status))
                .frame(width: 90, alignment: .leading)

            Text(shortDate(item.createdAt))
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .frame(width: 120, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.cardBackground)
    }

    @ViewBuilder
    private func tableHeader(_ title: String, width: CGFloat?) -> some View {
        let label = Text(LocalizedStringKey(title), bundle: .module)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
        if let width {
            label.frame(width: width, alignment: .leading)
        } else {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusPill(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
    }

    private func openCheckout() async {
        guard let url = await accountService.createCheckout() else { return }
        NSWorkspace.shared.open(url)
    }

    private func shortDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "completed":
            return theme.successColor
        case "aborted":
            return theme.warningColor
        default:
            return theme.errorColor
        }
    }
}
