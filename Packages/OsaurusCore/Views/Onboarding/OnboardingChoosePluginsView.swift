//
//  OnboardingChoosePluginsView.swift
//  osaurus
//
//  Onboarding step 6 — pick a few starter tools (browser, spreadsheet,
//  slides, …) before landing in the walkthrough. The list is curated
//  locally in `ChoosePluginsState.curated`; we filter against the live
//  `PluginRepositoryService` so any pick missing from the remote
//  catalog just doesn't show up.
//
//  Behaviour:
//   - Catalog refresh fires on first appear (warm cache after AppDelegate
//     boot, but cold first-run can be slow — show a loading state).
//   - Default-on picks are pre-ticked. Already-installed plugins show an
//     "Installed" badge with no toggle.
//   - Tapping the primary CTA installs every ticked, not-yet-installed
//     plugin in a detached task and advances immediately. Onboarding
//     never blocks on installs.
//   - If any installed plugin turns out to need secrets (manifest may
//     change between releases) we suppress the pendingSecretsPlugin sheet
//     so it doesn't pop over the walkthrough; the user can configure that
//     plugin later from Settings.
//

import SwiftUI

// MARK: - Curated pick

/// Onboarding-only marketing wrapper around a remote plugin spec. The
/// catalog ships a generic `puzzlepiece.extension.fill` icon for every
/// plugin; this struct overrides display name, blurb, and an SF Symbol
/// so the picker reads visually distinct.
struct OnboardingPluginPick {
    let pluginId: String
    let displayName: String
    let blurb: String
    let icon: String
    let isDefaultOn: Bool
}

// MARK: - State

@MainActor
final class ChoosePluginsState: ObservableObject {
    @Published var selectedIds: Set<String> = []
    @Published var hasLoaded: Bool = false
    @Published var isLoading: Bool = false

    /// Curated picks shown in the onboarding picker. Order matters — the
    /// grid renders in this order. Only entries that also exist in the
    /// remote catalog (`PluginRepositoryService.shared.plugins`) are
    /// surfaced; everything else is silently dropped.
    ///
    /// Skew is intentionally work-focused (browser + spreadsheets +
    /// slides) for the default-on picks so the first-run agent can
    /// actually do something useful out of the box.
    static let curated: [OnboardingPluginPick] = [
        OnboardingPluginPick(
            pluginId: "osaurus.browser",
            displayName: "Browser",
            blurb: "Open pages and pull text from the web.",
            icon: "safari.fill",
            isDefaultOn: true
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.xlsx",
            displayName: "Excel",
            blurb: "Read and build Excel spreadsheets.",
            icon: "tablecells.fill",
            isDefaultOn: true
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.pptx",
            displayName: "PowerPoint",
            blurb: "Build PowerPoint decks from scratch.",
            icon: "rectangle.on.rectangle.angled",
            isDefaultOn: false
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.files",
            displayName: "Files",
            blurb: "Read and write files in your projects.",
            icon: "folder.fill",
            isDefaultOn: false
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.shell",
            displayName: "Shell",
            blurb: "Run terminal commands inside the safety net.",
            icon: "terminal.fill",
            isDefaultOn: false
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.calendar",
            displayName: "Calendar",
            blurb: "See and create events on your Mac.",
            icon: "calendar",
            isDefaultOn: false
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.reminders",
            displayName: "Reminders",
            blurb: "Make and check off your Reminders.",
            icon: "checklist",
            isDefaultOn: false
        ),
        OnboardingPluginPick(
            pluginId: "osaurus.messages",
            displayName: "Messages",
            blurb: "Send iMessages from your Mac.",
            icon: "message.fill",
            isDefaultOn: false
        ),
    ]

    /// Picks that are present in the live catalog, paired with their
    /// `PluginState` for install/installing flags.
    var visiblePicks: [VisiblePick] {
        let live = PluginRepositoryService.shared.plugins
        return Self.curated.compactMap { pick in
            guard let state = live.first(where: { $0.pluginId == pick.pluginId }) else {
                return nil
            }
            return VisiblePick(pick: pick, state: state)
        }
    }

    struct VisiblePick: Identifiable {
        let pick: OnboardingPluginPick
        let state: PluginState
        var id: String { pick.pluginId }
    }

    /// Refreshes the catalog if it hasn't been loaded yet and seeds the
    /// default selection from `isDefaultOn`. Already-installed picks
    /// are intentionally excluded from `selectedIds` — they're rendered
    /// as a passive "Installed" badge, not a toggle.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        isLoading = true

        if PluginRepositoryService.shared.plugins.isEmpty {
            await PluginRepositoryService.shared.refresh()
        }

        seedDefaultSelection()
        hasLoaded = true
        isLoading = false
    }

    private func seedDefaultSelection() {
        let available = visiblePicks
        selectedIds = Set(
            available
                .filter { $0.pick.isDefaultOn && !$0.state.isInstalled }
                .map { $0.pick.pluginId }
        )
    }

    func isSelected(_ pluginId: String) -> Bool {
        selectedIds.contains(pluginId)
    }

    func toggle(_ pluginId: String) {
        if selectedIds.contains(pluginId) {
            selectedIds.remove(pluginId)
        } else {
            selectedIds.insert(pluginId)
        }
    }

    /// IDs that will actually be installed when the CTA fires (selected
    /// but not yet installed). Drives the CTA's title between "Install
    /// picks" and "Continue".
    var idsToInstall: [String] {
        let installed = Set(visiblePicks.filter { $0.state.isInstalled }.map { $0.pick.pluginId })
        return selectedIds.subtracting(installed).sorted()
    }

    /// Fires install tasks for every selected, not-yet-installed pick and
    /// immediately calls `onComplete`. Installs continue in the background;
    /// the user can verify state later from the Plugins surface.
    func installAndAdvance(onComplete: @escaping () -> Void) {
        let ids = idsToInstall
        for pluginId in ids {
            Task.detached(priority: .userInitiated) {
                try? await PluginRepositoryService.shared.install(pluginId: pluginId)
                // Don't pop a secrets sheet over the walkthrough — if this
                // pick turns out to require secrets we'd rather the user
                // discover that later in Settings than be yanked back.
                await MainActor.run {
                    if PluginRepositoryService.shared.pendingSecretsPlugin == pluginId {
                        PluginRepositoryService.shared.pendingSecretsPlugin = nil
                    }
                }
            }
        }
        onComplete()
    }
}

// MARK: - Layout constants

/// Onboarding-only layout tuning for the plugin picker grid. Kept
/// file-local so other onboarding steps don't accidentally inherit a
/// 2-column rhythm that's specific to this picker.
private enum PluginPickerLayout {
    /// Two equal-width cards per row. The right column of the
    /// two-column onboarding body is ~424pt wide, which gives ~207pt
    /// per card after the inner spacing — tight, but workable with the
    /// 28pt icon + compact accessory layout in `PluginPickCard`.
    static let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]
    static let gridSpacing: CGFloat = 10
}

// MARK: - Body

struct ChoosePluginsBody: View {
    @ObservedObject var state: ChoosePluginsState
    /// Observed (not used directly) so SwiftUI re-renders when the
    /// remote catalog list changes — `state.visiblePicks` reads
    /// `PluginRepositoryService.shared.plugins`, and that property
    /// can't trigger updates through `state` alone.
    @ObservedObject private var repo = PluginRepositoryService.shared

    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-tool",
            leftHeadline: "Pick what your agent can do",
            leftBody:
                "Tools are little powers your agent can use — like reading the web or grabbing a file. Add a couple now, swap them in and out any time from Settings.",
            subtitle: "All optional. Add or remove anytime."
        ) {
            content
        }
        .task { await state.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        // Compute once per render — `visiblePicks` walks the full
        // catalog inside a `compactMap`, and the body used to call it
        // three times per refresh.
        let picks = state.visiblePicks
        if picks.isEmpty {
            if state.isLoading {
                loadingCard
            } else {
                emptyCard
            }
        } else {
            VStack(alignment: .leading, spacing: OnboardingMetrics.cardSpacing) {
                pluginGrid(picks: picks)
                footnoteRow
            }
        }
    }

    private func pluginGrid(picks: [ChoosePluginsState.VisiblePick]) -> some View {
        LazyVGrid(columns: PluginPickerLayout.columns, spacing: PluginPickerLayout.gridSpacing) {
            ForEach(picks) { entry in
                PluginPickCard(
                    entry: entry,
                    isSelected: state.isSelected(entry.pick.pluginId),
                    onToggle: { state.toggle(entry.pick.pluginId) }
                )
            }
        }
    }

    private var loadingCard: some View {
        OnboardingGlassCard {
            HStack(spacing: 12) {
                ProgressView().scaleEffect(0.85)
                Text("Loading recommended tools…", bundle: .module)
                    .font(theme.font(size: 13))
                    .foregroundColor(theme.secondaryText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(14)
        }
    }

    private var emptyCard: some View {
        OnboardingGlassCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Couldn't load the tool list", bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "We'll keep trying. You can also add tools later from Settings.",
                        bundle: .module
                    )
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private var footnoteRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(
                "Browse the full catalog in Settings → Plugins.",
                bundle: .module
            )
            .font(theme.font(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 4)
    }
}

// MARK: - Plugin Pick Card

/// One card in the onboarding plugin grid. Pulled out of
/// `ChoosePluginsBody` so SwiftUI can diff and re-render a single card
/// when its selection toggles, instead of walking the whole body.
private struct PluginPickCard: View {
    let entry: ChoosePluginsState.VisiblePick
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var theme

    private var installed: Bool { entry.state.isInstalled }
    private var installing: Bool { entry.state.isInstalling }

    var body: some View {
        Button {
            if !installed { onToggle() }
        } label: {
            OnboardingGlassCard(isSelected: isSelected && !installed) {
                cardContent
            }
        }
        .buttonStyle(.plain)
        .disabled(installed || installing)
        .opacity(installed ? 0.78 : 1.0)
    }

    /// Title + accessory share one row INSIDE the right column (not as
    /// siblings of the icon at the top-level `HStack`). At ~207pt card
    /// width the previous layout gave the title only ~55pt — enough to
    /// truncate "Calendar" to "Calen…" and force the "Installed"
    /// capsule to wrap onto a second line.
    private var cardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            iconBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(LocalizedStringKey(entry.pick.displayName), bundle: .module)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    accessory
                }
                Text(LocalizedStringKey(entry.pick.blurb), bundle: .module)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor.opacity(0.14))
                .frame(width: 28, height: 28)
            Image(systemName: entry.pick.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
        .fixedSize()
    }

    /// Trailing accessory — install spinner, "Installed" badge, or
    /// radio glyph. All three branches commit to identical bounding
    /// boxes (16×16 spinner / fixed-width capsule / 18×18 framed glyph)
    /// so toggling selection never re-flows the surrounding row.
    @ViewBuilder
    private var accessory: some View {
        if installing {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        } else if installed {
            Text("Installed", bundle: .module)
                .font(theme.font(size: 9, weight: .bold))
                .foregroundColor(theme.successColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.successColor.opacity(0.14)))
        } else {
            // Single SF Symbol for both states — see comment above.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isSelected ? theme.accentColor : theme.primaryBorder)
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - CTA

struct ChoosePluginsCTA: View {
    @ObservedObject var state: ChoosePluginsState
    let onComplete: () -> Void

    var body: some View {
        let willInstall = state.idsToInstall
        let title: String =
            willInstall.isEmpty
            ? L("Continue")
            : (willInstall.count == 1 ? L("Install 1 Tool") : L("Install \(willInstall.count) Tools"))

        return OnboardingBrandButton(title: title) {
            state.installAndAdvance(onComplete: onComplete)
        }
        .frame(width: OnboardingMetrics.ctaWidthCompact)
    }
}

// MARK: - Secondary

struct ChoosePluginsSecondary: View {
    let onSkip: () -> Void

    var body: some View {
        OnboardingTextButton(title: "Skip for now", action: onSkip)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingChoosePluginsView_Previews: PreviewProvider {
        static var previews: some View {
            let state = ChoosePluginsState()
            return VStack {
                ChoosePluginsBody(state: state).frame(height: 460)
                HStack {
                    ChoosePluginsSecondary(onSkip: {})
                    Spacer()
                    ChoosePluginsCTA(state: state, onComplete: {})
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 640)
        }
    }
#endif
