import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ModelMemoryTelemetryTests {
    private func sample(
        id: UUID = UUID(),
        severity: SwapPressureMonitor.Severity = .none,
        phase: SwapPressureMonitor.Phase = .resident,
        emulated: Bool = false
    ) -> SwapPressureMonitor.State {
        .init(
            severity: severity,
            phase: phase,
            modelName: "/private/user/custom-model",
            baselineUsedBytes: 1 << 30,
            swapUsedBytes: 5 << 30,
            swapTotalBytes: 8 << 30,
            growthSinceBaselineBytes: 4 << 30,
            peakGrowthBytes: 4 << 30,
            episodeElapsedSeconds: 23,
            processFootprintBytes: 6 << 30,
            swapinsPerSecond: 240,
            decompressionsPerSecond: 24_000,
            emulated: emulated,
            episodeID: id
        )
    }

    @Test func repeatedTicksAreDeduplicatedAndEpisodeEventsAreBounded() {
        var limiter = ModelMemoryTelemetryLimiter()
        let id = UUID()
        let firstLoad = limiter.shouldRecord(sample(id: id, phase: .loading))
        let repeatedLoad = limiter.shouldRecord(sample(id: id, phase: .loading))
        let firstResident = limiter.shouldRecord(sample(id: id))
        let repeatedResident = limiter.shouldRecord(sample(id: id))
        #expect(firstLoad)
        #expect(!repeatedLoad)
        #expect(firstResident)
        #expect(!repeatedResident)
        var count = 2
        for i in 0 ..< 100 {
            if limiter.shouldRecord(sample(id: id, severity: i.isMultiple(of: 2) ? .critical : .none)) {
                count += 1
            }
        }
        #expect(count == ModelMemoryTelemetryLimiter.maximumEventsPerEpisode)
        let nextEpisode = limiter.shouldRecord(sample())
        let quiet = limiter.shouldRecord(.quiet)
        let emulated = limiter.shouldRecord(sample(emulated: true))
        #expect(nextEpisode)
        #expect(!quiet)
        #expect(!emulated)
    }

    @Test func samplesStayConsentGatedAndContainOnlyDocumentedBuckets() {
        let suite = "memory-telemetry-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [(String, [String: Any])] = []
        let service = TelemetryService(
            defaults: defaults,
            emit: { name, props in
                events.append((name, props.mapValues { $0 as Any }))
            }
        )
        service.markStartedForTesting()
        service.setEnabled(false)
        FeatureTelemetry.modelMemorySample(sample(), service: service)
        #expect(events.isEmpty)
        service.setEnabled(true)
        FeatureTelemetry.modelMemorySample(sample(severity: .critical), service: service)
        #expect(events.count == 1)
        let props = events[0].1
        #expect(events[0].0 == "model_memory_sample")
        #expect(
            Set(props.keys)
                == Set([
                    "phase", "severity", "host_swap_gib", "peak_swap_growth_gib", "process_footprint_gib",
                    "host_swapins_pages_s", "host_decompressions_pages_s", "total_memory_gb",
                ])
        )
        #expect(props["process_footprint_gib"] as? String == "4-16")
        #expect(props["host_swapins_pages_s"] as? String == "100-1000")
        #expect(props["host_decompressions_pages_s"] as? String == "10000-100000")
        FeatureTelemetry.modelMemorySample(sample(emulated: true), service: service)
        FeatureTelemetry.modelMemorySample(.quiet, service: service)
        #expect(events.count == 1)
        service.setEnabled(false)
        FeatureTelemetry.modelMemorySample(sample(), service: service)
        #expect(events.count == 1)
    }

    @Test func bucketBoundariesAndMissingRates() {
        #expect(ModelMemoryTelemetryBuckets.bytes(0) == "0")
        #expect(ModelMemoryTelemetryBuckets.bytes((1 << 30) - 1) == "<1")
        #expect(ModelMemoryTelemetryBuckets.bytes(1 << 30) == "1-4")
        #expect(ModelMemoryTelemetryBuckets.bytes(64 << 30) == "64+")
        #expect(ModelMemoryTelemetryBuckets.rate(0) == "0")
        #expect(ModelMemoryTelemetryBuckets.rate(.nan) == "unknown")
        #expect(ModelMemoryTelemetryBuckets.rate(-1) == "unknown")
    }
}
