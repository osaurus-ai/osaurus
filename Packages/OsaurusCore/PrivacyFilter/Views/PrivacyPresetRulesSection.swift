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
//  removing one only drops the group from "My regions" — nothing is
//  silently disabled.
//
//  Presets: a suggestion banner when any home-region preset is off, a
//  search field, then groups in the order My regions → Global → Other
//  regions (collapsed). Per-row toggles and the group-level Enable all
//  / Disable all write through `saveDebounced` so a burst of flips
//  coalesces into one JSON write.
//

import SwiftUI

// MARK: - My Regions

struct PrivacyRegionsSection: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: PrivacyFilterConfiguration
    /// Synchronous save — region membership must land immediately.
    let save: () -> Void

    @State private var showAddRegion = false

    var body: some View {
        SettingsSection(title: L("My Regions"), icon: "globe", anchorId: "privacy.rules.regions") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Countries whose national ID, tax, health and bank number formats Osaurus should look for. The first region is detected from your Mac's locale; add or remove any region.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: 8) {
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
        return HStack(spacing: 6) {
            Text(verbatim: PrivacyRulePresets.regionFlag(code))
                .font(.system(size: 13))
            Text(verbatim: PrivacyRulePresets.regionDisplayName(code))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            if isDetected(code) {
                Text("(detected)", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            if presets.isEmpty {
                Text("generic", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            } else {
                Text(verbatim: "\(enabled)/\(presets.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(enabled == presets.count ? theme.secondaryText : theme.accentColor)
                    .localizedHelp("Presets on for this region, out of the total available.")
            }
            Button {
                configuration.removeHomeRegion(code)
                save()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .localizedHelp("Remove this region. Its presets stay as they are.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.tertiaryBackground)
                .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
        )
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
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text("Add region…", bundle: .module)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(SettingsButtonStyle(isPrimary: false))
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
    @Environment(\.theme) private var theme
    let excluded: Set<String>
    let onPick: (String) -> Void

    @State private var query: String = ""

    private struct Entry: Identifiable {
        let code: String
        let name: String
        let presetCount: Int
        var id: String { code }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var matching: [Entry] {
        PrivacyRulePresets.allISORegionCodes
            .filter { !excluded.contains($0) }
            .map {
                Entry(
                    code: $0,
                    name: PrivacyRulePresets.regionDisplayName($0),
                    presetCount: PrivacyRulePresets.presets(in: $0).count
                )
            }
            .filter { entry in
                let q = trimmedQuery
                guard !q.isEmpty else { return true }
                return entry.name.localizedCaseInsensitiveContains(q)
                    || entry.code.localizedCaseInsensitiveContains(q)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Mac's locale region, offered first when it isn't chosen yet
    /// (e.g. the user removed it, or a migrated config never seeded it).
    private var detected: Entry? {
        guard trimmedQuery.isEmpty,
            let code = PrivacyFilterConfiguration.regionCode(from: .current)
        else { return nil }
        return matching.first { $0.code == code }
    }

    private var specific: [Entry] { matching.filter { $0.presetCount > 0 && $0.code != detected?.code } }
    private var generic: [Entry] { matching.filter { $0.presetCount == 0 && $0.code != detected?.code } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                TextField(L("Search regions"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
            )

            // A plain VStack (not Lazy) so `fixedSize` can measure the
            // content and the popover shrinks to a short result list
            // instead of reserving the full height for three rows.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let detected {
                        header(L("Detected from your Mac"))
                        row(detected)
                    }
                    if !specific.isEmpty {
                        header(L("Country-specific presets"))
                        ForEach(specific) { row($0) }
                    }
                    if !generic.isEmpty {
                        header(L("Generic coverage only"))
                        ForEach(generic) { row($0) }
                    }
                    if matching.isEmpty {
                        Text("No regions match.", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .padding(8)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 300)
        }
        .padding(10)
        .frame(width: 320)
    }

    private func header(_ text: String) -> some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            onPick(entry.code)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: PrivacyRulePresets.regionFlag(entry.code))
                Text(verbatim: entry.name)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if entry.presetCount > 0 {
                    Text("\(entry.presetCount) presets", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                } else {
                    Text("Generic", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Rules

struct PrivacyPresetRulesSection: View {
    @Environment(\.theme) private var theme
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
        SettingsSection(title: L("Preset Rules"), icon: "books.vertical.fill", anchorId: "privacy.rules.presets") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Country-specific ID, tax, health and bank number formats plus global finance, network and secret patterns. Presets for your regions are on by default; everything else is opt-in. Osaurus redacts matches and blocks sends that leak them.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
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
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(presets.count) recommended presets are off", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text("Osaurus turns these on for \(joined) and Global on a new install.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                setPresets(presets.map(\.id), enabled: true)
            } label: {
                Text("Turn on", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { bannerDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .localizedHelp("Hide until Settings is reopened.")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accentColor.opacity(0.25), lineWidth: 1))
        )
    }

    // MARK: Search

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            TextField(L("Search presets by name, country or type"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if isSearching {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        )
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
        return VStack(alignment: .leading, spacing: 12) {
            if hits.isEmpty {
                Text("No presets match.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 6)
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
        VStack(alignment: .leading, spacing: 12) {
            if !configuration.homeRegions.isEmpty {
                sectionLabel(L("My regions"))
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
        Text(verbatim: text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .padding(.top, 4)
    }

    private var otherRegionsDisclosure: some View {
        let codes = otherRegionCodes
        let total = codes.reduce(0) { $0 + Presets.presets(in: $1).count }
        let enabled = codes.reduce(0) { sum, code in
            sum + Presets.presets(in: code).filter { configuration.isPresetEnabled($0.id) }.count
        }
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { otherRegionsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    sectionLabel(L("Other regions"))
                    Spacer()
                    Text(verbatim: "\(enabled)/\(total)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Image(systemName: otherRegionsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let region {
                    Text(verbatim: Presets.regionFlag(region))
                        .font(.system(size: 13))
                    Text(verbatim: Presets.regionDisplayName(region))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Text("Global", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }
                Text(verbatim: "\(enabledCount)/\(presets.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
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
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expandedOtherRegions.contains(region) {
                                expandedOtherRegions.remove(region)
                            } else {
                                expandedOtherRegions.insert(region)
                            }
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
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
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 8) {
                        ForEach(presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
        )
    }

    private func groupActionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(enabled ? theme.accentColor : theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Row

    private func presetRow(_ preset: Presets.Preset) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preset.kind.symbolName)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: preset.localizedTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    PrivacyCategoryBadge(category: preset.category)
                }
                Text(verbatim: preset.localizedSummary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(verbatim: preset.sample)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(LocalizedStringKey(preset.tier.localizationKey), bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText.opacity(0.8))
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
            .labelsHidden()
            .toggleStyle(.switch)
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
