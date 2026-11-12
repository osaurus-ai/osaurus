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
        VStack(spacing: theme.space.s0) {
            headerView
                .settingsHeaderEntrance(hasAppeared: hasAppeared)

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
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(theme.motion.standard.delay(0.05)) { hasAppeared = true }
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
        VStack(spacing: theme.space.s0) {
            chrome
            HStack(spacing: theme.space.s0) {
                eventList(compact: selectedLog != nil, presentation: .inspector)
                    .frame(maxWidth: .infinity)
                if let selected = selectedLog {
                    Divider().background(theme.border.subtle)
                    InsightsDetailPane(log: selected, presentation: .inspector, onBack: pop)
                        .frame(width: Self.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(theme.motion.standard, value: selectedLog?.id)
        }
    }

    /// Narrow: a selected row replaces the whole page; Back returns.
    private var pushLayout: some View {
        ZStack {
            if let selected = selectedLog {
                InsightsDetailPane(log: selected, presentation: .page, onBack: pop)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            } else {
                VStack(spacing: theme.space.s0) {
                    chrome
                    eventList(compact: false, presentation: .page)
                }
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            }
        }
        .animation(theme.motion.standard, value: selectedLog == nil)
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Insights",
            subtitle: "Activity and audit log for everything this Mac ran or sent",
            count: insightsService.totalRequestCount,
            overflowHelp: "Export, verify, or clear the log",
            overflow: {
                Button(action: { showExportSheet = true }) {
                    Label(L("Export"), systemImage: "square.and.arrow.up")
                }
                .disabled(!insightsService.hasLogs)
                Button(action: { insightsService.verify() }) {
                    Label(L("Verify Integrity"), systemImage: "checkmark.shield")
                }
                .disabled(!insightsService.hasLogs || insightsService.isVerifying || insightsService.activityStore == nil)
                Divider()
                Button(role: .destructive, action: { showClearConfirmation = true }) {
                    Label(L("Clear Activity Log…"), systemImage: "trash")
                }
                .disabled(!insightsService.hasLogs)
            },
            toolbar: {
                InsightsToolbar(service: insightsService, showFilterPopover: $showFilterPopover)
            }
        )
    }

    // MARK: - Chrome (glance · toolbar · scopes)

    private var chrome: some View {
        VStack(alignment: .leading, spacing: theme.settingsInlineGap) {
            if let error = insightsService.storeError {
                InlineBanner(
                    kind: .warning,
                    title: String(format: L("Activity log storage is unavailable (%@). Showing this session only."), error)
                )
            }
            if showVerification, let v = insightsService.lastVerification {
                verificationBanner(v)
            }
            InsightsGlanceStrip(summary: insightsService.summary, filter: $insightsService.filter)
        }
        .padding(.horizontal, theme.settingsPageInset)
        .padding(.bottom, theme.settingsInlineGap)
    }

    private func verificationBanner(_ v: ActivityLogVerification) -> some View {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        var details: [String] = []
        if let first = v.firstSeq, let last = v.lastSeq, let hash = v.lastHash {
            details.append("#\(first) – #\(last) · \(String(hash.prefix(16)))… · \(df.string(from: v.checkedAt))")
        }
        details += v.problems.prefix(8).map { "• " + $0.description }
        return InlineBanner(
            kind: v.isIntact ? .success : .error,
            title: v.isIntact
                ? String(format: L("Integrity verified: %d records, chain intact"), v.recordCount)
                : String(format: L("Integrity problems found in %d records"), v.recordCount),
            caption: details.isEmpty ? nil : details.joined(separator: "\n"),
            icon: v.isIntact ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
            onDismiss: { withAnimation { showVerification = false } }
        )
    }

    // MARK: - Event list

    private func eventList(compact: Bool, presentation: InsightsDetailPresentation) -> some View {
        VStack(spacing: theme.space.s0) {
            if !insightsService.pagedLogs.isEmpty {
                tableHeader(compact: compact)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: theme.space.s0, pinnedViews: [.sectionHeaders]) {
                        if insightsService.pagedLogs.isEmpty {
                            emptyStateView
                                .frame(maxWidth: .infinity)
                                .padding(.top, theme.space.s40)
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
                    .padding(.bottom, theme.space.s24)
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
                    withAnimation(theme.motion.quick) { proxy.scrollTo(id, anchor: nil) }
                }
            }
        }
    }

    private func tableHeader(compact: Bool) -> some View {
        let columns = ActivityTableColumns(compact: compact, fontScale: theme.fontScale)
        return HStack(spacing: theme.space.s0) {
            Spacer().frame(width: columns.status)
            Text("TIME", bundle: .module).frame(width: columns.time, alignment: .leading)
            Text("EVENT", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text("SOURCE", bundle: .module).frame(width: columns.source, alignment: .leading)
            }
            Text("DURATION", bundle: .module).frame(width: columns.duration, alignment: .trailing)
        }
        .font(SettingsFont.chip)
        .foregroundColor(theme.text.tertiary)
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s8)
        .overlay(alignment: .bottom) { Divider().background(theme.border.subtle) }
    }

    private func dayHeader(_ key: String, count: Int) -> some View {
        HStack(spacing: theme.space.s8) {
            Text(Self.dayLabel(key))
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            Text(count == 1 ? L("1 event") : String(format: L("%d events"), count))
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
            Spacer()
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.top, theme.space.s12)
        .padding(.bottom, theme.space.s6)
        .background(theme.surface.canvas)
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if insightsService.isLoading {
                SettingsSpinner()
            } else {
                Button(action: { insightsService.loadMore() }) {
                    Text(
                        String(
                            format: L("Load more (%d of %d)"),
                            insightsService.pagedLogs.count,
                            insightsService.totalRequestCount
                        )
                    )
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.link)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, theme.space.s16)
        .onAppear { insightsService.loadMore() }
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        let filtered = !insightsService.filter.isEmpty
        return SettingsEmptyState(
            inline: filtered ? "line.3.horizontal.decrease.circle" : "list.bullet.clipboard",
            title: filtered ? "Nothing Matches These Filters" : "No Activity Yet",
            hint: filtered
                ? "Try widening the time range or clearing a filter."
                : "Chats, cloud requests, web searches, tool calls and API traffic will appear here as they happen.",
            secondaryAction: filtered
                ? .init(title: L("Clear filters"), icon: "", handler: { insightsService.clearFilters() }) : nil
        )
    }

    // MARK: - Selection / navigation

    private func pop() {
        withAnimation(theme.motion.standard) { selectedLog = nil }
    }

    private func select(_ log: RequestLog) {
        withAnimation(theme.motion.standard) { selectedLog = log }
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
    /// Hue used only for the row glyph and the detail header glyph.
    var ink: DataInk {
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
        case .embedding: return .teal
        case .audioTranscription: return .green
        case .speechSynthesis: return .orange
        case .mediaGeneration: return .pink
        case .workflowRun, .workflowNode: return .indigo
        case .event: return .orange
        case .task: return .orange
        case .system: return .gray
        case .interaction: return .orange
        }
    }
}

// MARK: - Glance strip

/// Four stat tiles that double as one-tap filters, so the headline numbers
/// answer "did anything leave, did anything fail, was anything redacted"
/// and jump straight to those rows. Events clears the filter.
private struct InsightsGlanceStrip: View {
    @Environment(\.theme) private var theme
    let summary: ActivitySummary
    @Binding var filter: ActivityFilter

    @State private var showDestinations = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsInlineGap) {
            SettingsStatStrip(
                stats: [
                    SettingsStat(label: "Events", value: "\(summary.totalCount)"),
                    SettingsStat(label: "Left this Mac", value: remoteValue),
                    SettingsStat(
                        label: "Failed",
                        value: "\(summary.errorCount)",
                        valueTint: summary.errorCount > 0 ? theme.status.error.foreground : nil
                    ),
                    SettingsStat(label: "Privacy-filtered", value: "\(summary.privacyFilteredCount)"),
                ],
                style: .tiles(columns: 4),
                selection: Binding(get: { glanceSelection }, set: { selectGlance($0) })
            )

            if summary.totalCount > 0 {
                if summary.remoteCount > 0 {
                    splitBar
                    destinationsDisclosure
                } else {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "lock.laptopcomputer")
                            .glyphSize(.micro, weight: .semibold)
                        Text("Everything stayed on this Mac", bundle: .module)
                            .font(SettingsFont.smallLabel)
                    }
                    .foregroundColor(theme.text.tertiary)
                }
            }
        }
    }

    private var remoteValue: String {
        guard summary.totalCount > 0, summary.remoteCount > 0 else { return "\(summary.remoteCount)" }
        return String(format: "%d · %.0f%%", summary.remoteCount, summary.remoteShare * 100)
    }

    /// The tile matching the one active quick filter; Events when none is on,
    /// nil when the Filter popover has combined several.
    private var glanceSelection: String? {
        var active: [String] = []
        if filter.locality == .remote { active.append("Left this Mac") }
        if filter.status == .error { active.append("Failed") }
        if filter.privacyFilterApplied == true { active.append("Privacy-filtered") }
        if active.isEmpty { return "Events" }
        return active.count == 1 ? active[0] : nil
    }

    /// One quick filter at a time; Events (or deselecting) clears them.
    private func selectGlance(_ id: String?) {
        if filter.locality == .remote { filter.locality = nil }
        if filter.status == .error { filter.status = .all }
        if filter.privacyFilterApplied == true { filter.privacyFilterApplied = nil }
        switch id {
        case "Left this Mac": filter.locality = .remote
        case "Failed": filter.status = .error
        case "Privacy-filtered": filter.privacyFilterApplied = true
        default: break
        }
    }

    private var splitBar: some View {
        GeometryReader { geo in
            HStack(spacing: theme.space.s2) {
                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(theme.border.strong)
                    .frame(width: max(0, geo.size.width * (1 - summary.remoteShare) - 1))
                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(theme.status.info.foreground)
                    .frame(width: max(0, geo.size.width * summary.remoteShare - 1))
            }
        }
        .frame(height: 5)
    }

    private var destinationsDisclosure: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Button(action: { withAnimation(theme.motion.quick) { showDestinations.toggle() } }) {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "chevron.right")
                        .glyphSize(.tiny, weight: .semibold)
                        .rotationEffect(.degrees(showDestinations ? 90 : 0))
                    Text(destinationsLine)
                        .font(SettingsFont.smallLabel)
                    Spacer()
                }
                .foregroundColor(theme.text.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDestinations {
                VStack(spacing: theme.space.s0) {
                    ForEach(summary.destinations.prefix(14)) { dest in
                        destinationRow(dest)
                        if dest.id != summary.destinations.prefix(14).last?.id {
                            Divider().background(theme.border.subtle)
                        }
                    }
                }
                .settingsChrome(.surface)
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
            HStack(spacing: theme.space.s10) {
                Image(systemName: dest.errorCount > 0 ? "exclamationmark.icloud" : "icloud")
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(dest.errorCount > 0 ? theme.status.warning.foreground : theme.text.link)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(dest.label)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if !dest.host.isEmpty, dest.host != dest.label {
                        Text(dest.host)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(dest.count == 1 ? L("1 request") : String(format: L("%d requests"), dest.count))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                if dest.bytesSent > 0 {
                    Text(ActivitySummary.formattedBytes(dest.bytesSent))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .frame(width: 64, alignment: .trailing)
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(theme.text.link)
                }
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dest.host.isEmpty ? dest.label : dest.host)
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

    private var scope: Binding<InsightsScope> {
        Binding(
            get: { InsightsScope.scope(for: service.filter.categories) ?? .all },
            set: { service.filter.categories = $0.categories }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsControlGap) {
            SettingsTabsRow(
                selection: scope,
                searchText: filter.text,
                searchPlaceholder: "Search model, destination, path, agent…"
            ) {
                timeRangeControl
                filterButton
            }

            let tokens = ActivityFilterToken.tokens(for: filter.wrappedValue).filter { $0.kind != .dateRange && $0.kind != .text }
            if !tokens.isEmpty {
                FlowLayout(spacing: theme.space.s6) {
                    ForEach(tokens) { token in
                        InsightsFilterToken(token: token) {
                            var f = filter.wrappedValue
                            token.remove(from: &f)
                            filter.wrappedValue = f
                        }
                    }
                    Button(action: { service.clearFilters() }) {
                        Text("Clear all", bundle: .module)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.text.link)
                            .padding(.horizontal, theme.space.s6)
                            .padding(.vertical, theme.space.s4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var timeRangeControl: some View {
        AssignedBaseSegmentedPicker(
            selection: filter.dateRange,
            options: ActivityDateRange.presets.map { .init($0, $0.displayName, verbatim: true) },
            size: .compact
        )
        .fixedSize()
    }

    private var filterButton: some View {
        // Date range and search are visible in the row itself; the badge counts
        // only what is hidden behind the popover.
        let hidden = ActivityFilterToken.tokens(for: filter.wrappedValue).filter { $0.kind != .dateRange && $0.kind != .text }.count
        return Button(action: { showFilterPopover.toggle() }) {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "line.3.horizontal.decrease").glyphSize(.micro, weight: .semibold)
                Text("Filter", bundle: .module).font(SettingsFont.smallLabel)
                if hidden > 0 {
                    CountBadge(hidden, prominence: .attention)
                }
            }
            .foregroundColor(hidden > 0 ? theme.text.link : theme.text.secondary)
            .padding(.horizontal, theme.space.s8)
            .frame(minHeight: theme.controlSize.defaultHeight)
            .settingsChrome(.subtle)
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
            InsightsFilterPopover(service: service, onDone: { showFilterPopover = false })
                .environment(\.theme, theme)
        }
    }
}

private struct InsightsFilterToken: View {
    let token: ActivityFilterToken
    let onRemove: () -> Void

    var body: some View {
        FilterTokenChip(prefix: kindPrefix, token.label, onRemove: onRemove)
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
        case .workflowRun: return L("Workflow")
        case .task: return L("Task")
        case .participant: return L("Who")
        case .agentAddress: return L("Agent")
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
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack {
                Text("Filter activity", bundle: .module)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if filter.wrappedValue.activeCount > 0 {
                    Button(action: { service.clearFilters() }) {
                        Text("Reset", bundle: .module)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.text.link)
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
                FlowLayout(spacing: theme.space.s6) {
                    ForEach(RequestSource.allCases.filter { $0 != .system }, id: \.self) { source in
                        let isOn = filter.wrappedValue.sources.contains(source)
                        toggleChip(source.displayName, isOn: isOn) {
                            if isOn { filter.wrappedValue.sources.remove(source) } else { filter.wrappedValue.sources.insert(source) }
                        }
                    }
                }
            }

            if !service.knownDestinations.isEmpty || !service.knownModels.isEmpty {
                HStack(alignment: .top, spacing: theme.space.s12) {
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
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
            }
            .settingsCheckbox()

            HStack {
                Spacer()
                Button(action: onDone) { Text("Done", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.space.s16)
        .frame(width: 360)
        .background(theme.surface.canvas)
    }

    private func group<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            title
                .textStyle(.micro, weight: 600)
                .foregroundColor(theme.text.tertiary)
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
        AssignedBaseSegmentedPicker(
            selection: Binding(get: { items.first(where: selected) ?? items[0] }, set: onSelect),
            options: items.map { .init($0, label($0), verbatim: true) },
            size: .compact
        )
    }

    private func toggleChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        FilterChip(title, isSelected: isOn, action: action)
    }

    private func pickerMenu(
        current: String?,
        anyLabel: String,
        options: [String],
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        SettingsMenuPicker(selection: Binding(get: { current }, set: onSelect)) {
            Text(anyLabel).tag(String?.none)
            Divider()
            ForEach(options, id: \.self) { option in
                Text(option).tag(String?.some(option))
            }
        }
    }
}

// MARK: - Scope bar

/// Groups the fourteen categories into a handful of tabs. Writing a scope
/// replaces `filter.categories` wholesale; an ad-hoc category set (deep link)
/// leaves "All" lit and surfaces the categories as a removable token.
// MARK: - Row

/// Column widths shared by the table header and every row.
/// Text columns grow with the Text Size setting so a timestamp or header
/// never wraps mid-word.
private struct ActivityTableColumns {
    let status: CGFloat = 14
    let time: CGFloat
    let source: CGFloat
    let duration: CGFloat

    init(compact: Bool, fontScale: Double) {
        let scale = CGFloat(fontScale)
        time = 64 * scale
        source = compact ? 0 : 84 * scale
        duration = 64 * scale
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
        let columns = ActivityTableColumns(compact: compact, fontScale: theme.fontScale)
        Button(action: onTap) {
            HStack(spacing: theme.space.s0) {
                statusDot
                    .frame(width: columns.status, alignment: .leading)

                Text(log.formattedTimestamp)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .frame(width: columns.time, alignment: .leading)

                HStack(spacing: theme.space.s10) {
                    ZStack {
                        Circle().fill(theme.dataWash(log.category.ink))
                        Image(systemName: log.category.icon)
                            .glyphSize(.footnote, weight: .semibold)
                            .foregroundColor(theme.dataInk(log.category.ink))
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text(log.title)
                            .textStyle(usesMonospacedTitle ? .code : .caption, weight: 500)
                            .foregroundColor(
                                log.isError
                                    ? theme.status.error.foreground
                                    : (log.isPluginLog ? pluginLevelColor : theme.text.primary)
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                        secondaryLine
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, theme.space.s12)

                if !compact {
                    Text(log.source.displayName)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                        .frame(width: columns.source, alignment: .leading)
                }

                Text(log.formattedDuration)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .frame(width: columns.duration, alignment: .trailing)
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s8)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(theme.action.primary.default.background).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return theme.surface.selected }
        if isHovering { return theme.surface.hover }
        return .clear
    }

    @ViewBuilder
    private var statusDot: some View {
        if log.isError {
            Circle().fill(theme.status.error.foreground).frame(width: 6, height: 6)
                .help(Text(verbatim: log.errorMessage ?? "\(log.statusCode)"))
        } else if log.statusCode >= 400, !log.isPluginLog, log.category != .interaction {
            Circle().fill(theme.status.warning.foreground).frame(width: 6, height: 6)
                .help(Text(verbatim: "\(log.statusCode)"))
        } else {
            Color.clear.frame(width: 6, height: 6)
        }
    }

    private var secondaryLine: some View {
        HStack(spacing: theme.space.s4) {
            Text(secondaryText)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if log.egress?.privacyFilterApplied == true {
                Image(systemName: "hand.raised.fill")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundColor(theme.status.success.foreground)
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
        case 500: return theme.status.error.foreground
        case 299: return theme.status.warning.foreground
        default: return theme.text.primary
        }
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
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text("Export Activity Log", bundle: .module)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                Text(
                    "Choose a format for outside review. Every export includes a manifest with the chain position so a reviewer can verify it offline.",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text("Format", bundle: .module).font(SettingsFont.smallLabel).foregroundColor(theme.text.tertiary)
                ForEach(ActivityExportFormat.allCases) { format in
                    Button(action: { options.format = format }) {
                        HStack(alignment: .top, spacing: theme.space.s10) {
                            Image(systemName: options.format == format ? "largecircle.fill.circle" : "circle")
                                .glyphSize(.label)
                                .foregroundColor(options.format == format ? theme.text.link : theme.text.tertiary)
                            SettingsRowText(compact: true) {
                                Text(format.displayName)
                            } description: {
                                Text(format.summary).foregroundColor(theme.text.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text("Scope", bundle: .module).font(SettingsFont.smallLabel).foregroundColor(theme.text.tertiary)
                Toggle(isOn: $options.filteredOnly) {
                    SettingsRowText(compact: true) {
                        Text(
                            filter.isEmpty
                                ? L("Current view (all records)")
                                : String(format: L("Current view only (%d records)"), filteredCount)
                        )
                    } description: {
                        if !filter.isEmpty {
                            Text(ActivityExportService.describe(filter))
                        }
                    }
                }
                .settingsCheckbox()
                .disabled(filter.isEmpty)
                Toggle(isOn: $options.includeContent) {
                    SettingsRowText(compact: true) {
                        Text("Include message content", bundle: .module)
                    } description: {
                        Text(
                            "Off: prompts, responses and tool arguments are replaced with a marker. Destinations, sizes and tool names are kept.",
                            bundle: .module
                        )
                    }
                }
                .settingsCheckbox()
            }

            HStack {
                Spacer()
                Button(action: onCancel) { Text("Cancel", bundle: .module) }
                    .assignedSettingsButtonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(action: { onExport(options) }) { Text("Export…", bundle: .module) }
                    .assignedSettingsButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.space.s24)
        .frame(width: 460)
        .background(theme.surface.canvas)
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        InsightsView().frame(width: 1000, height: 700)
    }
#endif
