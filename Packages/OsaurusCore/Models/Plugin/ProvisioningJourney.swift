//
//  ProvisioningJourney.swift
//  osaurus
//
//  Structured, observable model of the sandbox provisioning lifecycle.
//  Drives the real-time UI in `SandboxView`: ordered step list, per-step
//  byte / rate progress, ETA seeded from the last successful boot, and
//  the live "now doing" activity line.
//
//  The legacy scalar fields on `SandboxManager.State`
//  (`provisioningPhase`, `provisioningProgress`, `isProvisioning`) are
//  still published in lock-step so existing observers (chat UI booting
//  badge, native block views) keep working unchanged.
//

import Foundation

#if os(macOS)

    /// Stable identifiers for each phase the sandbox can go through while
    /// coming up. Used both as the SwiftUI list key and as the lookup key
    /// for the per-step historical-duration map persisted in
    /// `SandboxConfiguration.lastBootDurations`.
    public enum ProvisioningStepID: String, Codable, Sendable, CaseIterable {
        /// Download the Kata kernel tarball (cold path only).
        case downloadKernel
        /// Download the initfs blob (cold path only).
        case downloadInitFS
        /// Untar + locate the kernel binary on disk.
        case extractKernel
        /// `ContainerManager.create` — image pull + EXT4 rootfs unpack.
        case createContainer
        /// Bring up the host-side NIO bridge socket. Runs concurrently
        /// with `createContainer` but reported as its own step so the
        /// user sees the parallelism on the cold path.
        case startBridge
        /// `container.create` + `container.start` — the actual VM boot.
        case startContainer
        /// Post-boot in-guest setup (shim copy, token dir).
        case configureSandbox
        /// Post-boot batched dependency install + per-plugin verify pass.
        /// Lives in the journey so the dashboard can keep telling the
        /// user "your plugins are coming back" even after `isProvisioning`
        /// flips to false.
        case verifyPlugins
    }

    /// Lifecycle of a single journey step. `.skipped` means the work was
    /// short-circuited (e.g. kernel already cached on disk) and the UI
    /// should show a checkmark immediately without a misleading progress
    /// bar.
    public enum ProvisioningStepStatus: String, Codable, Sendable, Equatable {
        case pending
        case inProgress
        case completed
        case failed
        case skipped
    }

    /// Live state for one step inside `ProvisioningJourney.steps`.
    /// Equatable so SwiftUI can diff cheaply when the actor publishes a
    /// new copy of the parent journey.
    public struct ProvisioningStepState: Identifiable, Equatable, Sendable {
        public let id: ProvisioningStepID
        public var label: String
        public var status: ProvisioningStepStatus

        /// Normalised 0...1 progress when meaningful. `nil` means
        /// "indeterminate" — the view should fall back to a spinner.
        public var progress: Double?

        /// Byte counters for download / unpack steps. `nil` for steps
        /// whose work isn't measured in bytes.
        public var bytesProcessed: Int64?
        public var bytesTotal: Int64?

        /// Observed throughput in bytes/second when available. Drives the
        /// "8.2 MB/s" suffix on the active step row.
        public var bytesPerSecond: Double?

        public var startedAt: Date?
        public var finishedAt: Date?

        /// Best-effort seconds remaining. Either rate-derived (downloads
        /// / unpack) or seeded from `SandboxConfiguration.lastBootDurations`
        /// for steps whose work is inherently indeterminate.
        public var etaSeconds: Double?

        /// One-line "what is the guest actually doing right now". Set by
        /// the per-step driver (e.g. "Unpacking layer abc...").
        public var detail: String?

        public init(
            id: ProvisioningStepID,
            label: String,
            status: ProvisioningStepStatus = .pending,
            progress: Double? = nil,
            bytesProcessed: Int64? = nil,
            bytesTotal: Int64? = nil,
            bytesPerSecond: Double? = nil,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            etaSeconds: Double? = nil,
            detail: String? = nil
        ) {
            self.id = id
            self.label = label
            self.status = status
            self.progress = progress
            self.bytesProcessed = bytesProcessed
            self.bytesTotal = bytesTotal
            self.bytesPerSecond = bytesPerSecond
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.etaSeconds = etaSeconds
            self.detail = detail
        }

        /// Elapsed seconds since this step's `startedAt`, or 0 if not yet
        /// started. Used by the row footer and the rate / ETA math.
        public var elapsedSeconds: Double {
            guard let start = startedAt else { return 0 }
            let end = finishedAt ?? Date()
            return max(0, end.timeIntervalSince(start))
        }
    }

    /// Snapshot of the whole provisioning lifecycle. Published once via
    /// `SandboxManager.State.journey` and replaced on every mutation;
    /// each in-place update inside `SandboxManager` rebuilds the array
    /// so SwiftUI's `Equatable` diff sees a fresh value.
    public struct ProvisioningJourney: Equatable, Sendable {
        public var steps: [ProvisioningStepState]
        public var currentStepID: ProvisioningStepID?
        public var startedAt: Date?
        public var finishedAt: Date?
        public var failed: Bool

        public init(
            steps: [ProvisioningStepState] = [],
            currentStepID: ProvisioningStepID? = nil,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            failed: Bool = false
        ) {
            self.steps = steps
            self.currentStepID = currentStepID
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.failed = failed
        }

        public func step(_ id: ProvisioningStepID) -> ProvisioningStepState? {
            steps.first { $0.id == id }
        }

        /// Total elapsed time since the journey began.
        public var elapsedSeconds: Double {
            guard let start = startedAt else { return 0 }
            let end = finishedAt ?? Date()
            return max(0, end.timeIntervalSince(start))
        }

        /// Sum of remaining-step ETAs. For the active step we use its
        /// live `etaSeconds`; for pending steps we fall back to the
        /// per-step `etaSeconds` seed (populated by `beginJourney` from
        /// the persisted `lastBootDurations`). Returns `nil` if there are
        /// no remaining ETAs to sum, so callers can show "—" rather than
        /// a misleading "0s".
        public var remainingTotalSeconds: Double? {
            var total: Double = 0
            var anyHit = false
            for step in steps {
                switch step.status {
                case .completed, .skipped, .failed:
                    continue
                case .inProgress, .pending:
                    if let eta = step.etaSeconds {
                        total += eta
                        anyHit = true
                    }
                }
            }
            return anyHit ? total : nil
        }
    }

#endif
