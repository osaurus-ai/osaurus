//
//  DiscordPollingTransportRuntime.swift
//  osaurus
//
//  Cursor-based Discord receive transport for allowlisted channels.
//

import Foundation

actor DiscordPollingTransportRuntime: AgentChannelReceiveTransportRuntime {
    static let transportId = "discord_polling"

    private let service: DiscordConnectionService
    private let healthCenter: AgentChannelTransportHealthCenter
    private let sleeper: any AgentChannelTransportSleeping
    private var worker: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(
        service: DiscordConnectionService = .shared,
        healthCenter: AgentChannelTransportHealthCenter = .shared,
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper()
    ) {
        self.service = service
        self.healthCenter = healthCenter
        self.sleeper = sleeper
    }

    func start(pollInterval: TimeInterval = 3) async {
        guard worker == nil else { return }
        let interval = max(2, pollInterval)
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await self.runStep()
                do {
                    try await self.sleeper.sleep(for: interval)
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
        await healthCenter.update(
            AgentChannelTransportHealthState(
                connectionId: DiscordConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .discord,
                status: .disabled,
                severity: .info,
                summary: "Discord polling is stopped.",
                isRunning: false,
                receiveEnabled: false,
                updatedAt: now
            )
        )
    }

    @discardableResult
    func runStep(now: Date = Date()) async -> AgentChannelTransportStepResult {
        do {
            let batch = try await service.pollInboundMessages()
            consecutiveFailures = 0
            let health = AgentChannelTransportHealthState(
                connectionId: DiscordConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .discord,
                status: .healthy,
                severity: .info,
                summary: "Discord polling is healthy.",
                isRunning: true,
                receiveEnabled: true,
                lastSuccessAt: now,
                lastReceivedCount: batch.received,
                lastStoredCount: batch.stored,
                dispatchAttemptedCount: batch.dispatchAttempted,
                dispatchSuppressedCount: batch.dispatchSuppressed,
                updatedAt: now
            )
            await healthCenter.update(health)
            return AgentChannelTransportStepResult(
                disposition: .succeeded,
                health: health,
                received: batch.received,
                stored: batch.stored,
                dispatchAttempted: batch.dispatchAttempted,
                dispatchSuppressed: batch.dispatchSuppressed
            )
        } catch {
            consecutiveFailures += 1
            let health = AgentChannelTransportHealthState(
                connectionId: DiscordConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .discord,
                status: consecutiveFailures >= 3 ? .failed : .degraded,
                severity: consecutiveFailures >= 3 ? .error : .warning,
                summary: "Discord polling failed.",
                detail: error.localizedDescription,
                isRunning: true,
                receiveEnabled: true,
                lastFailureAt: now,
                consecutiveFailures: consecutiveFailures,
                updatedAt: now
            )
            await healthCenter.update(health)
            return AgentChannelTransportStepResult(disposition: .failed, health: health)
        }
    }
}
