//
//  PeakMemorySampler.swift
//  OsaurusEvalsKit
//
//  Background peak-tracker over the process physical footprint. The
//  runner wraps each model-driven case with one of these so the report
//  records the case's peak RAM (Activity-Monitor "Memory"), the value
//  the AGENTS.md low-RAM gate is written against. Instantaneous reads
//  miss the spike during MLX prefill/decode, so we sample on a timer and
//  keep the max.
//

import Foundation
import OsaurusCore

/// Polls `ProcessMemoryProbe.currentPhysFootprintMB()` on a utility-queue
/// timer and remembers the maximum. Lock-guarded rather than an actor so
/// `stop()` is synchronous and the sampler keeps observing while the
/// main actor is blocked inside an MLX decode (the spike we care about).
final class PeakMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var peakMb: Double
    private var stopped = false

    private init(initial: Double, intervalMs: Int) {
        self.peakMb = initial
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs)
        )
        timer.setEventHandler { [weak self] in
            guard let self, let sample = ProcessMemoryProbe.currentPhysFootprintMB() else { return }
            self.lock.lock()
            if sample > self.peakMb { self.peakMb = sample }
            self.lock.unlock()
        }
        timer.resume()
    }

    /// Begin sampling immediately, seeded with the current footprint so a
    /// case shorter than one interval still reports a real value.
    static func start(intervalMs: Int = 100) -> PeakMemorySampler {
        PeakMemorySampler(
            initial: ProcessMemoryProbe.currentPhysFootprintMB() ?? 0,
            intervalMs: intervalMs
        )
    }

    /// Stop sampling and return the peak observed (MB), or nil when the
    /// probe never produced a positive reading.
    @discardableResult
    func stop() -> Double? {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let peak = peakMb
        lock.unlock()
        if !alreadyStopped { timer.cancel() }
        return peak > 0 ? peak : nil
    }
}
