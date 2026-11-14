import Foundation

/// One initial observation and bounded phase/severity transitions per residency
/// episode. No polling event flood, no model identifiers and no synthetic data.
struct ModelMemoryTelemetryLimiter {
    private var episodeID: UUID?
    private var phase: SwapPressureMonitor.Phase?
    private var severity: SwapPressureMonitor.Severity?
    private var count = 0
    static let maximumEventsPerEpisode = 8

    mutating func shouldRecord(_ state: SwapPressureMonitor.State) -> Bool {
        guard !state.emulated, state.phase != .idle, let id = state.episodeID else { return false }
        if episodeID != id {
            episodeID = id
            phase = nil
            severity = nil
            count = 0
        }
        guard count < Self.maximumEventsPerEpisode,
            phase != state.phase || severity != state.severity
        else { return false }
        phase = state.phase
        severity = state.severity
        count += 1
        return true
    }
}

enum ModelMemoryTelemetryBuckets {
    static func bytes(_ value: UInt64) -> String {
        switch value {
        case 0: "0"
        case ..<(1 << 30): "<1"
        case ..<(4 << 30): "1-4"
        case ..<(16 << 30): "4-16"
        case ..<(64 << 30): "16-64"
        default: "64+"
        }
    }

    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "unknown" }
        switch value {
        case 0: return "0"
        case ..<100: return "<100"
        case ..<1_000: return "100-1000"
        case ..<10_000: return "1000-10000"
        case ..<100_000: return "10000-100000"
        default: return "100000+"
        }
    }
}
