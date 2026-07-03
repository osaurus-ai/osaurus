//
//  ResourceSampler.swift
//  OsaurusEvalsKit
//
//  Background resource tracker over the eval process. The runner wraps each
//  model/embedder-driven case with one of these so the report records the
//  case's peak RAM (Activity-Monitor "Memory", the value the AGENTS.md
//  low-RAM gate is written against) AND its CPU utilization. Instantaneous
//  reads miss the spike during MLX prefill/decode, so we sample on a timer
//  and keep the peak; CPU is a rate, so we diff cumulative CPU seconds over
//  wall-clock per tick (peak) and across the whole window (mean).
//
//  Supersedes the RAM-only `PeakMemorySampler`: one timer now covers both
//  signals so a case never pays for two pollers.
//

import Foundation
import OsaurusCore

/// One case's resource telemetry, as observed by the sampler. CPU is a
/// percentage of a single core, so it can exceed 100% when multiple cores
/// are busy (the harness, tokenizer, and Swift concurrency runtime all run
/// on CPU while MLX decode runs on the GPU). Fields are optional so a probe
/// that never produced a reading reads as "not measured", never a zero.
struct ResourceSample: Sendable {
    let peakPhysFootprintMb: Double?
    let meanCpuPercent: Double?
    let peakCpuPercent: Double?
}

/// Polls `ProcessMemoryProbe.currentPhysFootprintMB()` and
/// `ProcessCpuProbe.cumulativeCpuSeconds()` on a utility-queue timer.
/// Lock-guarded rather than an actor so `stop()` is synchronous and the
/// sampler keeps observing while the main actor is blocked inside an MLX
/// decode (the spike we care about).
final class ResourceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var stopped = false

    private var peakMb: Double

    // CPU utilization is a rate. `start*` anchor the window mean; `last*`
    // anchor each tick's instantaneous rate (whose max is the peak).
    private let startWall: TimeInterval
    private let startCpuSeconds: Double?
    private var lastWall: TimeInterval
    private var lastCpuSeconds: Double?
    private var endCpuSeconds: Double?
    private var peakCpuPercent: Double = 0

    private init(initialMb: Double, intervalMs: Int) {
        let now = Date().timeIntervalSinceReferenceDate
        let cpu = ProcessCpuProbe.cumulativeCpuSeconds()
        self.peakMb = initialMb
        self.startWall = now
        self.startCpuSeconds = cpu
        self.lastWall = now
        self.lastCpuSeconds = cpu
        self.endCpuSeconds = cpu
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    /// Instantaneous CPU rates are only trusted over a window at least this
    /// long. Under heavy system load the sampler thread can be preempted
    /// between reading the CPU clock and the wall clock, skewing one tick's
    /// anchors; the next tick then divides a real multi-core CPU delta by a
    /// near-zero wall delta (observed live: a 123,571% "peak" in the matrix).
    private static let minRateWindowSeconds: TimeInterval = 0.05

    /// Hard physical ceiling for an instantaneous per-process CPU reading:
    /// every core at 100%. Anything above it is read-skew, not load.
    private static let maxCpuPercent =
        Double(ProcessInfo.processInfo.activeProcessorCount) * 100.0

    private func tick() {
        let mb = ProcessMemoryProbe.currentPhysFootprintMB()
        let cpu = ProcessCpuProbe.cumulativeCpuSeconds()
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        if let mb, mb > peakMb { peakMb = mb }
        if let cpu, let prev = lastCpuSeconds {
            let dt = now - lastWall
            if dt >= Self.minRateWindowSeconds {
                let pct = min((cpu - prev) / dt * 100.0, Self.maxCpuPercent)
                if pct > peakCpuPercent { peakCpuPercent = pct }
            }
        }
        if let cpu {
            lastCpuSeconds = cpu
            endCpuSeconds = cpu
        }
        lastWall = now
        lock.unlock()
    }

    /// Begin sampling immediately, seeded with the current footprint so a
    /// case shorter than one interval still reports a real value.
    static func start(intervalMs: Int = 100) -> ResourceSampler {
        ResourceSampler(
            initialMb: ProcessMemoryProbe.currentPhysFootprintMB() ?? 0,
            intervalMs: intervalMs
        )
    }

    /// Stop sampling and return the observed peak RAM plus the window-mean
    /// and peak CPU utilization. Reads CPU once more at stop time so the mean
    /// covers the full window even for a case shorter than one tick.
    @discardableResult
    func stop() -> ResourceSample {
        let finalCpu = ProcessCpuProbe.cumulativeCpuSeconds()
        let finalWall = Date().timeIntervalSinceReferenceDate
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        if let finalCpu { endCpuSeconds = finalCpu }
        let peak = peakMb
        let startCpu = startCpuSeconds
        let endCpu = endCpuSeconds
        let elapsed = finalWall - startWall
        let peakCpu = peakCpuPercent
        lock.unlock()
        if !alreadyStopped { timer.cancel() }

        var meanCpu: Double?
        if let s = startCpu, let e = endCpu, elapsed > 0 {
            let m = (e - s) / elapsed * 100.0
            if m >= 0 { meanCpu = m }
        }
        return ResourceSample(
            peakPhysFootprintMb: peak > 0 ? peak : nil,
            meanCpuPercent: meanCpu,
            peakCpuPercent: peakCpu > 0 ? peakCpu : nil
        )
    }
}
