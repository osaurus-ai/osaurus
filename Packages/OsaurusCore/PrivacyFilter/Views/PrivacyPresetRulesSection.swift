//
//  PrivacyPresetRulesSection.swift
//  osaurus / PrivacyFilter
//
//  "My Regions" + "Preset Rules" sections of the Privacy → Rules tab.
//
//  Regions: chips for every `homeRegions` entry plus an "Add region…"
//  popover over every ISO 3166 region the OS knows (localized names
//  come from `Locale`, not the string catalog). Adding a region turns
//  on its presets (`PrivacyFilterConfiguration.addHomeRegion`);
//  removing one only drops the group from "My Regions" — nothing is
//  silently disabled.
//
//  Presets: a suggestion banner when any home-region preset is off, a
//  search field, then groups in the order My Regions → Global → Other
//  regions (collapsed). Per-row toggles and the group-level Enable all
//  / Disable all write through `saveDebounced` so a burst of flips
//  coalesces into one JSON write.
//

import SwiftUI

// MARK: - My Regions

struct PrivacyRegionsSection: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var configuration: PrivacyFilterConfiguration
    /// Synchronous save — region membership must land immediately.
    let save: () -> Void

    @State private var showAddRegion = false

    var body: some View {
        SettingsSection(title: "My Regions", anchorId: "privacy.rules.regions") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(
                    "Countries whose national ID, tax, health and bank number formats Osaurus should look for. The first region is detected from your Mac's locale; add or remove any region.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: theme.space.s8) {
                    ForEach(configuration.homeRegions, id: \.self) { code in
                        regionChip(code)
                    }
                    addRegionButton
                }
            }
            .settingsRowChrome()
        }
    }

    private func regionChip(_ code: String) -> some View {
        let presets = PrivacyRulePresets.presets(in: code)
        let enabled = presets.filter { configuration.isPresetEnabled($0.id) }.count
        return HStack(spacing: theme.space.s6) {
            Text(verbatim: PrivacyRulePresets.regionFlag(code))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
            Text(verbatim: PrivacyRulePresets.regionDisplayName(code))
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            if isDetected(code) {
                Text("(detected)", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            if presets.isEmpty {
                Text("generic", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            } else {
                Text(verbatim: "\(enabled)/\(presets.count)")
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                    .foregroundColor(enabled == presets.count ? theme.text.secondary : theme.text.link)
                    .localizedHelp("Presets on for this region, out of the total available.")
            }
            Button {
                configuration.removeHomeRegion(code)
                save()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .glyphSize(.caption)
                    .foregroundColor(theme.text.tertiary)
            }
            .buttonStyle(.plain)
            .localizedHelp("Remove this region. Its presets stay as they are.")
        }
        .modifier(ChipChrome(theme: theme))
    }

    /// Shared capsule for region chips and the "Add region…" button so
    /// the two sit at exactly the same height in the flow.
    private struct ChipChrome: ViewModifier {
        let theme: ThemeProtocol
        func body(content: Content) -> some View {
            content
                .frame(height: 16)
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(.control)
        }
    }

    /// The chip reads "(detected)" while the list is still exactly the
    /// locale seed; any edit (add or remove) drops the hint.
    private func isDetected(_ code: String) -> Bool {
        guard configuration.homeRegions.count == 1,
            let localeRegion = PrivacyFilterConfiguration.regionCode(from: .current)
        else { return false }
        return code == localeRegion
    }

    private var addRegionButton: some View {
        Button {
            showAddRegion = true
        } label: {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "plus")
                    .glyphSize(.micro, weight: .semibold)
                Text("Add region…", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            }
            .foregroundColor(theme.text.link)
            .modifier(ChipChrome(theme: theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddRegion, arrowEdge: .bottom) {
            PrivacyRegionPicker(excluded: Set(configuration.homeRegions)) { code in
                configuration.addHomeRegion(code)
                save()
                showAddRegion = false
            }
        }
    }
}

/// Searchable list of every ISO region, minus the ones already chosen.
/// Regions with country-specific presets show a count; the rest read
/// "Generic" so the user knows what adding them buys.
private struct PrivacyRegionPicker: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let excluded: Set<String>
    let onPick: (String) -> Void

    @State private var query: String = ""
    /// All candidate regions, built once on appear (≈250 locale
    /// lookups) rather than on every keystroke / render.
    @State private var entries: [Entry] = []

    private struct Entry: Identifiable {
        let code: String
        let name: String
        let presetCount: Int
        var id: String { code }
    }

    /// Everything `body` needs, derived from `entries` + `query` in a
    /// single pass so the list is filtered once per render.
    private struct Buckets {
        var detected: Entry?
        var specific: [Entry] = []
        var generic: [Entry] = []
        var isEmpty: Bool { detected == nil && specific.isEmpty && generic.isEmpty }
        var rowCount: Int { (detected == nil ? 0 : 1) + specific.count + generic.count }
        var headerCount: Int { (detected == nil ? 0 : 1) + (specific.isEmpty ? 0 : 1) + (generic.isEmpty ? 0 : 1) }
    }

    private func buildEntries() -> [Entry] {
        PrivacyRulePresets.allISORegionCodes
            .filter { !excluded.contains($0) }
            .map {
                Entry(
                    code: $0,
                    name: PrivacyRulePresets.regionDisplayName($0),
                    presetCount: PrivacyRulePresets.presets(in: $0).count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func bucket() -> Buckets {
        let q = query.trimmingCharacters(in: .whitespaces)
        let localeRegion = q.isEmpty ? PrivacyFilterConfiguration.regionCode(from: .current) : nil
        var out = Buckets()
        for entry in entries {
            if !q.isEmpty,
                !entry.name.localizedCaseInsensitiveContains(q),
                !entry.code.localizedCaseInsensitiveContains(q)
            {
                continue
            }
            if entry.code == localeRegion {
                // The Mac's locale region is offered first when it isn't
                // chosen yet (removed, or a migrated config never seeded it).
                out.detected = entry
            } else if entry.presetCount > 0 {
                out.specific.append(entry)
            } else {
                out.generic.append(entry)
            }
        }
        return out
    }

    private static let rowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 24
    private static let maxListHeight: CGFloat = 300

    var body: some View {
        let buckets = bucket()
        // Explicit height: a `fixedSize` ScrollView lays out at full
        // content height and then gets clipped, which drew rows over the
        // search field. Sizing from the row count keeps short result
        // lists tight and long ones scrollable.
        let listHeight = min(
            Self.maxListHeight,
            max(
                Self.rowHeight,
                CGFloat(buckets.rowCount) * Self.rowHeight + CGFloat(buckets.headerCount) * Self.headerHeight
            )
        )
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SearchField(text: $query, placeholder: "Search regions", fillsAvailableWidth: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.space.s0) {
                    if let detected = buckets.detected {
                        header(L("Detected from your Mac"))
                        row(detected)
                    }
                    if !buckets.specific.isEmpty {
                        header(L("Country-specific presets"))
                        ForEach(buckets.specific) { row($0) }
                    }
                    if !buckets.generic.isEmpty {
                        header(L("Generic coverage only"))
                        ForEach(buckets.generic) { row($0) }
                    }
                    if buckets.isEmpty {
                        Text("No regions match.", bundle: .module)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .frame(height: Self.rowHeight)
                            .padding(.horizontal, theme.space.s8)
                    }
                }
            }
            .frame(height: listHeight)
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
        .frame(width: 320)
        .onAppear {
            if entries.isEmpty { entries = buildEntries() }
        }
    }

    private func header(_ text: String) -> some View {
        Text(verbatim: text)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            .foregroundColor(theme.text.tertiary)
            .padding(.horizontal, theme.space.s8)
            .frame(height: Self.headerHeight, alignment: .bottomLeading)
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            onPick(entry.code)
        } label: {
            HStack(spacing: theme.space.s8) {
                Text(verbatim: PrivacyRulePresets.regionFlag(entry.code))
                Text(verbatim: entry.name)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if entry.presetCount > 0 {
                    Text("\(entry.presetCount) presets", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(theme.text.secondary)
                } else {
                    Text("Generic", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Rules

struct PrivacyPresetRulesSection: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var configuration: PrivacyFilterConfiguration
    let saveDebounced: () -> Void

    @State private var searchText: String = ""
    /// Session-only: the banner comes back on next open, which is the
    /// right nag level for "you have recommended presets off".
    @State private var bannerDismissed = false
    @State private var otherRegionsExpanded = false
    /// Region groups the user has expanded inside "Other regions".
    /// Home-region and Global groups are always open.
    @State private var expandedOtherRegions: Set<String> = []

    private typealias Presets = PrivacyRulePresets

    var body: some View {
        SettingsSection(title: "Preset Rules", anchorId: "privacy.rules.presets") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                Text(
                    "Country-specific ID, tax, health and bank number formats plus global finance, network and secret patterns. Presets for your regions are on by default; everything else is opt-in. Osaurus redacts matches and blocks sends that leak them.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                if !bannerDismissed, let suggestion = suggestedPresets, !suggestion.isEmpty {
                    suggestionBanner(suggestion)
                }

                searchField

                if isSearching {
                    searchResults
                } else {
                    groupedCatalogue
                }
            }
            .settingsRowChrome()
        }
    }

    // MARK: Suggestion banner

    /// Presets a fresh install would enable for the current home
    /// regions that are currently off (or unset). `nil` when there are
    /// no home regions.
    private var suggestedPresets: [Presets.Preset]? {
        guard !configuration.homeRegions.isEmpty else { return nil }
        let wanted = Presets.defaultPresetRules(forRegions: configuration.homeRegions)
        return Presets.all.filter { wanted[$0.id] == true && !configuration.isPresetEnabled($0.id) }
    }

    private func suggestionBanner(_ presets: [Presets.Preset]) -> some View {
        let names = configuration.homeRegions.map { Presets.regionDisplayName($0) }
        let joined = ListFormatter.localizedString(byJoining: names)
        return HStack(alignment: .center, spacing: theme.space.s8) {
            Image(systemName: "lightbulb.fill")
                .glyphSize(.caption)
                .foregroundColor(theme.text.link)
            SettingsRowText(compact: true) {
                Text("\(presets.count) recommended presets are off", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            } description: {
                Text("Osaurus turns these on for \(joined) and Global on a new install.", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            }
            Spacer()
            Button {
                setPresets(presets.map(\.id), enabled: true)
            } label: {
                Text("Turn on", bundle: .module)
            }
            .buttonStyle(.settings(.primary))
            SettingsIconButton("xmark", help: "Hide until Settings is reopened.", size: .compact) {
                withAnimation(theme.motion.quick) { bannerDismissed = true }
            }
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
        .settingsChrome(.selected)
    }

    // MARK: Search

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchField: some View {
        SearchField(text: $searchText, placeholder: "Search presets by name, country or type", fillsAvailableWidth: true)
    }

    private func matches(_ preset: Presets.Preset, query: String) -> Bool {
        if preset.localizedTitle.localizedCaseInsensitiveContains(query) { return true }
        if preset.id.localizedCaseInsensitiveContains(query) { return true }
        if preset.kind.rawValue.localizedCaseInsensitiveContains(query) { return true }
        if let region = preset.regionCode {
            if region.localizedCaseInsensitiveContains(query) { return true }
            if Presets.regionDisplayName(region).localizedCaseInsensitiveContains(query) { return true }
        } else if L("Global").localizedCaseInsensitiveContains(query) {
            return true
        }
        return false
    }

    private var searchResults: some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let hits = Presets.all.filter { matches($0, query: query) }
        // Group hits by region (Global first), preserving catalogue order.
        var order: [String?] = []
        var buckets: [String?: [Presets.Preset]] = [:]
        for hit in hits {
            if buckets[hit.regionCode] == nil { order.append(hit.regionCode) }
            buckets[hit.regionCode, default: []].append(hit)
        }
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            if hits.isEmpty {
                Text("No presets match.", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.vertical, theme.space.s6)
            }
            ForEach(order, id: \.self) { region in
                groupView(region: region, presets: buckets[region] ?? [], collapsible: false, expanded: true)
            }
        }
    }

    // MARK: Grouped catalogue

    private var otherRegionCodes: [String] {
        let home = Set(configuration.homeRegions)
        return Presets.regionCodes.filter { !home.contains($0) }
    }

    private var groupedCatalogue: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if !configuration.homeRegions.isEmpty {
                sectionLabel(L("My Regions"))
                ForEach(configuration.homeRegions, id: \.self) { code in
                    groupView(region: code, presets: Presets.presets(in: code), collapsible: false, expanded: true)
                }
            }

            sectionLabel(L("Global"))
            groupView(region: nil, presets: Presets.globalPresets, collapsible: false, expanded: true)

            otherRegionsDisclosure
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            .foregroundColor(theme.text.tertiary)
            .padding(.top, theme.space.s4)
    }

    private var otherRegionsDisclosure: some View {
        let codes = otherRegionCodes
        let total = codes.reduce(0) { $0 + Presets.presets(in: $1).count }
        let enabled = codes.reduce(0) { sum, code in
            sum + Presets.presets(in: code).filter { configuration.isPresetEnabled($0.id) }.count
        }
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            Button {
                withAnimation(theme.motion.quick) { otherRegionsExpanded.toggle() }
            } label: {
                HStack(spacing: theme.space.s8) {
                    sectionLabel(L("Other regions"))
                    Spacer()
                    Text(verbatim: "\(enabled)/\(total)")
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    Image(systemName: otherRegionsExpanded ? "chevron.up" : "chevron.down")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if otherRegionsExpanded {
                ForEach(codes, id: \.self) { code in
                    groupView(
                        region: code,
                        presets: Presets.presets(in: code),
                        collapsible: true,
                        expanded: expandedOtherRegions.contains(code)
                    )
                }
            }
        }
    }

    // MARK: Group

    @ViewBuilder
    private func groupView(
        region: String?,
        presets: [Presets.Preset],
        collapsible: Bool,
        expanded: Bool
    ) -> some View {
        let enabledCount = presets.filter { configuration.isPresetEnabled($0.id) }.count
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                if let region {
                    Text(verbatim: Presets.regionFlag(region))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                    Text(verbatim: Presets.regionDisplayName(region))
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                } else {
                    Image(systemName: "globe")
                        .glyphSize(.caption)
                        .foregroundColor(theme.text.secondary)
                    Text("Global", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                }
                Text(verbatim: "\(enabledCount)/\(presets.count)")
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Spacer()
                if !presets.isEmpty {
                    groupActionButton(L("Enable all"), enabled: enabledCount < presets.count) {
                        setPresets(presets.map(\.id), enabled: true)
                    }
                    groupActionButton(L("Disable all"), enabled: enabledCount > 0) {
                        setPresets(presets.map(\.id), enabled: false)
                    }
                }
                if collapsible, let region {
                    Button {
                        withAnimation(theme.motion.quick) {
                            if expandedOtherRegions.contains(region) {
                                expandedOtherRegions.remove(region)
                            } else {
                                expandedOtherRegions.insert(region)
                            }
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .glyphSize(.footnote, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if expanded {
                if presets.isEmpty {
                    Text(
                        "Generic patterns only — add specific rules under Custom Rules.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: theme.space.s8) {
                        ForEach(presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
        .settingsChrome(.surface)
    }

    private func groupActionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(enabled ? theme.text.link : theme.text.tertiary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Row

    private func presetRow(_ preset: Presets.Preset) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Image(systemName: preset.kind.symbolName)
                .glyphSize(.caption)
                .foregroundColor(theme.text.secondary)
                .frame(width: 18)
                .padding(.top, theme.space.s2)
            SettingsRowText(compact: true) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: preset.localizedTitle)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    PrivacyCategoryBadge(category: preset.category)
                }
            } description: {
                Text(verbatim: preset.localizedSummary)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: preset.sample)
                        .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(LocalizedStringKey(preset.tier.localizationKey), bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .help(tierHelp(preset.tier))
                }
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { configuration.isPresetEnabled(preset.id) },
                    set: { newValue in
                        configuration.presetRules[preset.id] = newValue
                        saveDebounced()
                    }
                )
            )
            .settingsSwitch()
        }
        .settingsRowChrome()
    }

    private func tierHelp(_ tier: Presets.Tier) -> String {
        switch tier {
        case .validated:
            return L("Check digit verified — bare numbers can be matched with few false positives.")
        case .anchored:
            return L("Matches the documented shape, usually after a keyword; no checksum exists for this ID.")
        case .generic:
            return L("Multilingual keyword fallback for regions without a specific preset.")
        }
    }

    // MARK: Writes

    private func setPresets(_ ids: [String], enabled: Bool) {
        for id in ids {
            configuration.presetRules[id] = enabled
        }
        saveDebounced()
    }
}
