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

    /// True once `awaitReady` has resolved at least once. Cheap to
    /// poll — synchronous gates use this as a fast-path.
    @Published public private(set) var isReady: Bool = false

    /// Set by `StorageExportService.rotateStorageKey` while it is
    /// actively re-encrypting databases. While true, every gate
    /// (`awaitReady`, `blockingAwaitReady`) blocks new callers so
    /// they don't race a half-rotated key.
    @Published public private(set) var isMutating: Bool = false

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

    /// Synchronous gate for callers that can't go async (HTTP
    /// request handlers reaching for `ChatHistoryDatabase.shared`,
    /// `ChatSessionStore`, etc.). Blocks the calling thread until
    /// `awaitReady` resolves.
    ///
    /// On the main thread, spins the default run-loop mode so the
    /// migration overlay keeps painting + the user can still move
    /// the panel around. Off the main thread, just blocks on a
    /// semaphore.
    ///
    /// Exposed as a `nonisolated` static so non-main callsites can
    /// invoke it without first hopping onto the main actor to read
    /// `.shared` (which would itself require an `await`).
    nonisolated public static func blockingAwaitReady() {
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            if shared.isReady {
                semaphore.signal()
                return
            }
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
        let view = StorageMigrationOverlay(coordinator: self)
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: 460, height: 240)

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

    public init(coordinator: StorageMigrationCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            theme.primaryBackground.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(theme.accentColor)

                Text("Securing your data")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                Text(stepText)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .frame(width: 280)

                if let lastError = coordinator.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.primaryBackground)
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            )
            .padding(40)
        }
        .transition(.opacity)
    }

    private var stepText: String {
        coordinator.progress?.stepLabel ?? "Preparing"
    }

    private var ratio: Double {
        guard let p = coordinator.progress, p.total > 0 else { return 0 }
        return min(1, max(0, Double(p.completed) / Double(p.total)))
    }
}
