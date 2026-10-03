//
//  InsightsView.swift
//  osaurus
//
//  Activity / audit dashboard. Every interaction this Mac ran or sent —
//  local inference, cloud inference, web searches, URL fetches, MCP
//  calls, channel deliveries, Router calls, inbound API traffic, media
//  work and plugin activity — is a row.
//
//  Layout, top to bottom: a glance strip (events · left this Mac · failed
//  · privacy-filtered, each a one-tap filter), a single toolbar row
//  (search · time range · Filter popover) with removable tokens for every
//  active criterion, a scope tab row that groups the categories, then the
//  event list. At wide widths a selected row opens in a side inspector so
//  rows can be clicked through; narrow windows fall back to push/back.
//  Verify checks the hash chain; Export writes JSONL / CSV / Markdown.
//

import SwiftUI

struct InsightsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var insightsService = InsightsService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var selectedLog: RequestLog?
    @State private var showClearConfirmation = false
    @State private var showExportSheet = false
    @State private var showVerification = false
    @State private var showFilterPopover = false

    /// Content width at or above which a selected row opens beside the list
    /// instead of replacing it. The management window with its sidebar open
    /// crosses this around a 1280pt window.
    static let inspectorBreakpoint: CGFloat = 1040
    static let inspectorWidth: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            GeometryReader { geo in
                let useInspector = geo.size.width >= Self.inspectorBreakpoint
                Group {
                    if useInspector {
                        inspectorLayout
                    } else {
                        pushLayout
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) { hasAppeared = true }
            insightsService.reload()
            applyPendingFocus(insightsService.pendingFocusLogId)
        }
        .onChange(of: insightsService.pendingFocusLogId) { _, newValue in
            applyPendingFocus(newValue)
        }
        .onChange(of: insightsService.lastVerification) { _, newValue in
            showVerification = newValue != nil
        }
        .themedAlert(
            L("Clear Activity Log"),
            isPresented: $showClearConfirmation,
            message: L(
                "This removes every recorded interaction from this Mac. The log will record that it was cleared. Export first if you need a copy."
            ),
            primaryButton: .destructive(L("Clear")) { insightsService.clear() },
            secondaryButton: .cancel(L("Cancel"))
        )
        .sheet(isPresented: $showExportSheet) {
            ActivityExportSheet(
                filter: insightsService.filter,
                filteredCount: insightsService.totalRequestCount,
                onExport: { options in
                    showExportSheet = false
                    ActivityExportCoordinator.run(options: options, filter: insightsService.filter)
                },
                onCancel: { showExportSheet = false }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    // MARK: - Layouts

    /// Wide: chrome on top, list and inspector side by side underneath.
    private var inspectorLayout: some View {
        VStack(spacing: 0) {
            chrome
            HStack(spacing: 0) {
                eventList(compact: selectedLog != nil, presentation: .inspector)
                    .frame(maxWidth: .infinity)
                if let selected = selectedLog {
                    Divider().background(theme.primaryBorder.opacity(0.3))
                    InsightsDetailPane(log: selected, presentation: .inspector, onBack: pop)
                        .frame(width: Self.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: selectedLog?.id)
        }
    }

    /// Narrow: a selected row replaces the whole page; Back returns.
    private var pushLayout: some View {
        ZStack {
            if let selected = selectedLog {
                InsightsDetailPane(log: selected, presentation: .page, onBack: pop)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            } else {
                VStack(spacing: 0) {
                    chrome
                    eventList(compact: false, presentation: .page)
                }
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedLog == nil)
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Insights"),
            subtitle: L("Activity and audit log for everything this Mac ran or sent")
        ) {
            HeaderPrimaryButton(L("Export"), icon: "square.and.arrow.up") {
                showExportSheet = true
            }
            .disabled(!insightsService.hasLogs)

            Menu {
                Button(action: { insightsService.verify() }) {
                    Label(L("Verify Integrity"), systemImage: "checkmark.shield")
                }
                .disabled(!insightsService.hasLogs || insightsService.isVerifying || insightsService.activityStore == nil)
                Divider()
                Button(role: .destructive, action: { showClearConfirmation = true }) {
                    Label(L("Clear Activity Log…"), systemImage: "trash")
                }
                .disabled(!insightsService.hasLogs)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Verify or clear the log", bundle: .module))
        }
    }

    // MARK: - Chrome (glance · toolbar · scopes)

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = insightsService.storeError {
                InlineNotice(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: String(format: L("Activity log storage is unavailable (%@). Showing this session only."), error)
                )
            }
            if showVerification, let v = insightsService.lastVerification {
                verificationBanner(v)
            }
            InsightsGlanceStrip(summary: insightsService.summary, filter: $insightsService.filter)
            InsightsToolbar(service: insightsService, showFilterPopover: $showFilterPopover)
            InsightsScopeBar(filter: $insightsService.filter)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func verificationBanner(_ v: ActivityLogVerification) -> some View {
        let tint: Color = v.isIntact ? .green : .red
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: v.isIntact ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        v.isIntact
                            ? String(format: L("Integrity verified: %d records, chain intact"), v.recordCount)
                            : String(format: L("Integrity problems found in %d records"), v.recordCount)
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    if let first = v.firstSeq, let last = v.lastSeq, let hash = v.lastHash {
                        Text("#\(first) – #\(last) · \(String(hash.prefix(16)))… · \(df.string(from: v.checkedAt))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                Spacer()
                Button(action: { withAnimation { showVerification = false } }) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(v.problems.prefix(8).enumerated()), id: \.offset) { _, p in
                Text("• " + p.description).font(.system(size: 11)).foregroundColor(theme.secondaryText)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Event list

    private func eventList(compact: Bool, presentation: InsightsDetailPresentation) -> some View {
        VStack(spacing: 0) {
            if !insightsService.pagedLogs.isEmpty {
                tableHeader(compact: compact)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if insightsService.pagedLogs.isEmpty {
                            emptyStateView
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            ForEach(Self.groupByDay(insightsService.pagedLogs), id: \.key) { group in
                                Section(header: dayHeader(group.key, count: group.rows.count)) {
                                    ForEach(group.rows) { log in
                                        ActivityRow(
                                            log: log,
                                            compact: compact,
                                            isSelected: selectedLog?.id == log.id,
                                            onTap: { select(log) }
                                        )
                                        .id(log.id)
                                    }
                                }
                            }
                            if insightsService.canLoadMore {
                                loadMoreRow
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveSelection(by: 1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveSelection(by: -1, proxy: proxy) }
                .onKeyPress(.escape) {
                    guard presentation == .inspector, selectedLog != nil else { return .ignored }
                    pop()
                    return .handled
                }
                .onChange(of: selectedLog?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: nil) }
                }
            }
        }
    }

    private func tableHeader(compact: Bool) -> some View {
        let columns = ActivityTableColumns(compact: compact)
        return HStack(spacing: 0) {
            Spacer().frame(width: columns.status)
            Text("TIME", bundle: .module).frame(width: columns.time, alignment: .leading)
            Text("EVENT", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text("SOURCE", bundle: .module).frame(width: columns.source, alignment: .leading)
            }
            Text("DURATION", bundle: .module).frame(width: columns.duration, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(theme.tertiaryText.opacity(0.7))
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().background(theme.primaryBorder.opacity(0.3)) }
    }

    private func dayHeader(_ key: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(Self.dayLabel(key))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            Text(count == 1 ? L("1 event") : String(format: L("%d events"), count))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(theme.primaryBackground.opacity(0.96))
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if insightsService.isLoading {
                ProgressView().scaleEffect(0.7)
            } else {
                Button(action: { insightsService.loadMore() }) {
                    Text(
                        String(
                            format: L("Load more (%d of %d)"),
                            insightsService.pagedLogs.count,
                            insightsService.totalRequestCount
                        )
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .onAppear { insightsService.loadMore() }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: insightsService.filter.isEmpty ? "list.bullet.clipboard" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 48))
                .foregroundColor(theme.tertiaryText.opacity(0.3))
            Text(insightsService.filter.isEmpty ? L("No Activity Yet") : L("Nothing Matches These Filters"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)
            Text(
                insightsService.filter.isEmpty
                    ? L("Chats, cloud requests, web searches, tool calls and API traffic will appear here as they happen.")
                    : L("Try widening the time range or clearing a filter.")
            )
            .font(.system(size: 13))
            .foregroundColor(theme.tertiaryText)
            .multilineTextAlignment(.center)
            if !insightsService.filter.isEmpty {
                Button(action: { insightsService.clearFilters() }) {
                    Text("Clear filters", bundle: .module).font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
            }
        }
        .padding(40)
    }

    // MARK: - Selection / navigation

    private func pop() {
        withAnimation(.easeInOut(duration: 0.22)) { selectedLog = nil }
    }

    private func select(_ log: RequestLog) {
        withAnimation(.easeInOut(duration: 0.22)) { selectedLog = log }
    }

    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = insightsService.pagedLogs
        guard !rows.isEmpty else { return .ignored }
        let next: Int
        if let current = selectedLog, let idx = rows.firstIndex(where: { $0.id == current.id }) {
            next = min(max(idx + delta, 0), rows.count - 1)
        } else {
            next = delta > 0 ? 0 : rows.count - 1
        }
        select(rows[next])
        return .handled
    }

    private func applyPendingFocus(_ logId: UUID?) {
        guard let logId else { return }
        defer { insightsService.pendingFocusLogId = nil }
        guard let log = insightsService.log(id: logId) else { return }
        select(log)
    }

    // MARK: - Grouping helpers

    struct DayGroup {
        let key: String
        let rows: [RequestLog]
    }

    static func groupByDay(_ logs: [RequestLog]) -> [DayGroup] {
        var order: [String] = []
        var buckets: [String: [RequestLog]] = [:]
        for log in logs {
            let key = log.dayKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(log)
        }
        return order.map { DayGroup(key: $0, rows: buckets[$0] ?? []) }
    }

    static func dayLabel(_ key: String, now: Date = Date()) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("Today") }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Category tint

extension ActivityCategory {
    /// Muted hue used only for the row glyph and the detail header glyph.
    var tint: Color {
        switch self {
        case .inference: return .purple
        case .compaction: return .indigo
        case .webSearch: return .teal
        case .urlExtract: return .cyan
        case .mcpToolCall: return .orange
        case .channelDelivery: return .pink
        case .routerControl: return .blue
        case .inboundAPI: return .blue
        case .pluginCall, .pluginLog: return .teal
        case .embedding: return .mint
        case .audioTranscription: return .green
        case .speechSynthesis: return .yellow
        case .mediaGeneration: return .pink
        case .system: return .gray
        }
    }
}

// MARK: - Glance strip

/// Four quiet stat tiles. The last three double as one-tap filters so the
/// headline numbers answer "did anything leave, did anything fail, was
/// anything redacted" and let the reviewer jump straight to those rows.
private struct InsightsGlanceStrip: View {
    @Environment(\.theme) private var theme
    let summary: ActivitySummary
    @Binding var filter: ActivityFilter

    @State private var showDestinations = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GlanceTile(
                    value: "\(summary.totalCount)",
                    label: L("Events"),
                    isActive: false,
                    action: nil
                )
                GlanceTile(
                    value: "\(summary.remoteCount)",
                    detail: summary.totalCount > 0 && summary.remoteCount > 0
                        ? String(format: "%.0f%%", summary.remoteShare * 100) : nil,
                    label: L("Left this Mac"),
                    isActive: filter.locality == .remote,
                    action: { filter.locality = filter.locality == .remote ? nil : .remote }
                )
                GlanceTile(
                    value: "\(summary.errorCount)",
                    label: L("Failed"),
                    valueTint: summary.errorCount > 0 ? theme.errorColor : nil,
                    isActive: filter.status == .error,
                    action: { filter.status = filter.status == .error ? .all : .error }
                )
                GlanceTile(
                    value: "\(summary.privacyFilteredCount)",
                    label: L("Privacy-filtered"),
                    isActive: filter.privacyFilterApplied == true,
                    action: { filter.privacyFilterApplied = filter.privacyFilterApplied == true ? nil : true }
                )
            }

            if summary.totalCount > 0 {
                if summary.remoteCount > 0 {
                    splitBar
                    destinationsDisclosure
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.laptopcomputer")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Everything stayed on this Mac", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    private var splitBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.tertiaryText.opacity(0.35))
                    .frame(width: max(0, geo.size.width * (1 - summary.remoteShare) - 1))
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.accentColor.opacity(0.85))
                    .frame(width: max(0, geo.size.width * summary.remoteShare - 1))
            }
        }
        .frame(height: 5)
    }

    private var destinationsDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { showDestinations.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showDestinations ? 90 : 0))
                    Text(destinationsLine)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDestinations {
                VStack(spacing: 0) {
                    ForEach(summary.destinations.prefix(14)) { dest in
                        destinationRow(dest)
                        if dest.id != summary.destinations.prefix(14).last?.id {
                            Divider().background(theme.primaryBorder.opacity(0.15))
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.secondaryBackground.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.primaryBorder.opacity(0.25), lineWidth: 1))
                )
            }
        }
    }

    private var destinationsLine: String {
        let n = summary.destinations.count
        let dests = n == 1 ? L("1 destination") : String(format: L("%d destinations"), n)
        if summary.bytesSent > 0 {
            return "\(dests) · \(String(format: L("%@ sent"), ActivitySummary.formattedBytes(summary.bytesSent)))"
        }
        return dests
    }

    private func destinationRow(_ dest: ActivityDestinationSummary) -> some View {
        let isActive = !dest.host.isEmpty && filter.destinationHost == dest.host
        return Button(action: {
            guard !dest.host.isEmpty else { return }
            filter.destinationHost = isActive ? nil : dest.host
        }) {
            HStack(spacing: 10) {
                Image(systemName: dest.errorCount > 0 ? "exclamationmark.icloud" : "icloud")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(dest.errorCount > 0 ? theme.warningColor : theme.accentColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dest.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if !dest.host.isEmpty, dest.host != dest.label {
                        Text(dest.host)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(dest.count == 1 ? L("1 request") : String(format: L("%d requests"), dest.count))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                if dest.bytesSent > 0 {
                    Text(ActivitySummary.formattedBytes(dest.bytesSent))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 64, alignment: .trailing)
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dest.host.isEmpty ? dest.label : dest.host)
    }
}

private struct GlanceTile: View {
    @Environment(\.theme) private var theme
    let value: String
    var detail: String?
    let label: String
    var valueTint: Color?
    let isActive: Bool
    let action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { isHovering = $0 }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(valueTint ?? (isActive ? theme.accentColor : theme.primaryText))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? theme.accentColor.opacity(0.10) : theme.secondaryBackground.opacity(isHovering ? 0.8 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? theme.accentColor.opacity(0.5) : theme.primaryBorder.opacity(0.25), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

// MARK: - Toolbar

/// Search · time range · Filter (popover). Everything that used to be a
/// permanently visible colored segment now lives in the popover and shows
/// up as a removable token beneath the row while it is active.
private struct InsightsToolbar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var service: InsightsService
    @Binding var showFilterPopover: Bool

    private var filter: Binding<ActivityFilter> { $service.filter }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SearchField(
                    text: filter.text,
                    placeholder: "Search model, destination, path, agent…",
                    fillsAvailableWidth: true,
                    compact: true
                )

                timeRangeControl

                filterButton

                let count = service.totalRequestCount
                Text(count == 1 ? L("1 event") : String(format: L("%d events"), count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
            }

            let tokens = ActivityFilterToken.tokens(for: filter.wrappedValue).filter { $0.kind != .dateRange && $0.kind != .text }
            if !tokens.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tokens) { token in
                        FilterTokenChip(token: token) {
                            var f = filter.wrappedValue
                            token.remove(from: &f)
                            filter.wrappedValue = f
                        }
                    }
                    Button(action: { service.clearFilters() }) {
                        Text("Clear all", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var timeRangeControl: some View {
        HStack(spacing: 2) {
            ForEach(ActivityDateRange.presets, id: \.self) { range in
                let isSelected = filter.wrappedValue.dateRange == range
                Button(action: { filter.wrappedValue.dateRange = range }) {
                    Text(range.displayName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(isSelected ? .white : theme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? theme.accentColor.opacity(0.9) : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.tertiaryBackground))
        .fixedSize()
    }

    private var filterButton: some View {
        // Date range and search are visible in the row itself; the badge counts
        // only what is hidden behind the popover.
        let hidden = ActivityFilterToken.tokens(for: filter.wrappedValue).filter { $0.kind != .dateRange && $0.kind != .text }.count
        return Button(action: { showFilterPopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .semibold))
                Text("Filter", bundle: .module).font(.system(size: 11, weight: .medium))
                if hidden > 0 {
                    Text("\(hidden)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accentColor))
                }
            }
            .foregroundColor(hidden > 0 ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(hidden > 0 ? theme.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
            InsightsFilterPopover(service: service, onDone: { showFilterPopover = false })
                .environment(\.theme, theme)
        }
    }
}

private struct FilterTokenChip: View {
    @Environment(\.theme) private var theme
    let token: ActivityFilterToken
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(kindPrefix)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Text(token.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Remove this filter", bundle: .module))
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(theme.accentColor.opacity(0.10))
                .overlay(Capsule().stroke(theme.accentColor.opacity(0.35), lineWidth: 1))
        )
    }

    private var kindPrefix: String {
        switch token.kind {
        case .text: return L("Search")
        case .dateRange: return L("Time")
        case .locality: return L("Where")
        case .categories: return L("Kind")
        case .source: return L("Source")
        case .destination: return L("Destination")
        case .model: return L("Model")
        case .agent: return L("Agent")
        case .status: return L("Status")
        case .privacyFilter: return L("Privacy")
        case .pluginLogsHidden: return L("Logs")
        }
    }
}

// MARK: - Filter popover

private struct InsightsFilterPopover: View {
    @Environment(\.theme) private var theme
    @ObservedObject var service: InsightsService
    let onDone: () -> Void

    private var filter: Binding<ActivityFilter> { $service.filter }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Filter activity", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if filter.wrappedValue.activeCount > 0 {
                    Button(action: { service.clearFilters() }) {
                        Text("Reset", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            group(Text("Where", bundle: .module)) {
                choiceRow(
                    items: [nil, DataLocality.local, DataLocality.remote],
                    selected: { $0 == filter.wrappedValue.locality },
                    label: { $0?.displayName ?? L("Any") }
                ) { filter.wrappedValue.locality = $0 }
            }

            group(Text("Status", bundle: .module)) {
                choiceRow(
                    items: ActivityStatusFilter.allCases,
                    selected: { $0 == filter.wrappedValue.status },
                    label: { $0 == .all ? L("Any") : $0.displayName }
                ) { filter.wrappedValue.status = $0 }
            }

            group(Text("Source", bundle: .module)) {
                FlowLayout(spacing: 6) {
                    ForEach(RequestSource.allCases.filter { $0 != .system }, id: \.self) { source in
                        let isOn = filter.wrappedValue.sources.contains(source)
                        toggleChip(source.displayName, isOn: isOn) {
                            if isOn { filter.wrappedValue.sources.remove(source) } else { filter.wrappedValue.sources.insert(source) }
                        }
                    }
                }
            }

            if !service.knownDestinations.isEmpty || !service.knownModels.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    if !service.knownDestinations.isEmpty {
                        group(Text("Destination", bundle: .module)) {
                            pickerMenu(
                                current: filter.wrappedValue.destinationHost,
                                anyLabel: L("Any destination"),
                                options: service.knownDestinations
                            ) { filter.wrappedValue.destinationHost = $0 }
                        }
                    }
                    if !service.knownModels.isEmpty {
                        group(Text("Model", bundle: .module)) {
                            pickerMenu(
                                current: filter.wrappedValue.model,
                                anyLabel: L("Any model"),
                                options: service.knownModels
                            ) { filter.wrappedValue.model = $0 }
                        }
                    }
                }
            }

            group(Text("Privacy Filter", bundle: .module)) {
                choiceRow(
                    items: [nil, true, false],
                    selected: { $0 == filter.wrappedValue.privacyFilterApplied },
                    label: { v in v == nil ? L("Any") : (v == true ? L("Only filtered") : L("Only unfiltered")) }
                ) { filter.wrappedValue.privacyFilterApplied = $0 }
            }

            Toggle(isOn: filter.includePluginLogs) {
                Text("Show plugin console logs", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button(action: onDone) { Text("Done", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(theme.primaryBackground)
    }

    private func group<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceRow<T: Hashable>(
        items: [T],
        selected: @escaping (T) -> Bool,
        label: @escaping (T) -> String,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = selected(item)
                Button(action: { onSelect(item) }) {
                    Text(label(item))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .white : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? theme.accentColor.opacity(0.9) : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.tertiaryBackground))
    }

    private func toggleChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .white : theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? theme.accentColor.opacity(0.9) : theme.tertiaryBackground))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pickerMenu(
        current: String?,
        anyLabel: String,
        options: [String],
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        Menu {
            Button(anyLabel) { onSelect(nil) }
            Divider()
            ForEach(options, id: \.self) { option in
                Button(action: { onSelect(option) }) {
                    if current == option { Image(systemName: "checkmark") }
                    Text(option)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current ?? anyLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(current == nil ? theme.secondaryText : theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - Scope bar

/// Groups the fourteen categories into a handful of tabs. Writing a scope
/// replaces `filter.categories` wholesale; an ad-hoc category set (deep link)
/// leaves "All" lit and surfaces the categories as a removable token.
private struct InsightsScopeBar: View {
    @Binding var filter: ActivityFilter

    private var selection: Binding<InsightsScope> {
        Binding(
            get: { InsightsScope.scope(for: filter.categories) ?? .all },
            set: { filter.categories = $0.categories }
        )
    }

    var body: some View {
        AnimatedTabSelector(selection: selection)
    }
}

// MARK: - Row

/// Column widths shared by the table header and every row.
private struct ActivityTableColumns {
    let status: CGFloat = 14
    let time: CGFloat = 64
    let source: CGFloat
    let duration: CGFloat = 64

    init(compact: Bool) {
        source = compact ? 0 : 84
    }
}

private struct ActivityRow: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    var compact: Bool = false
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        let columns = ActivityTableColumns(compact: compact)
        Button(action: onTap) {
            HStack(spacing: 0) {
                statusDot
                    .frame(width: columns.status, alignment: .leading)

                Text(log.formattedTimestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: columns.time, alignment: .leading)

                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(log.category.tint.opacity(0.14))
                        Image(systemName: log.category.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(log.category.tint.opacity(0.9))
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.title)
                            .font(.system(size: 12, weight: .medium, design: usesMonospacedTitle ? .monospaced : .default))
                            .foregroundColor(log.isError ? theme.errorColor : (log.isPluginLog ? pluginLevelColor : theme.primaryText))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        secondaryLine
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)

                if !compact {
                    Text(log.source.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .frame(width: columns.source, alignment: .leading)
                }

                Text(log.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: columns.duration, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(theme.accentColor).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return theme.accentColor.opacity(0.12) }
        if isHovering { return theme.secondaryBackground.opacity(0.4) }
        return .clear
    }

    @ViewBuilder
    private var statusDot: some View {
        if log.isError {
            Circle().fill(theme.errorColor).frame(width: 6, height: 6)
                .help(Text(verbatim: log.errorMessage ?? "\(log.statusCode)"))
        } else if log.statusCode >= 400, !log.isPluginLog {
            Circle().fill(theme.warningColor).frame(width: 6, height: 6)
                .help(Text(verbatim: "\(log.statusCode)"))
        } else {
            Color.clear.frame(width: 6, height: 6)
        }
    }

    private var secondaryLine: some View {
        HStack(spacing: 4) {
            Text(secondaryText)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if log.egress?.privacyFilterApplied == true {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.successColor.opacity(0.9))
                    .help(Text("Privacy Filter rewrote spans before send", bundle: .module))
            }
        }
    }

    /// `Category · Agent · Destination · N tools` — only the parts that exist.
    private var secondaryText: String {
        var parts: [String] = [log.category.displayName]
        if let plugin = log.pluginId { parts.append(plugin) }
        if let agent = log.agentName { parts.append(agent) }
        if log.locality == .remote { parts.append(log.destinationDisplay) }
        if let tools = log.toolDefinitionCount, tools > 0 {
            parts.append(tools == 1 ? L("1 tool") : String(format: L("%d tools"), tools))
        }
        return parts.joined(separator: " · ")
    }

    private var usesMonospacedTitle: Bool {
        switch log.category {
        case .inboundAPI, .routerControl, .mcpToolCall, .pluginCall, .urlExtract: return true
        default: return false
        }
    }

    private var pluginLevelColor: Color {
        switch log.statusCode {
        case 500: return theme.errorColor
        case 299: return theme.warningColor
        default: return theme.primaryText
        }
    }
}

// MARK: - Inline notice

private struct InlineNotice: View {
    @Environment(\.theme) private var theme
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint)
            Text(text).font(.system(size: 12)).foregroundColor(theme.primaryText)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Export sheet

private struct ActivityExportSheet: View {
    @Environment(\.theme) private var theme

    let filter: ActivityFilter
    let filteredCount: Int
    let onExport: (ActivityExportOptions) -> Void
    let onCancel: () -> Void

    @State private var options = ActivityExportOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Activity Log", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Choose a format for outside review. Every export includes a manifest with the chain position so a reviewer can verify it offline.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Format", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.tertiaryText)
                ForEach(ActivityExportFormat.allCases) { format in
                    Button(action: { options.format = format }) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: options.format == format ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(options.format == format ? theme.accentColor : theme.tertiaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.displayName).font(.system(size: 12, weight: .medium)).foregroundColor(theme.primaryText)
                                Text(format.summary).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Scope", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.tertiaryText)
                Toggle(isOn: $options.filteredOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filter.isEmpty
                            ? L("Current view (all records)")
                            : String(format: L("Current view only (%d records)"), filteredCount))
                            .font(.system(size: 12)).foregroundColor(theme.primaryText)
                        if !filter.isEmpty {
                            Text(ActivityExportService.describe(filter)).font(.system(size: 10)).foregroundColor(theme.tertiaryText)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(filter.isEmpty)
                Toggle(isOn: $options.includeContent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include message content", bundle: .module).font(.system(size: 12)).foregroundColor(theme.primaryText)
                        Text("Off: prompts, responses and tool arguments are replaced with a marker. Destinations, sizes and tool names are kept.", bundle: .module)
                            .font(.system(size: 10)).foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button(action: onCancel) { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                Button(action: { onExport(options) }) { Text("Export…", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(theme.primaryBackground)
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        InsightsView().frame(width: 1000, height: 700)
    }
#endif
