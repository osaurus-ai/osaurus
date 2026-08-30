//
//  WhatsAppWatchTransportRuntime.swift
//  osaurus
//
//  Watch-based WhatsApp receive transport. Holds one long-lived
//  `watch.subscribe` session against the `osaurus-wa` helper (whatsmeow
//  WhatsApp Web bridge) and feeds events through the WhatsApp connection
//  service's authorization + relay pipeline. The stream is live-only —
//  WAMID dedupe (connection_id + provider_event_id) makes helper restarts
//  harmless for redelivered rows.
//

import Foundation

actor WhatsAppWatchTransportRuntime: AgentChannelReceiveTransportRuntime {
    static let transportId = "whatsapp_watch"

    private let service: WhatsAppConnectionService
    private let healthCenter: AgentChannelTransportHealthCenter
    private let sleeper: any AgentChannelTransportSleeping
    private let backoffPolicy: AgentChannelTransportBackoffPolicy
    private var worker: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(
        service: WhatsAppConnectionService = .shared,
        healthCenter: AgentChannelTransportHealthCenter = .shared,
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper(),
        backoffPolicy: AgentChannelTransportBackoffPolicy = AgentChannelTransportBackoffPolicy(
            initialDelay: 5,
            multiplier: 2,
            maxDelay: 300
        )
    ) {
        self.service = service
        self.healthCenter = healthCenter
        self.sleeper = sleeper
        self.backoffPolicy = backoffPolicy
    }

    /// `pollInterval` is required by the transport-runtime protocol but
    /// unused: the watch session is push-based, and between-session pacing
    /// comes from the backoff policy.
    func start(pollInterval: TimeInterval = 5) async {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.runStep()
                if Task.isCancelled { break }
                let delay = max(result.retryDelay ?? 5, 1)
                do {
                    try await self.sleeper.sleep(for: delay)
                } catch {
                    break
                }
            }
        }
    }

    func stop(now: Date = Date()) async {
        worker?.cancel()
        worker = nil
        consecutiveFailures = 0
        // Kill the helper child process so nothing keeps a WhatsApp Web
        // socket open after receive is disabled or the app exits.
        await service.shutdownTransport()
        await healthCenter.update(
            AgentChannelTransportHealthState(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: .disabled,
                severity: .info,
                summary: "WhatsApp receive is stopped.",
                isRunning: false,
                receiveEnabled: false,
                updatedAt: now
            )
        )
    }

    /// One supervision cycle: preflight the helper and the linked session,
    /// then hold a live watch session until it ends.
    @discardableResult
    func runStep(now: Date = Date()) async -> AgentChannelTransportStepResult {
        guard service.helperAvailable() else {
            consecutiveFailures = 0
            let health = AgentChannelTransportHealthState(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: .failed,
                severity: .error,
                summary: "The WhatsApp helper is missing or failed verification.",
                isRunning: worker != nil,
                receiveEnabled: false,
                lastFailureAt: now,
                updatedAt: now
            )
            await healthCenter.update(health)
            // The helper won't appear mid-session; back off hard.
            return AgentChannelTransportStepResult(
                disposition: .failed,
                health: health,
                retryDelay: 300
            )
        }
        let linkStatus = await service.probeAndCacheLinkStatus()
        guard linkStatus.linked else {
            consecutiveFailures = 0
            let health = AgentChannelTransportHealthState(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: .degraded,
                severity: .warning,
                summary: "WhatsApp receive is waiting for a linked account.",
                detail: "Open WhatsApp settings and scan the QR code with your phone (WhatsApp > Settings > Linked Devices).",
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
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: .idle,
                severity: .info,
                summary: "WhatsApp receive is stopped.",
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
            let reason = WhatsAppRPCSecurity.redact(error.localizedDescription)
            let health = AgentChannelTransportHealthState(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: consecutiveFailures >= 3 ? .failed : .degraded,
                severity: consecutiveFailures >= 3 ? .error : .warning,
                summary: reason.isEmpty
                    ? "The WhatsApp receive stream was interrupted; reconnecting."
                    : reason,
                detail: "Osaurus restarts the helper and resubscribes automatically (attempt \(consecutiveFailures)). If the account was unlinked, re-scan the QR code in WhatsApp settings.",
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
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: .healthy,
                severity: .info,
                summary: "WhatsApp receive is listening for new messages.",
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
        let dropped = service.watchDroppedNonAllowlistedCount()
        await healthCenter.update(
            AgentChannelTransportHealthState(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .whatsapp,
                status: .healthy,
                severity: .info,
                summary: "WhatsApp receive is healthy.",
                detail: dropped > 0
                    ? "Ignored \(dropped) message\(dropped == 1 ? "" : "s") from chats outside the readable allowlist this session. If a test message is missing, add its chat to the readable list in WhatsApp settings."
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
