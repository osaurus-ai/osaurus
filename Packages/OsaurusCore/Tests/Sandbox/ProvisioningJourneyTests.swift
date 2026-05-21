//
//  ProvisioningJourneyTests.swift
//  OsaurusCoreTests
//
//  Covers the structured provisioning journey added to drive the
//  real-time UI in SandboxView:
//
//  * `SandboxConfiguration.lastBootDurations` round-trips correctly
//    (and is tolerant of the field being absent on legacy installs).
//  * The pure byte / rate / ETA formatters used by the journey row
//    behave correctly across the obvious edge cases (no rate yet,
//    zero total, sub-second / sub-minute / multi-minute ETAs).
//  * `ProvisioningJourney.remainingTotalSeconds` aggregates step
//    ETAs the way the UI's "≈ remaining" pill expects, including
//    the no-data → `nil` fallthrough.
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite("Provisioning Journey")
    struct ProvisioningJourneyTests {

        // MARK: - SandboxConfiguration coding

        @Test
        func decode_missingLastBootDurations_yieldsNil() throws {
            // Drop everything new added after 0.x so we exercise the
            // `decodeIfPresent` path. The verifier earlier than the
            // journey work simply doesn't have `lastBootDurations` in
            // the on-disk JSON; we must not crash decoding it.
            let json = """
                {
                  "cpus": 2,
                  "memoryGB": 4,
                  "network": "outbound",
                  "autoStart": true
                }
                """
            let data = Data(json.utf8)
            let config = try JSONDecoder().decode(SandboxConfiguration.self, from: data)
            #expect(config.cpus == 2)
            #expect(config.memoryGB == 4)
            #expect(config.lastBootDurations == nil)
        }

        @Test
        func encode_then_decode_lastBootDurations_preservesValues() throws {
            let original = SandboxConfiguration(
                cpus: 4,
                memoryGB: 8,
                network: "outbound",
                autoStart: false,
                setupComplete: true,
                lastProvisionedAppVersion: "1.2.3",
                lastBootDurations: [
                    ProvisioningStepID.configureSandbox.rawValue: 2.5,
                    ProvisioningStepID.startContainer.rawValue: 4.0,
                ]
            )

            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SandboxConfiguration.self, from: data)
            #expect(decoded == original)
            #expect(decoded.lastBootDurations?[ProvisioningStepID.configureSandbox.rawValue] == 2.5)
            #expect(decoded.lastBootDurations?[ProvisioningStepID.startContainer.rawValue] == 4.0)
        }

        // MARK: - Byte / rate / ETA formatting

        @Test
        func formatBytes_picksTheRightUnit() {
            #expect(SandboxManager.formatBytes(0) == "0 B")
            #expect(SandboxManager.formatBytes(512) == "512 B")
            #expect(SandboxManager.formatBytes(2 * 1024) == "2.0 KB")
            #expect(SandboxManager.formatBytes(5 * 1024 * 1024) == "5.0 MB")
            #expect(SandboxManager.formatBytes(3 * 1024 * 1024 * 1024) == "3.0 GB")
        }

        @Test
        func formatByteActivity_includesRate_whenAvailable() {
            let line = SandboxManager.formatByteActivity(
                bytes: 45 * 1024 * 1024,
                total: 98 * 1024 * 1024,
                bytesPerSecond: Double(8 * 1024 * 1024)
            )
            #expect(line.contains("45.0 MB"))
            #expect(line.contains("98.0 MB"))
            #expect(line.contains("8.0 MB/s"))
            #expect(line.contains("·"))
        }

        @Test
        func formatByteActivity_omitsRate_whenStillWarmingUp() {
            // The applyByteProgress helper defers writing
            // `bytesPerSecond` until ~250 ms of samples are in, so
            // every first event renders without the "·" separator.
            let line = SandboxManager.formatByteActivity(
                bytes: 1 * 1024 * 1024,
                total: 10 * 1024 * 1024,
                bytesPerSecond: nil
            )
            #expect(line == "1.0 MB / 10.0 MB")
            #expect(!line.contains("/s"))
        }

        @Test
        func formatEta_humanReadable() {
            #expect(ProvisioningJourneyView.formatEta(0) == "<1s")
            #expect(ProvisioningJourneyView.formatEta(0.4) == "<1s")
            #expect(ProvisioningJourneyView.formatEta(8) == "8s")
            #expect(ProvisioningJourneyView.formatEta(45) == "45s")
            #expect(ProvisioningJourneyView.formatEta(75) == "1m 15s")
            // ≥5 min drops seconds so the pill stays compact.
            #expect(ProvisioningJourneyView.formatEta(600) == "10m")
        }

        // MARK: - ProvisioningJourney aggregate ETA

        @Test
        func remainingTotalSeconds_sumsActiveAndPending() {
            let journey = ProvisioningJourney(
                steps: [
                    ProvisioningStepState(
                        id: .downloadKernel,
                        label: "k",
                        status: .completed,
                        etaSeconds: nil
                    ),
                    ProvisioningStepState(
                        id: .createContainer,
                        label: "c",
                        status: .inProgress,
                        etaSeconds: 12
                    ),
                    ProvisioningStepState(
                        id: .startContainer,
                        label: "s",
                        status: .pending,
                        etaSeconds: 4
                    ),
                    ProvisioningStepState(
                        id: .configureSandbox,
                        label: "x",
                        status: .pending,
                        etaSeconds: nil
                    ),
                ]
            )
            #expect(journey.remainingTotalSeconds == 16)
        }

        @Test
        func remainingTotalSeconds_isNil_whenNothingKnown() {
            let journey = ProvisioningJourney(
                steps: [
                    ProvisioningStepState(id: .downloadKernel, label: "k", status: .skipped),
                    ProvisioningStepState(id: .createContainer, label: "c", status: .pending),
                    ProvisioningStepState(id: .configureSandbox, label: "x", status: .pending),
                ]
            )
            // No ETAs at all → "—" in the UI, not a misleading "0s".
            #expect(journey.remainingTotalSeconds == nil)
        }

        @Test
        func remainingTotalSeconds_excludesTerminalStatuses() {
            let journey = ProvisioningJourney(
                steps: [
                    ProvisioningStepState(id: .downloadKernel, label: "k", status: .completed, etaSeconds: 99),
                    ProvisioningStepState(id: .extractKernel, label: "e", status: .skipped, etaSeconds: 99),
                    ProvisioningStepState(id: .startBridge, label: "b", status: .failed, etaSeconds: 99),
                    ProvisioningStepState(id: .startContainer, label: "s", status: .pending, etaSeconds: 7),
                ]
            )
            // Only the .pending step contributes; the completed /
            // skipped / failed entries are intentionally excluded.
            #expect(journey.remainingTotalSeconds == 7)
        }

        // MARK: - Rate / ETA math

        @Test
        func computeByteRateETA_returnsNil_whenSampleWindowTooShort() {
            // < 250 ms of samples is the formal "warming up" window; we
            // skip the rate so the UI doesn't show a wildly noisy
            // first-event-of-the-download estimate.
            let (rate, eta) = SandboxManager.computeByteRateETA(
                bytes: 1_000_000,
                total: 10_000_000,
                elapsed: 0.1
            )
            #expect(rate == nil)
            #expect(eta == nil)
        }

        @Test
        func computeByteRateETA_computesRateAndEta_midDownload() {
            // 5 MB streamed over 1 s → 5 MB/s. Total is 25 MB so 20 MB
            // remain → 4 s ETA. Direct arithmetic, no rounding fudge.
            let (rate, eta) = SandboxManager.computeByteRateETA(
                bytes: 5 * 1024 * 1024,
                total: 25 * 1024 * 1024,
                elapsed: 1.0
            )
            #expect(rate == Double(5 * 1024 * 1024))
            #expect(eta == 4.0)
        }

        @Test
        func computeByteRateETA_clampsEtaToZero_whenFullyDownloaded() {
            // The download delegate fires a final event at
            // bytes == total; we want ETA = 0, not "tiny positive".
            let (rate, eta) = SandboxManager.computeByteRateETA(
                bytes: 10 * 1024 * 1024,
                total: 10 * 1024 * 1024,
                elapsed: 2.0
            )
            #expect(rate ?? -1 > 0)
            #expect(eta == 0)
        }

        @Test
        func computeByteRateETA_keepsRate_dropsEta_whenTotalIsUnknown() {
            // Servers occasionally elide Content-Length; we still want
            // to show a rate so the user can see movement, but ETA has
            // to be "—".
            let (rate, eta) = SandboxManager.computeByteRateETA(
                bytes: 1024,
                total: 0,
                elapsed: 0.5
            )
            #expect(rate == Double(2048))
            #expect(eta == nil)
        }

        // MARK: - Legacy shim mapping

        @MainActor
        @Test
        func syncLegacyPhase_publishesActiveStep_intoProvisioningPhase() {
            let journey = ProvisioningJourney(
                steps: [
                    ProvisioningStepState(
                        id: .downloadKernel,
                        label: "Downloading Linux kernel",
                        status: .completed,
                        progress: 1.0
                    ),
                    ProvisioningStepState(
                        id: .createContainer,
                        label: "Pulling sandbox image",
                        status: .inProgress,
                        progress: 0.42
                    ),
                ],
                currentStepID: .createContainer
            )
            SandboxManager.State.shared.provisioningPhase = nil
            SandboxManager.State.shared.provisioningProgress = nil
            SandboxManager.syncLegacyPhase(from: journey)

            #expect(SandboxManager.State.shared.provisioningPhase == "Pulling sandbox image…")
            #expect(SandboxManager.State.shared.provisioningProgress == 0.42)
        }

        @MainActor
        @Test
        func syncLegacyPhase_clearsLegacyFields_afterJourneyFinished() {
            let now = Date()
            let journey = ProvisioningJourney(
                steps: [
                    ProvisioningStepState(
                        id: .configureSandbox,
                        label: "Configuring sandbox",
                        status: .completed,
                        progress: 1.0,
                        startedAt: now.addingTimeInterval(-2),
                        finishedAt: now
                    )
                ],
                currentStepID: nil,
                startedAt: now.addingTimeInterval(-3),
                finishedAt: now
            )

            SandboxManager.State.shared.provisioningPhase = "stale"
            SandboxManager.State.shared.provisioningProgress = 0.99
            SandboxManager.syncLegacyPhase(from: journey)

            #expect(SandboxManager.State.shared.provisioningPhase == nil)
            #expect(SandboxManager.State.shared.provisioningProgress == nil)
        }

        // MARK: - Step state helpers

        @Test
        func elapsedSeconds_isZero_beforeStart() {
            let step = ProvisioningStepState(id: .downloadKernel, label: "k")
            #expect(step.elapsedSeconds == 0)
        }

        @Test
        func elapsedSeconds_usesFinishedAt_whenStopped() {
            let start = Date(timeIntervalSinceReferenceDate: 0)
            let end = start.addingTimeInterval(3.5)
            let step = ProvisioningStepState(
                id: .downloadKernel,
                label: "k",
                status: .completed,
                startedAt: start,
                finishedAt: end
            )
            // Use `> 3.49` instead of `==` to absorb floating-point
            // rounding from the formatter; we only care about ~3.5.
            #expect(abs(step.elapsedSeconds - 3.5) < 0.01)
        }
    }

#endif
