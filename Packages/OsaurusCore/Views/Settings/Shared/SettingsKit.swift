//
//  SettingsKit.swift
//  osaurus
//
//  The shared building blocks every Management tab is composed from, so
//  General, Conversation, Voice, Tools, Privacy and Images all read the same
//  way. Complements `SettingsPrimitives.swift` (section card, fields,
//  toggle) with the page scaffold, generic rows, the collapsed "Advanced"
//  disclosure, and the destructive zone.
//
//  Kit at a glance:
//  - `SettingsPage`               header + scroll + padding + search landing
//  - `SettingsGroup`              the flat grouped-form surface rows sit in
//  - `SettingsRow`                title / description / trailing control
//  - `SettingsToggle`             (SettingsPrimitives) a `SettingsRow` + switch
//  - `SettingsPickerRow`          a `SettingsRow` + segmented / menu picker
//  - `SettingsLinkRow`            "this lives elsewhere" pointer or web link
//  - `SettingsAdvancedDisclosure` collapsed-by-default power-user options
//  - `SettingsDestructiveZone`    reset / wipe actions, always last on a page
//
//  Visual language: the macOS System Settings grouped form. A section is a
//  plain sentence-case title above one flat rounded surface; the rows inside
//  carry no chrome of their own and are separated by inset hairlines. Rows
//  used *outside* a group (channel sheets, server sections) keep a
//  self-contained card so they still read as a control there.
//

import SwiftUI

// MARK: - Group Environment

private struct SettingsInGroupKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering inside a `SettingsGroup` / `SettingsSection`
    /// surface. Row chrome reads it to drop its standalone card.
    var settingsInGroup: Bool {
        get { self[SettingsInGroupKey.self] }
        set { self[SettingsInGroupKey.self] = newValue }
    }
}

/// Shared metrics so the group, its rows, and its dividers line up.
enum SettingsGroupMetrics {
    static let cornerRadius: CGFloat = 10
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 12
    /// Rows without a description still get a comfortable hit target.
    static let rowMinHeight: CGFloat = 20
}

// MARK: - Settings Group

/// One flat grouped-form surface. Direct children become rows: each is inset
/// 16 × 12 and separated from the next by an inset hairline. Use it bare for
/// an untitled group (a lone toggle at the top of a page) or through
/// `SettingsSection`, which adds the title above.
struct SettingsGroup<Content: View>: View {
    @Environment(\.theme) private var theme

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsGroupMetrics.horizontalInset)
                        .padding(.vertical, SettingsGroupMetrics.verticalInset)
                    if index < subviews.count - 1 {
                        SettingsGroupDivider()
                    }
                }
            }
        }
        .environment(\.settingsInGroup, true)
        .background(
            RoundedRectangle(cornerRadius: SettingsGroupMetrics.cornerRadius)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsGroupMetrics.cornerRadius)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

/// The inset hairline between two rows of a group.
struct SettingsGroupDivider: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.cardBorder)
            .frame(height: 1)
            .padding(.leading, SettingsGroupMetrics.horizontalInset)
    }
}

/// The sentence-case label that sits above a group.
struct SettingsGroupTitle: View {
    @Environment(\.theme) private var theme

    let title: String

    var body: some View {
        Text(LocalizedStringKey(title), bundle: .module)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)
            .padding(.leading, 2)
    }
}

/// A group title with an optional live caption beside it ("1 connected ·
/// 12 tools") and a trailing accessory (search field, ⋯ menu). Use this
/// instead of `SettingsSection` when the header needs controls; pair it
/// with a `SettingsGroup` below.
struct SettingsSectionHeader<Accessory: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    /// Already-localized, dynamic caption; rendered verbatim.
    var caption: String? = nil
    @ViewBuilder let accessory: Accessory

    init(title: String, caption: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.caption = caption
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SettingsGroupTitle(title: title)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory
        }
        .frame(minHeight: 22)
    }
}

/// The small caption below a group, for a one-line explanation of the
/// group as a whole.
struct SettingsGroupFooter: View {
    @Environment(\.theme) private var theme

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

// MARK: - Settings Page

/// Standard scaffold for a Management tab: a header (usually one of the
/// `ManagerHeader*` variants) above a scrolling column of `SettingsSection`
/// cards. Owns the entrance animation and the settings-search landing scroll
/// so tabs don't each carry a copy of that plumbing.
///
/// Landing is anchor-agnostic: any control tagged `settingsLandingAnchor`
/// inside `content` registers itself via `SettingsLandingAnchorsKey`, and the
/// page scrolls to it when the coordinator publishes that id. Ids that live on
/// other tabs are ignored because they never register here.
struct SettingsPage<Header: View, Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsLandingPending) private var pendingLanding

    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    @State private var hasAppeared = false
    @State private var renderedAnchors: Set<String> = []

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .opacity(hasAppeared ? 1 : 0)
                .onPreferenceChange(SettingsLandingAnchorsKey.self) { anchors in
                    renderedAnchors = anchors
                    scrollToLanding(pendingLanding, proxy: proxy)
                }
                .onChange(of: pendingLanding) { _, id in
                    scrollToLanding(id, proxy: proxy)
                }
                .onAppear {
                    scrollToLanding(pendingLanding, proxy: proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    /// Scrolls a landed search target into view. The control glows itself via
    /// `settingsLandingAnchor`; this only positions it. Ids not rendered on
    /// this page (other tabs' anchors) are no-ops.
    private func scrollToLanding(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, renderedAnchors.contains(id) else { return }
        // Defer a beat so a freshly expanded disclosure / tab has laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

// MARK: - Settings Row

/// The one row shape used across settings: a title, an optional description
/// beneath it, and a trailing control (switch, picker, button, value). Flat
/// inside a `SettingsGroup` (the group draws the surface and dividers); a
/// self-contained card elsewhere.
struct SettingsRow<Trailing: View, Description: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    var badge: String? = nil
    /// Settings-search landing anchor for this row.
    var anchorId: String? = nil
    @ViewBuilder let description: Description
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        badge: String? = nil,
        anchorId: String? = nil,
        @ViewBuilder description: () -> Description,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.badge = badge
        self.anchorId = anchorId
        self.description = description()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    if let badge {
                        Text(LocalizedStringKey(badge), bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.accentColor)
                    }
                }
                description
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            trailing
        }
        .settingsRowChrome()
        .settingsLandingAnchor(anchorId)
    }
}

// MARK: - Row chrome

extension View {
    /// The canonical settings-row surface. Inside a `SettingsGroup` this is
    /// just a min-height so the group's inset + dividers do the framing; on
    /// its own it is the 12pt-padded, 10pt-rounded `inputBackground` card
    /// hand-built rows relied on. `SettingsRow` (and therefore
    /// `SettingsToggle`) uses it; custom-layout rows apply it directly.
    func settingsRowChrome() -> some View {
        modifier(SettingsRowChrome())
    }
}

private struct SettingsRowChrome: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.settingsInGroup) private var inGroup

    func body(content: Content) -> some View {
        if inGroup {
            content
                .frame(maxWidth: .infinity, minHeight: SettingsGroupMetrics.rowMinHeight, alignment: .leading)
        } else {
            content
                .padding(12)
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
}

extension SettingsRow where Description == Text {
    /// Plain-string description convenience. An empty description renders
    /// nothing beneath the title.
    init(
        title: String,
        description: String,
        badge: String? = nil,
        anchorId: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            badge: badge,
            anchorId: anchorId,
            description: { Text(LocalizedStringKey(description), bundle: .module) },
            trailing: trailing
        )
    }
}

// MARK: - Settings Picker Row

/// A `SettingsRow` whose trailing control is a picker. Segmented for a few
/// short options (permission Ask / Deny / Allow), menu for longer lists.
struct SettingsPickerRow<Value: Hashable>: View {
    @Environment(\.theme) private var theme

    enum Style {
        case segmented
        case menu
    }

    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }

        init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    let title: String
    var description: String = ""
    var anchorId: String? = nil
    var style: Style = .segmented
    let options: [Option]
    @Binding var selection: Value

    init(
        title: String,
        description: String = "",
        anchorId: String? = nil,
        style: Style = .segmented,
        selection: Binding<Value>,
        options: [Option]
    ) {
        self.title = title
        self.description = description
        self.anchorId = anchorId
        self.style = style
        self.options = options
        self._selection = selection
    }

    var body: some View {
        SettingsRow(title: title, description: description, anchorId: anchorId) {
            picker
        }
    }

    @ViewBuilder
    private var picker: some View {
        switch style {
        case .segmented:
            Picker("", selection: $selection) {
                ForEach(options) { option in
                    Text(LocalizedStringKey(option.label), bundle: .module).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .menu:
            Menu {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        HStack {
                            Text(LocalizedStringKey(option.label), bundle: .module)
                            if option.value == selection {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(
                        LocalizedStringKey(options.first { $0.value == selection }?.label ?? ""),
                        bundle: .module
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Settings Link Row

/// A row that takes the user somewhere else: another settings tab that owns
/// the control ("Context Window Cap lives under Server → Cache"), or a web
/// page (Terms of Service). Keeps pointer rows from being rebuilt as bespoke
/// HStacks on every tab.
struct SettingsLinkRow: View {
    @Environment(\.theme) private var theme

    let title: String
    var description: String = ""
    var icon: String = "arrow.up.right.square"
    var actionTitle: String = "Open"
    var anchorId: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    init(
        title: String,
        description: String = "",
        icon: String = "arrow.up.right.square",
        actionTitle: String = "Open",
        anchorId: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.actionTitle = actionTitle
        self.anchorId = anchorId
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title, description: description, anchorId: anchorId) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(actionTitle), bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .opacity(isHovering ? 0.8 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Advanced Disclosure

/// Collapsed-by-default home for power-user options, so a page's everyday
/// controls stay short. Opens automatically when a settings-search result
/// lands on one of `anchorIds` (the ids of controls rendered inside), so a
/// tucked-away setting is still one click away from the search field.
struct SettingsAdvancedDisclosure<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsLandingPending) private var pendingLanding

    let title: String
    /// Landing anchor ids of the controls inside. A pending landing on any of
    /// them expands the disclosure before the page scrolls to it.
    let anchorIds: Set<String>
    @ViewBuilder let content: Content

    @State private var isExpanded = false

    init(
        title: String = "Advanced",
        anchorIds: Set<String> = [],
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.anchorIds = anchorIds
        self.content = content()
    }

    var body: some View {
        // One group: a disclosure row, then — when open — the tucked-away
        // controls as further rows of the same surface.
        SettingsGroup {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, minHeight: SettingsGroupMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module))

            if isExpanded {
                content
            }
        }
        .onAppear { expandIfLanding(pendingLanding) }
        .onChange(of: pendingLanding) { _, id in expandIfLanding(id) }
    }

    private func expandIfLanding(_ id: String?) {
        guard let id, !isExpanded, anchorIds.contains(id) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            isExpanded = true
        }
    }
}

// MARK: - Destructive Zone

/// The group that closes a page: factory reset, identity reset, wipe caches.
/// Same surface as every other group — the red lives on the action button,
/// not on a tinted card. Always place this last so nothing routine sits
/// below it.
struct SettingsDestructiveZone<Content: View>: View {
    let title: String
    var anchorId: String? = nil
    @ViewBuilder let content: Content

    init(title: String = "Danger Zone", anchorId: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.anchorId = anchorId
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroupTitle(title: title)
            SettingsGroup {
                content
            }
        }
        .settingsLandingAnchor(anchorId)
    }
}

/// One action inside a `SettingsDestructiveZone`.
struct SettingsDestructiveRow: View {
    @Environment(\.theme) private var theme

    enum Severity {
        case warning
        case destructive
    }

    let title: String
    let description: String
    let actionTitle: String
    var severity: Severity = .destructive
    var anchorId: String? = nil
    let action: () -> Void

    init(
        title: String,
        description: String,
        actionTitle: String,
        severity: Severity = .destructive,
        anchorId: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.severity = severity
        self.anchorId = anchorId
        self.action = action
    }

    private var tint: Color {
        severity == .warning ? theme.warningColor : theme.errorColor
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(LocalizedStringKey(actionTitle), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.tertiaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .settingsRowChrome()
        .settingsLandingAnchor(anchorId)
    }
}
