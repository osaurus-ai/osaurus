//
//  InsightsView.swift
//  osaurus
//
//  Activity / audit dashboard. Every interaction this Mac ran or sent —
//  local inference, cloud inference, web searches, URL fetches, MCP
//  calls, channel deliveries, Router calls, inbound API traffic and
//  plugin activity — is a row. The top card summarises what left the
//  device; the filter bar narrows by time, locality, kind, destination,
//  model, agent and outcome; Verify checks the hash chain; Export writes
//  JSONL / CSV / Markdown for outside review.
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

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ZStack {
                if let selected = selectedLog {
                    InsightsDetailPane(log: selected, onBack: pop)
                        .transition(
                            .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
                        )
                } else {
                    listContent
                        .transition(
                            .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: selectedLog == nil)
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

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Insights"),
            subtitle: L("Activity and audit log for everything this Mac ran or sent")
        ) {
            HeaderSecondaryButton(L("Verify"), icon: "checkmark.shield") {
                insightsService.verify()
            }
            .disabled(!insightsService.hasLogs || insightsService.isVerifying || insightsService.activityStore == nil)
            .opacity(insightsService.hasLogs && insightsService.activityStore != nil ? 1 : 0.5)

            HeaderSecondaryButton(L("Export"), icon: "square.and.arrow.up") {
                showExportSheet = true
            }
            .disabled(!insightsService.hasLogs)
            .opacity(insightsService.hasLogs ? 1 : 0.5)

            HeaderSecondaryButton(L("Clear"), icon: "trash") {
                showClearConfirmation = true
            }
            .disabled(!insightsService.hasLogs)
            .opacity(insightsService.hasLogs ? 1 : 0.5)
        }
    }

    // MARK: - List

    /// Below this content width the table drops the SIZE column and narrows
    /// WHERE/KIND so the WHAT column keeps room to breathe. The management
    /// window's design minimum (940pt) with the sidebar open lands here.
    private static let compactTableWidth: CGFloat = 820

    private var listContent: some View {
        GeometryReader { geo in
            listScroll(compact: geo.size.width < Self.compactTableWidth)
        }
    }

    private func listScroll(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    VStack(spacing: 14) {
                        if let error = insightsService.storeError {
                            noticeBanner(
                                icon: "exclamationmark.triangle.fill",
                                tint: .orange,
                                text: String(format: L("Activity log storage is unavailable (%@). Showing this session only."), error)
                            )
                        }
                        if showVerification, let v = insightsService.lastVerification {
                            verificationBanner(v)
                        }
                        ActivityFilterBar(service: insightsService)
                        EgressSummaryCard(summary: insightsService.summary, filter: $insightsService.filter)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    if insightsService.pagedLogs.isEmpty {
                        emptyStateView
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        tableHeader(compact: compact)
                        groupedRows(compact: compact)
                        if insightsService.canLoadMore {
                            loadMoreRow
                        }
                    }
                }
            }
        }
    }

    private func tableHeader(compact: Bool) -> some View {
        let columns = ActivityTableColumns(compact: compact)
        return HStack(spacing: 0) {
            Text("TIME", bundle: .module).frame(width: columns.time, alignment: .leading)
            Text("WHERE", bundle: .module).frame(width: columns.locality, alignment: .leading)
            Text("KIND", bundle: .module).frame(width: columns.kind, alignment: .leading)
            Text("WHAT", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
            Text("SOURCE", bundle: .module).frame(width: columns.source, alignment: .leading)
            Text("STATUS", bundle: .module).frame(width: columns.status, alignment: .center)
            if !compact {
                Text("SIZE", bundle: .module).frame(width: columns.size, alignment: .trailing)
            }
            Text("TIME", bundle: .module).frame(width: columns.duration, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(theme.tertiaryText.opacity(0.7))
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(theme.primaryBackground)
        .overlay(alignment: .bottom) { Divider().background(theme.primaryBorder.opacity(0.3)) }
    }

    private func groupedRows(compact: Bool) -> some View {
        let groups = Self.groupByDay(insightsService.pagedLogs)
        return ForEach(groups, id: \.key) { group in
            dayHeader(group.key, count: group.rows.count)
            ForEach(group.rows) { log in
                ActivityRow(log: log, compact: compact, isSelected: selectedLog?.id == log.id, onTap: { push(log) })
                if log.id != group.rows.last?.id {
                    Divider().background(theme.primaryBorder.opacity(0.15)).padding(.horizontal, 24)
                }
            }
        }
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
        .padding(.top, 14)
        .padding(.bottom, 6)
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

    // MARK: - Banners

    private func noticeBanner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint)
            Text(text).font(.system(size: 12)).foregroundColor(theme.primaryText)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.25), lineWidth: 1))
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

    // MARK: - Navigation

    private func pop() {
        withAnimation(.easeInOut(duration: 0.25)) { selectedLog = nil }
    }

    private func push(_ log: RequestLog) {
        withAnimation(.easeInOut(duration: 0.25)) { selectedLog = log }
    }

    private func applyPendingFocus(_ logId: UUID?) {
        guard let logId else { return }
        defer { insightsService.pendingFocusLogId = nil }
        guard let log = insightsService.log(id: logId) else { return }
        push(log)
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

// MARK: - Egress summary card

private struct EgressSummaryCard: View {
    @Environment(\.theme) private var theme
    let summary: ActivitySummary
    @Binding var filter: ActivityFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("What left this Mac", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text(rangeLabel)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            // Pills keep their natural width and wrap onto a second line when the
            // window is narrow, so labels never break mid-word.
            FlowLayout(spacing: 22) {
                StatPill(icon: "icloud.and.arrow.up", value: "\(summary.remoteCount)", label: L("Cloud requests"), color: .blue)
                StatPill(icon: "building.2", value: "\(summary.destinations.count)", label: L("Destinations"), color: .indigo)
                StatPill(icon: "arrow.up.doc", value: ActivitySummary.formattedBytes(summary.bytesSent), label: L("Bytes sent"), color: .cyan)
                StatPill(icon: "magnifyingglass", value: "\(summary.searchCount + summary.extractCount)", label: L("Searches & fetches"), color: .teal)
                StatPill(icon: "hand.raised.fill", value: "\(summary.privacyFilteredCount)", label: L("Privacy-filtered"), color: .green)
                StatPill(icon: "internaldrive", value: "\(summary.localCount)", label: L("Stayed local"), color: .gray)
                StatPill(
                    icon: "exclamationmark.triangle.fill",
                    value: "\(summary.errorCount)",
                    label: L("Failed"),
                    color: summary.errorCount > 0 ? .red : Color.gray.opacity(0.5)
                )
            }

            // Local / cloud split
            if summary.totalCount > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.45))
                            .frame(width: max(0, geo.size.width * (1 - summary.remoteShare) - 1))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.8))
                            .frame(width: max(0, geo.size.width * summary.remoteShare - 1))
                    }
                }
                .frame(height: 6)
                HStack(spacing: 14) {
                    legend(color: Color.gray.opacity(0.6), text: String(format: L("%d local"), summary.localCount))
                    legend(color: .blue, text: String(format: L("%d cloud (%.0f%%)"), summary.remoteCount, summary.remoteShare * 100))
                    if summary.inferenceCount > 0 {
                        legend(color: .purple, text: String(format: L("%d inferences · %@"), summary.inferenceCount, summary.formattedAvgSpeed))
                    }
                    Spacer()
                }
            }

            if !summary.destinations.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(summary.destinations.prefix(14)) { dest in
                        destinationChip(dest)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1))
        )
    }

    private var rangeLabel: String {
        guard let earliest = summary.earliest, let latest = summary.latest else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        if Calendar.current.isDate(earliest, inSameDayAs: latest) {
            let t = DateFormatter()
            t.timeStyle = .short
            return "\(f.string(from: earliest)) – \(t.string(from: latest))"
        }
        return "\(f.string(from: earliest)) – \(f.string(from: latest))"
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(theme.secondaryText)
        }
    }

    private func destinationChip(_ dest: ActivityDestinationSummary) -> some View {
        let isActive = !dest.host.isEmpty && filter.destinationHost == dest.host
        return Button(action: {
            guard !dest.host.isEmpty else { return }
            filter.destinationHost = isActive ? nil : dest.host
        }) {
            HStack(spacing: 5) {
                Image(systemName: dest.errorCount > 0 ? "exclamationmark.icloud" : "icloud")
                    .font(.system(size: 9, weight: .semibold))
                Text(dest.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("\(dest.count)").font(.system(size: 10, weight: .bold, design: .monospaced))
                if dest.bytesSent > 0 {
                    Text("· \(ActivitySummary.formattedBytes(dest.bytesSent))")
                        .font(.system(size: 10)).opacity(0.8)
                }
            }
            .foregroundColor(isActive ? .white : Color.blue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(isActive ? Color.blue.opacity(0.85) : Color.blue.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(dest.host.isEmpty ? dest.label : dest.host)
    }
}

// MARK: - Filter bar

private struct ActivityFilterBar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var service: InsightsService

    private var filter: Binding<ActivityFilter> { $service.filter }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Wraps onto a second line in a narrow window instead of
                // clipping the search field / status segments.
                FlowLayout(spacing: 10) {
                    SearchField(
                        text: filter.text,
                        placeholder: "Search model, destination, path, agent…",
                        width: 260,
                        compact: true
                    )

                    segmented(
                        items: ActivityDateRange.presets,
                        selected: { $0 == filter.wrappedValue.dateRange },
                        label: { $0.displayName },
                        tint: .orange
                    ) { filter.wrappedValue.dateRange = $0 }

                    segmented(
                        items: [nil, DataLocality.local, DataLocality.remote],
                        selected: { $0 == filter.wrappedValue.locality },
                        label: { $0?.displayName ?? L("All") },
                        tint: .blue
                    ) { filter.wrappedValue.locality = $0 }

                    segmented(
                        items: ActivityStatusFilter.allCases,
                        selected: { $0 == filter.wrappedValue.status },
                        label: { $0 == .all ? L("Any") : $0.displayName },
                        tint: .red
                    ) { filter.wrappedValue.status = $0 }
                }

                Spacer(minLength: 8)

                let count = service.totalRequestCount
                Text(count == 1 ? L("1 event") : String(format: L("%d events"), count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                FlowLayout(spacing: 6) {
                    ForEach(ActivityCategory.allCases.filter { $0 != .system }, id: \.self) { category in
                        categoryChip(category)
                    }
                }
                Spacer(minLength: 8)
                moreMenu
                if filter.wrappedValue.activeCount > 0 {
                    Button(action: { service.clearFilters() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            Text(String(format: L("Clear filters (%d)"), filter.wrappedValue.activeCount))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func segmented<T: Hashable>(
        items: [T],
        selected: @escaping (T) -> Bool,
        label: @escaping (T) -> String,
        tint: Color,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = selected(item)
                Button(action: { onSelect(item) }) {
                    Text(label(item))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(isSelected ? .white : theme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? tint.opacity(0.8) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.5)))
        .fixedSize()
    }

    private func categoryChip(_ category: ActivityCategory) -> some View {
        let isOn = filter.wrappedValue.categories.contains(category)
        return Button(action: {
            if isOn { filter.wrappedValue.categories.remove(category) } else { filter.wrappedValue.categories.insert(category) }
        }) {
            HStack(spacing: 4) {
                Image(systemName: category.icon).font(.system(size: 9, weight: .semibold))
                Text(category.displayName).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isOn ? .white : theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(isOn ? theme.accentColor.opacity(0.85) : theme.tertiaryBackground.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private var moreMenu: some View {
        Menu {
            Menu(L("Source")) {
                ForEach(RequestSource.allCases.filter { $0 != .system }, id: \.self) { source in
                    Toggle(isOn: Binding(
                        get: { filter.wrappedValue.sources.contains(source) },
                        set: { on in
                            if on { filter.wrappedValue.sources.insert(source) } else { filter.wrappedValue.sources.remove(source) }
                        }
                    )) { Text(source.displayName) }
                }
            }
            if !service.knownDestinations.isEmpty {
                Menu(L("Destination")) {
                    Button(L("Any destination")) { filter.wrappedValue.destinationHost = nil }
                    Divider()
                    ForEach(service.knownDestinations, id: \.self) { host in
                        Button(action: { filter.wrappedValue.destinationHost = host }) {
                            if filter.wrappedValue.destinationHost == host { Image(systemName: "checkmark") }
                            Text(host)
                        }
                    }
                }
            }
            if !service.knownModels.isEmpty {
                Menu(L("Model")) {
                    Button(L("Any model")) { filter.wrappedValue.model = nil }
                    Divider()
                    ForEach(service.knownModels, id: \.self) { model in
                        Button(action: { filter.wrappedValue.model = model }) {
                            if filter.wrappedValue.model == model { Image(systemName: "checkmark") }
                            Text(model)
                        }
                    }
                }
            }
            Menu(L("Privacy Filter")) {
                Button(L("Any")) { filter.wrappedValue.privacyFilterApplied = nil }
                Button(L("Only privacy-filtered")) { filter.wrappedValue.privacyFilterApplied = true }
                Button(L("Only unfiltered")) { filter.wrappedValue.privacyFilterApplied = false }
            }
            Divider()
            Toggle(isOn: filter.includePluginLogs) { Text("Show plugin console logs", bundle: .module) }
            Toggle(isOn: Binding(
                get: { filter.wrappedValue.categories.contains(.system) },
                set: { on in
                    if on { filter.wrappedValue.categories.insert(.system) } else { filter.wrappedValue.categories.remove(.system) }
                }
            )) { Text("Category: System (chain-of-custody events)", bundle: .module) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .semibold))
                Text("More", bundle: .module).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.5)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Row

/// Fixed column widths shared by the table header and every row so they
/// stay aligned in both the full and compact layouts.
private struct ActivityTableColumns {
    let time: CGFloat = 64
    let locality: CGFloat
    let kind: CGFloat
    let source: CGFloat = 80
    let status: CGFloat = 56
    let size: CGFloat = 96
    let duration: CGFloat = 64

    init(compact: Bool) {
        locality = compact ? 108 : 150
        kind = compact ? 84 : 96
    }
}

private struct ActivityRow: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    var compact: Bool = false
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let columns = ActivityTableColumns(compact: compact)
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(log.formattedTimestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: columns.time, alignment: .leading)

                LocalityBadge(log: log)
                    .frame(width: columns.locality, alignment: .leading)
                    .clipped()

                HStack(spacing: 4) {
                    Image(systemName: log.category.icon).font(.system(size: 9, weight: .semibold))
                    Text(log.category.displayName).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .foregroundColor(categoryColor.opacity(0.9))
                .frame(width: columns.kind, alignment: .leading)

                HStack(spacing: 6) {
                    if let pluginId = log.pluginId {
                        InlineTag(tint: .teal) { Text(pluginId).font(.system(size: 8, weight: .bold)) }
                    }
                    if let agent = log.agentName {
                        InlineTag(tint: .purple) { Text(agent).font(.system(size: 8, weight: .bold)) }
                    }
                    if let toolCount = log.toolDefinitionCount {
                        ToolsBadge(count: toolCount)
                    }
                    if log.egress?.privacyFilterApplied == true {
                        InlineTag(tint: .green) {
                            Image(systemName: "hand.raised.fill").font(.system(size: 8, weight: .bold))
                        }
                        .help(Text("Privacy Filter rewrote spans before send", bundle: .module))
                    }
                    Text(log.title)
                        .font(.system(size: 12, weight: .medium, design: log.category == .inference ? .default : .monospaced))
                        .foregroundColor(log.isPluginLog ? logLevelColor(log.statusCode) : theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()

                SourceBadge(source: log.source)
                    .frame(width: columns.source, alignment: .leading)

                HTTPStatusBadge(statusCode: log.statusCode, isError: log.isError)
                    .frame(width: columns.status, alignment: .center)

                if !compact {
                    Text(sizeLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .frame(width: columns.size, alignment: .trailing)
                }

                Text(log.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: columns.duration, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(theme.accentColor).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sizeLabel: String {
        if let i = log.inputTokens, let o = log.outputTokens, i + o > 0 {
            return "\(i)→\(o) tok"
        }
        if let b = log.egress?.bytesSent, b > 0 {
            var s = "↑" + ActivitySummary.formattedBytes(b)
            if let r = log.egress?.bytesReceived, r > 0 { s += " ↓" + ActivitySummary.formattedBytes(r) }
            return s
        }
        if let r = log.egress?.bytesReceived, r > 0 {
            return "↓" + ActivitySummary.formattedBytes(r)
        }
        return "–"
    }

    private var categoryColor: Color {
        switch log.category {
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

    private func logLevelColor(_ statusCode: Int) -> Color {
        switch statusCode {
        case 500: return .red
        case 299: return .orange
        default: return theme.primaryText
        }
    }
}

// MARK: - Badges

/// Local / Cloud pill with destination.
struct LocalityBadge: View {
    @Environment(\.theme) private var theme
    let log: RequestLog

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: log.locality == .remote ? "icloud.fill" : "internaldrive.fill")
                .font(.system(size: 9, weight: .bold))
            Text(log.locality == .remote ? log.destinationDisplay : L("This Mac"))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if log.connection?.transport == .secureChannel {
                Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundColor(tint.opacity(0.95))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.13)))
        .help(helpText)
    }

    private var tint: Color { log.locality == .remote ? .blue : Color.gray }

    private var helpText: String {
        if log.locality == .local { return L("Data stayed on this Mac") }
        var parts = [String(format: L("Sent to %@"), log.destinationDisplay)]
        if let host = log.egress?.destinationHost ?? EgressInfo.host(from: log.connection?.remoteEndpoint) { parts.append(host) }
        if let classes = log.egress?.dataClasses, !classes.isEmpty { parts.append(classes.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

private struct StatPill: View {
    @Environment(\.theme) private var theme
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundColor(color.opacity(0.8))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(theme.primaryText)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.vertical, 2)
    }
}

private struct InlineTag<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(tint.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.12)))
    }
}

private struct ToolsBadge: View {
    let count: Int

    var body: some View {
        let helpText: LocalizedStringKey = count == 1 ? "1 tool sent" : "\(count) tools sent"
        InlineTag(tint: .teal) {
            HStack(spacing: 3) {
                Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 8, weight: .bold))
                Text("\(count)").font(.system(size: 9, weight: .bold, design: .monospaced))
            }
        }
        .localizedHelp(helpText)
    }
}

private struct HTTPStatusBadge: View {
    let statusCode: Int
    let isError: Bool

    var body: some View {
        Text(statusCode == 200 && !isError ? "ok" : "\(statusCode)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(statusColor))
    }

    private var statusColor: Color {
        if isError { return statusCode >= 500 || statusCode < 400 ? .red : .orange }
        if statusCode >= 200 && statusCode < 300 { return .green }
        if statusCode >= 400 && statusCode < 500 { return .orange }
        if statusCode >= 500 { return .red }
        return .gray
    }
}

struct SourceBadge: View {
    let source: RequestSource

    var body: some View {
        Text(source.shortName)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(badgeColor.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(badgeColor.opacity(0.15)))
    }

    private var badgeColor: Color {
        switch source {
        case .chatUI: return .pink
        case .agent: return .purple
        case .httpAPI: return .blue
        case .plugin: return .teal
        case .p2p: return .purple
        case .scheduled: return .orange
        case .channel: return .indigo
        case .schedule: return .orange
        case .watcher: return .yellow
        case .selfSchedule: return .mint
        case .tool: return .teal
        case .system: return .gray
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
