//
//  OnboardingChoosePluginsView.swift
//  osaurus
//
//  Onboarding step 6 — pick a few starter tools (browser, file access,
//  calendar, …) before landing in the walkthrough. The list is curated
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
    /// list renders in this order. Only entries that also exist in the
    /// remote catalog (`PluginRepositoryService.shared.plugins`) are
    /// surfaced; everything else is silently dropped.
    ///
    /// The browser is the only default-on pick so the first-run agent can
    /// do something useful out of the box without pre-enabling tools that
    /// need extra system permissions (Calendar, Messages, …).
    ///
    /// Note: there is intentionally no "macOS Use" pick here. Controlling
    /// Mac apps by clicking/typing is now a CORE Osaurus capability (the
    /// Computer Use harness), enabled per-agent and configured in its own
    /// Settings tab — not installed as a standalone plugin.
    static let curated: [OnboardingPluginPick] = [
        OnboardingPluginPick(
            pluginId: "osaurus.browser",
            displayName: "Browser",
            blurb: "Open pages and pull text from the web.",
            icon: "safari.fill",
            isDefaultOn: true
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
    /// but not yet installed). Drives the CTA between "Install N Tools" and,
    /// when empty, "Skip".
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
            leftHeadline: "Pick what your dino can do",
            leftBody:
                "Tools are little powers your dino can use, like reading the web or grabbing a file. Add a couple now, swap them in and out any time from Settings.",
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
                pluginList(picks: picks)
                footnoteRow
            }
        }
    }

    /// Single-column list of full-width row cards — the same
    /// `OnboardingRowCard` rhythm the model and provider pickers use, so the
    /// step reads consistently with the earlier onboarding screens.
    private func pluginList(picks: [ChoosePluginsState.VisiblePick]) -> some View {
        VStack(spacing: OnboardingMetrics.cardSpacing) {
            ForEach(picks) { entry in
                pluginRow(entry)
            }
        }
    }

    private func pluginRow(_ entry: ChoosePluginsState.VisiblePick) -> some View {
        let pluginId = entry.pick.pluginId
        let installed = entry.state.isInstalled
        let installing = entry.state.isInstalling
        let selected = state.isSelected(pluginId)
        // Installed picks read as a passive "Installed" badge with no
        // checkbox (the disabled row hides the accessory), matching the
        // model picker's already-downloaded treatment.
        let badges: [OnboardingRowBadge] =
            installed ? [OnboardingRowBadge(L("Installed"), style: .success)] : []

        return OnboardingRowCard(
            icon: .symbol(entry.pick.icon),
            title: entry.pick.displayName,
            subtitle: entry.pick.blurb,
            badges: badges,
            accessory: .checkbox(isSelected: selected),
            isSelected: selected,
            isDisabled: installed || installing
        ) {
            state.toggle(pluginId)
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

// MARK: - CTA

/// Single adaptive CTA: installs the ticked picks, or — when nothing is
/// selected — turns into "Skip" so the step needs only one centered control
/// instead of a separate skip link. The skip path still fires the same
/// `stepSkipped` telemetry via `onSkip`.
struct ChoosePluginsCTA: View {
    @ObservedObject var state: ChoosePluginsState
    let onComplete: () -> Void
    let onSkip: () -> Void

    var body: some View {
        let willInstall = state.idsToInstall
        let isSkip = willInstall.isEmpty
        let title: String =
            isSkip
            ? L("Skip")
            : (willInstall.count == 1 ? L("Install 1 Tool") : L("Install \(willInstall.count) Tools"))

        return OnboardingBrandButton(title: title) {
            if isSkip {
                onSkip()
            } else {
                state.installAndAdvance(onComplete: onComplete)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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
                    Spacer()
                    ChoosePluginsCTA(state: state, onComplete: {}, onSkip: {})
                    Spacer()
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 640)
        }
    }
#endif
