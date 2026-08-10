//
//  IMessageWatchTransportRuntime.swift
//  osaurus
//
//  Watch-based iMessage receive transport. Holds one long-lived
//  `watch.subscribe` session against the pinned `imsg` helper, resuming from
//  the persisted chat.db ROWID cursor after helper restarts so no messages
//  are lost, and feeds events through the iMessage connection service's
//  authorization + relay pipeline.
//

import Foundation

actor IMessageWatchTransportRuntime: AgentChannelReceiveTransportRuntime {
    static let transportId = "imessage_watch"

    private let service: IMessageConnectionService
    private let healthCenter: AgentChannelTransportHealthCenter
    private let sleeper: any AgentChannelTransportSleeping
    private let backoffPolicy: AgentChannelTransportBackoffPolicy
    private let fullDiskAccessGranted: @Sendable () async -> Bool
    private var worker: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(
        service: IMessageConnectionService = .shared,
        healthCenter: AgentChannelTransportHealthCenter = .shared,
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper(),
        backoffPolicy: AgentChannelTransportBackoffPolicy = AgentChannelTransportBackoffPolicy(
            initialDelay: 5,
            multiplier: 2,
            maxDelay: 300
        ),
        fullDiskAccessGranted: @escaping @Sendable () async -> Bool = {
            await SystemPermissionService.shared.cachedIsGranted(.disk)
        }
    ) {
        self.service = service
        self.healthCenter = healthCenter
        self.sleeper = sleeper
        self.backoffPolicy = backoffPolicy
        self.fullDiskAccessGranted = fullDiskAccessGranted
    }

    /// `pollInterval` is required by the transport-runtime protocol but
    /// unused here: between-session pacing re-reads the live configuration
    /// every cycle (`currentReconnectFloor`), so interval edits apply
    /// without a restart.
    func start(pollInterval: TimeInterval = 5) async {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.runStep()
                if Task.isCancelled { break }
                // The reconnect pacing re-reads configuration every cycle so
                // interval edits apply without an app restart.
                let delay = max(result.retryDelay ?? self.currentReconnectFloor(), 1)
                do {
                    try await self.sleeper.sleep(for: delay)
                } catch {
                    break
                }
            }
        }
    }

    /// Base delay between watch sessions when the previous one ended without
    /// a specific retry hint. Reads the live configuration so operator edits
    /// take effect on the next cycle.
    private nonisolated func currentReconnectFloor() -> TimeInterval {
        max(3, TimeInterval(service.configuration().pollIntervalSeconds))
    }

    func stop(now: Date = Date()) async {
        worker?.cancel()
        worker = nil
        consecutiveFailures = 0
        // Kill the helper child process so nothing keeps watching chat.db
        // after receive is disabled or the app exits.
        await service.shutdownTransport()
        await healthCenter.update(
            AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: .disabled,
                severity: .info,
                summary: "iMessage receive is stopped.",
                isRunning: false,
                receiveEnabled: false,
                updatedAt: now
            )
        )
    }

    /// One supervision cycle: preflight the helper and Full Disk Access,
    /// then hold a live watch session until it ends. Returns when the
    /// session dies (with a retry delay) or the runtime is stopped.
    @discardableResult
    func runStep(now: Date = Date()) async -> AgentChannelTransportStepResult {
        guard service.helperAvailable() else {
            consecutiveFailures = 0
            let health = AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: .failed,
                severity: .error,
                summary: "The iMessage helper is missing or failed verification.",
                isRunning: worker != nil,
                receiveEnabled: false,
                lastFailureAt: now,
                updatedAt: now
            )
            await healthCenter.update(health)
            // The helper won't appear mid-session; back off hard instead of
            // hammering verification.
            return AgentChannelTransportStepResult(
                disposition: .failed,
                health: health,
                retryDelay: 300
            )
        }
        guard await fullDiskAccessGranted() else {
            // `imsg rpc` opens chat.db at startup, so spawning it without
            // Full Disk Access can only fail (and may trigger permission
            // prompts). Wait for the grant instead.
            consecutiveFailures = 0
            let health = AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: .degraded,
                severity: .warning,
                summary: "iMessage receive is waiting for Full Disk Access.",
                detail: "Grant Full Disk Access to Osaurus in System Settings > Privacy & Security.",
                isRunning: worker != nil,
                receiveEnabled: false,
                lastFailureAt: now,
                nextRetryAt: now.addingTimeInterval(60),
                updatedAt: now
            )
            await healthCenter.update(health)
            return AgentChannelTransportStepResult(
                disposition: .skipped,
                health: health,
                retryDelay: 60
            )
        }
        do {
            try await service.runWatchSession(
                onReady: { [weak self] in
                    await self?.noteSessionReady()
                },
                onBatch: { [weak self] batch in
                    await self?.noteBatch(batch)
                }
            )
            // The session only returns normally when receive was stopped.
            let health = AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: .idle,
                severity: .info,
                summary: "iMessage receive is stopped.",
                isRunning: worker != nil,
                receiveEnabled: false,
                updatedAt: now
            )
            return AgentChannelTransportStepResult(disposition: .skipped, health: health)
        } catch {
            consecutiveFailures += 1
            let delay = backoffPolicy.delay(
                consecutiveFailures: consecutiveFailures,
                jitter: Double.random(in: 0 ... 1)
            )
            let failedAt = Date()
            // Carry the specific failure into the summary the health badge
            // shows — "helper exited", "watch stream failed: …" — instead of
            // a generic Retry label the user can't act on.
            let reason = IMessageRPCSecurity.redact(error.localizedDescription)
            let health = AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: consecutiveFailures >= 3 ? .failed : .degraded,
                severity: consecutiveFailures >= 3 ? .error : .warning,
                summary: reason.isEmpty
                    ? "The iMessage receive stream was interrupted; reconnecting."
                    : reason,
                detail: "Osaurus restarts the helper and resumes from the saved cursor automatically (attempt \(consecutiveFailures)).",
                isRunning: worker != nil,
                receiveEnabled: true,
                lastFailureAt: failedAt,
                nextRetryAt: failedAt.addingTimeInterval(delay),
                consecutiveFailures: consecutiveFailures,
                updatedAt: failedAt
            )
            await healthCenter.update(health)
            return AgentChannelTransportStepResult(
                disposition: .failed,
                health: health,
                retryDelay: delay
            )
        }
    }

    private func noteSessionReady() async {
        consecutiveFailures = 0
        let now = Date()
        await healthCenter.update(
            AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: .healthy,
                severity: .info,
                summary: "iMessage receive is listening for new messages.",
                isRunning: worker != nil,
                receiveEnabled: true,
                lastSuccessAt: now,
                updatedAt: now
            )
        )
    }

    private func noteBatch(_ batch: AgentChannelReceiveBatchSummary) async {
        consecutiveFailures = 0
        let now = Date()
        // A silent Verify usually means the test message came from a chat
        // outside the readable allowlist; the counter makes that visible
        // without recording other conversations into Activity.
        let dropped = service.watchDroppedNonAllowlistedCount()
        await healthCenter.update(
            AgentChannelTransportHealthState(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .imessage,
                status: .healthy,
                severity: .info,
                summary: "iMessage receive is healthy.",
                detail: dropped > 0
                    ? "Ignored \(dropped) message\(dropped == 1 ? "" : "s") from chats outside the readable allowlist this session. If a test message is missing, mark its chat as Read in iMessage settings."
                    : nil,
                isRunning: worker != nil,
                receiveEnabled: true,
                lastSuccessAt: now,
                lastReceivedCount: batch.received,
                lastStoredCount: batch.stored,
                dispatchAttemptedCount: batch.dispatchAttempted,
                dispatchSuppressedCount: batch.dispatchSuppressed,
                updatedAt: now
            )
        )
    }
}
