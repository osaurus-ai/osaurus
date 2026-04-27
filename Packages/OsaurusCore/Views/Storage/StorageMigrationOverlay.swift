//
//  StorageMigrationOverlay.swift
//  osaurus
//
//  "Securing your data" splash window shown by
//  `AppDelegate.applicationDidFinishLaunching` on first launch after
//  upgrade while `StorageMigrator` runs its one-shot at-rest
//  encryption pass.
//
//  The coordinator owns its own borderless `NSPanel` so we don't have
//  to retrofit a SwiftUI WindowGroup root for an event the user only
//  sees once per upgrade. The panel auto-dismisses when the migrator
//  resolves; failures are stored in `lastError` and surfaced by the
//  Storage settings panel.
//
//  ## Sequencing contract
//
//  Every database open path in the app **must** await
//  `awaitReady()` (async) or call `blockingAwaitReady()` (sync)
//  *before* invoking `*Database.shared.open()`. Without this gate,
//  SQLCipher tries to open a still-plaintext file with a key set,
//  the page-1 read fails, and the DB enters a degraded state.
//
//  Sync callers on the main thread are safe — `blockingAwaitReady`
//  spins the main run loop so SwiftUI updates and the overlay's
//  progress label keep refreshing.
//

import AppKit
import SwiftUI
import os

@MainActor
public final class StorageMigrationCoordinator: ObservableObject {
    public static let shared = StorageMigrationCoordinator()

    @Published public private(set) var isPresenting: Bool = false
    @Published public private(set) var progress: StorageMigrator.Progress?
    @Published public private(set) var lastError: String?

    /// True once `awaitReady` has resolved at least once. Mirrored
    /// to the lock-free `Self.isReadyAtomic` so the synchronous
    /// `blockingAwaitReady()` fast path can poll without hopping
    /// onto the main actor.
    @Published public private(set) var isReady: Bool = false {
        didSet { Self.isReadyAtomic.store(isReady) }
    }

    /// Set by `StorageExportService.rotateStorageKey` while it is
    /// actively re-encrypting databases. While true, every gate
    /// (`awaitReady`, `blockingAwaitReady`) blocks new callers so
    /// they don't race a half-rotated key.
    @Published public private(set) var isMutating: Bool = false {
        didSet { Self.isMutatingAtomic.store(isMutating) }
    }

    /// Cross-thread mirrors of `isReady` / `isMutating` for the
    /// `blockingAwaitReady` fast path. Reads happen from arbitrary
    /// threads (every `*Database.open()` hits the gate
    /// defensively); writes happen on the main actor via the
    /// `didSet` blocks above. The constants need to escape the
    /// `@MainActor` isolation of the enclosing class for the
    /// fast-path readers — `AtomicBool` is `Sendable` so plain
    /// `nonisolated` is sufficient (no `(unsafe)`).
    nonisolated private static let isReadyAtomic = AtomicBool(false)
    nonisolated private static let isMutatingAtomic = AtomicBool(false)

    private var panel: NSPanel?
    private var migrationTask: Task<Void, Never>?

    /// Continuations parked by `awaitReady` while `isMutating` is true.
    /// Drained by `endMutating()`.
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private let log = Logger(subsystem: "ai.osaurus", category: "storage.migration")

    private init() {}

    // MARK: - Public sequencing API

    /// Async gate: kicks off the migrator on first call (with the
    /// "Securing your data" overlay), then resolves when migration
    /// is complete. Idempotent — every subsequent caller awaits the
    /// same task. Also blocks while a key rotation is in flight.
    public func awaitReady() async {
        if isReady && !isMutating { return }

        if !isReady {
            if migrationTask == nil {
                migrationTask = Task { [weak self] in
                    await self?.runMigration()
                }
            }
            await migrationTask?.value
        }

        // Also park if we're mid-rotation. Storage operations
        // (`EncryptedSQLiteOpener.open`, `StorageKeyManager.currentKey`)
        // would otherwise observe a transitional state where the
        // Keychain key and the on-disk encryption don't agree.
        while isMutating {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                mutationWaiters.append(cont)
            }
        }
    }

    // MARK: - Mutation hooks (used by rotation)

    /// Called by `StorageExportService.rotateStorageKey` before it
    /// starts re-encrypting. Blocks every subsequent `awaitReady`
    /// caller until `endMutating()` runs.
    public func beginMutating() {
        isMutating = true
    }

    /// Companion to `beginMutating`. Wakes up everything parked in
    /// `awaitReady`.
    public func endMutating() {
        isMutating = false
        let waiters = mutationWaiters
        mutationWaiters.removeAll()
        for cont in waiters { cont.resume() }
    }

    /// **Test-only.** Force the coordinator into the post-migration
    /// "ready" state without running the real migrator.
    ///
    /// Why this exists: every call to `awaitReady()` on the real
    /// `.shared` singleton triggers `runMigration()`, which:
    ///   - reads `~/.osaurus/.storage-version` (the *real* path, not
    ///     a tempdir — the coordinator predates `OsaurusPaths.overrideRoot`),
    ///   - calls `showPanel()` → `NSHostingController` + `NSPanel.makeKeyAndOrderFront`,
    ///   - hits Keychain via `StorageKeyManager.currentKey()`,
    ///   - walks the real filesystem under `~/.osaurus/Tools/` for
    ///     plugin DBs.
    ///
    /// On a CI runner none of those steps are safe: there's no
    /// display server for the panel, no interactive Keychain prompt
    /// path, and the runner's home directory shouldn't be mutated
    /// by a unit test. Tests that just want to exercise the
    /// `isReady` / `isMutating` gating contract should call this
    /// instead of the real `awaitReady()`.
    public func _setReadyForTesting() {
        migrationTask?.cancel()
        migrationTask = nil
        lastError = nil
        isReady = true
    }

    /// Synchronous gate for callers that can't go async (HTTP
    /// handlers, `*Database.open()` defensive paths, etc.). The
    /// fast path is **completely lock-free and main-actor-free**:
    /// we just read the atomic latches and return. This matters
    /// because the gate is called from every `*Database.open()`,
    /// which fires hundreds of times during launch on installs
    /// with many plugins. The previous implementation always
    /// scheduled a `Task @MainActor` to check `isReady`, then
    /// blocked the calling thread on a semaphore until that task
    /// drained — fine off-main, but a death-by-a-thousand-cuts
    /// stall on the main actor when the post-launch
    /// `PluginManager.loadAll()` had it tied up for several
    /// seconds and watched as the watchdog reported the main
    /// thread blocked.
    ///
    /// The slow path (only hit before the migrator has finished —
    /// realistically just the very first launch) still uses the
    /// semaphore + runloop spin so the migration overlay can
    /// paint and accept events while we wait.
    nonisolated public static func blockingAwaitReady() {
        if RuntimeEnvironment.isUnderTests {
            // Tests use isolated temporary databases and don't need the global
            // UI migration gate. Tests that specifically test the migrator
            // will call `StorageMigrator.shared.runIfNeeded()` directly.
            // Bypassing this prevents Swift Concurrency deadlocks when tests
            // run on the MainActor and hit the semaphore wait.
            return
        }

        // Fast path: lock-free atomic poll, no Task scheduling.
        if isReadyAtomic.load(), !isMutatingAtomic.load() {
            return
        }

        // Slow path: actually drive (or wait for) the migration.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await shared.awaitReady()
            semaphore.signal()
        }

        if Thread.isMainThread {
            while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            semaphore.wait()
        }
    }

    // MARK: - Migration

    private func runMigration() async {
        let needs = await StorageMigrator.shared.needsMigration()

        if !needs {
            // Fresh install (or already migrated). Make sure the
            // version stamp is on disk so we don't re-scan every
            // launch.
            await StorageMigrator.shared.stampCurrentVersionIfMissing()
            // Best-effort cleanup of any leftover backup directory
            // from a previous launch.
            await StorageMigrator.shared.cleanupBackupIfStale()
            isReady = true
            return
        }

        showPanel()
        isPresenting = true
        progress = StorageMigrator.Progress(stepLabel: "Preparing", completed: 0, total: 1)

        let result = await StorageMigrator.shared.runIfNeeded { [weak self] step in
            Task { @MainActor in
                self?.progress = step
            }
        }

        switch result {
        case .success:
            lastError = nil
            isReady = true
            log.info("storage migration: success")
        case .failure(let err):
            // Don't latch isReady=true on a hard failure. Reset the
            // task handle so the next `awaitReady` caller (e.g. the
            // user clicking Retry from Settings, or a relaunch
            // after a `keyUnavailable` error) re-attempts the
            // migration instead of being told everything's fine.
            lastError = err.localizedDescription
            isReady = false
            migrationTask = nil
            log.error("storage migration: \(err.localizedDescription) — will retry on next awaitReady")
        }

        // Hold the overlay briefly so the user perceives the success
        // moment instead of a flash. 350ms feels intentional but
        // doesn't drag.
        try? await Task.sleep(nanoseconds: 350_000_000)
        isPresenting = false
        dismissPanel()
    }

    private func showPanel() {
        guard panel == nil else { return }
        // Defense in depth for test runs that slipped past
        // `_setReadyForTesting`. Under XCTest we have no business
        // creating an `NSPanel` — no display server on CI, and even
        // local `swift test` shouldn't flash a "Securing your data"
        // window. The atomic `isReady` mirror still gets flipped by
        // `runMigration`, so the gate semantics stay correct. See
        // `RuntimeEnvironment.isUnderTests`.
        if RuntimeEnvironment.isUnderTests {
            log.info("Skipping StorageMigrationOverlay panel under XCTest")
            return
        }
        let view = StorageMigrationOverlay(coordinator: self)
        let host = NSHostingController(rootView: view)
        // Sized to fit the richer content: badged icon + title +
        // explainer + counted progress bar. SwiftUI then drives
        // its own intrinsic height; the panel is movable by
        // background drag so users can park it out of the way.
        host.view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)

        let panel = NSPanel(
            contentRect: host.view.frame,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = host
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

public struct StorageMigrationOverlay: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var coordinator: StorageMigrationCoordinator

    /// Drives the icon's gentle "breathing" while migration is
    /// running. Stops once `coordinator.isReady` flips true so the
    /// success state lands without competing animation.
    @State private var iconPulse: Bool = false

    // MARK: - Design tokens
    //
    // Centralised so the visual rhythm is auditable in one place
    // and tweaks don't require a hunt through layout code.

    private enum Layout {
        static let cardCornerRadius: CGFloat = 18
        static let errorCornerRadius: CGFloat = 8
        static let badgeSize: CGFloat = 84
        static let glyphSize: CGFloat = 36
        static let maxContentWidth: CGFloat = 380
        static let progressBarHeight: CGFloat = 6
        static let cardPadding: CGFloat = 28
        static let outerPadding: CGFloat = 24
        static let stackSpacing: CGFloat = 22
    }

    private enum Motion {
        static let pulseScaleRunning: ClosedRange<CGFloat> = 0.97 ... 1.03
        static let completeScale: CGFloat = 1.05
        static let pulsePeriod: Double = 2.0
        static let completeSpring: SwiftUI.Animation = .spring(response: 0.55, dampingFraction: 0.7)
        static let progressFill: SwiftUI.Animation = .easeInOut(duration: 0.35)
    }

    public init(coordinator: StorageMigrationCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            // Backdrop: a soft tint over the system blur so the
            // panel reads as a modal without becoming a hard slab.
            theme.primaryBackground.opacity(0.55).ignoresSafeArea()

            VStack(spacing: Layout.stackSpacing) {
                badgedIcon
                titleBlock
                progressBlock
                if let lastError = coordinator.lastError {
                    errorBlock(lastError)
                }
            }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground)
            .padding(Layout.outerPadding)
        }
        .onAppear { startIconPulse() }
        .transition(.opacity)
    }

    // MARK: - Layout pieces

    /// Circular badge with the lock-shield glyph. Uses the accent
    /// color at low opacity for the well + full opacity for the
    /// glyph itself, so the badge harmonises with whatever theme
    /// is active without us having to special-case dark/light.
    private var badgedIcon: some View {
        Circle()
            .fill(iconTint.opacity(0.12))
            .overlay(
                Circle().stroke(iconTint.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                Image(systemName: iconGlyph)
                    .font(.system(size: Layout.glyphSize, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .symbolRenderingMode(.hierarchical)
            )
            .frame(width: Layout.badgeSize, height: Layout.badgeSize)
            .scaleEffect(iconScale)
            .animation(Motion.completeSpring, value: isComplete)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(isComplete ? "All set" : "Securing your data")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(subtitleText)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Layout.maxContentWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Progress indicator with a step label on the left and a
    /// `current / total` counter on the right above a linear bar.
    /// When the migrator hasn't reported any progress yet (or
    /// during the success hold), the counter is omitted.
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(stepText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if let counterText {
                    Text(counterText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            progressBar
        }
        .frame(maxWidth: Layout.maxContentWidth)
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.tertiaryBackground)
            GeometryReader { proxy in
                Capsule()
                    .fill(isComplete ? theme.successColor : theme.accentColor)
                    .frame(width: max(Layout.progressBarHeight, proxy.size.width * ratio))
            }
        }
        .frame(height: Layout.progressBarHeight)
        .animation(Motion.progressFill, value: ratio)
        .animation(Motion.progressFill, value: isComplete)
    }

    private func errorBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.errorColor)
                .padding(.top, 2)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(theme.errorColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: Layout.maxContentWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.errorCornerRadius, style: .continuous)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.errorCornerRadius, style: .continuous)
                        .stroke(theme.errorColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .stroke(theme.cardBorder.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 28, y: 14)
    }

    // MARK: - Behaviour

    private func startIconPulse() {
        // Slow enough to read as "alive" without becoming
        // distracting. Disabled implicitly when the success state
        // takes over `iconScale`.
        withAnimation(.easeInOut(duration: Motion.pulsePeriod).repeatForever(autoreverses: true)) {
            iconPulse = true
        }
    }

    // MARK: - Derived state

    private var isComplete: Bool { coordinator.isReady }

    private var iconGlyph: String {
        isComplete ? "checkmark.shield.fill" : "lock.shield.fill"
    }

    private var iconTint: Color {
        isComplete ? theme.successColor : theme.accentColor
    }

    private var iconScale: CGFloat {
        if isComplete { return Motion.completeScale }
        return iconPulse ? Motion.pulseScaleRunning.upperBound : Motion.pulseScaleRunning.lowerBound
    }

    /// One-line explainer under the title — frames the migration
    /// in plain language so users know why they're staring at a
    /// progress bar.
    private var subtitleText: String {
        if let lastError = coordinator.lastError, !lastError.isEmpty {
            return "We hit a problem and will retry next launch — your data isn't lost."
        }
        if isComplete {
            return "Your data is encrypted at rest with AES-256."
        }
        return "First-time setup encrypts your chats, memory, and configuration with AES-256. This only happens once."
    }

    private var stepText: String {
        if isComplete { return "Done" }
        return coordinator.progress?.stepLabel ?? "Preparing…"
    }

    /// `nil` when there's nothing meaningful to count (no progress
    /// reported yet, or migration finished). Otherwise renders as
    /// `current / total` aligned to the right of the step label.
    private var counterText: String? {
        guard !isComplete, let p = coordinator.progress, p.total > 0 else { return nil }
        return "\(min(p.completed, p.total)) of \(p.total)"
    }

    private var ratio: Double {
        if isComplete { return 1 }
        guard let p = coordinator.progress, p.total > 0 else { return 0 }
        return min(1, max(0, Double(p.completed) / Double(p.total)))
    }
}
