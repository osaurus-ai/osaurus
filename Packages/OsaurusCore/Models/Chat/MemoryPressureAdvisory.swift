//
//  MemoryPressureAdvisory.swift
//  osaurus
//
//  Turns a pair of `HostMemorySample`s into something a person can act on.
//
//  This ADVISES. It never refuses, never caps, never blocks a load. A guess
//  about memory must not become a wall between a user and their model — the
//  OS already fails loudly when something genuinely does not fit, and
//  predicting that badly is strictly worse than attempting the operation.
//
//  Threshold note, because the obvious choice is wrong:
//
//  Swap PERCENTAGE is not a usable trigger. macOS grows its swap files on
//  demand, so "% of provisioned swap in use" runs high on perfectly healthy
//  machines — a developer Mac with 78 GB free was sitting at 78% of its
//  provisioned swap while doing nothing at all. Keying the warning on that
//  would fire constantly on machines with no problem.
//
//  What actually separated the two cases, measured:
//
//                        struggling M3 Max        healthy Mac
//      free RAM          64 MB (14 MB low)        43.7 GB
//      decompressions    ~154,000 pages/s         ~5 pages/s
//      swap % used       97%                      78%   <- useless
//
//  So the trigger is the decompression RATE together with genuinely low free
//  memory. A high rate is the direct cost signal: every one of those pages is
//  being unpacked purely so it can be read, ~2.5 GB/s of work that produces
//  nothing. Requiring low free memory alongside it keeps a brief legitimate
//  burst — an app launching, a large file opening — from tripping the notice.
//

import Foundation

/// A non-blocking notice that the MACHINE, not the model, is the reason
/// generation is slow.
public struct MemoryPressureAdvisory: Equatable, Sendable {

    /// Sustained page-decompression rate at or above which reads are being
    /// paid for twice. Set well above idle noise (~5/s) and far below the
    /// ~154,000/s observed on the machine this was built from, so it catches
    /// the condition long before it becomes unusable.
    public static let severeDecompressionPagesPerSecond: Double = 20_000

    /// Free physical memory below which the machine has no headroom left.
    public static let lowFreeMemoryBytes: UInt64 = 1_073_741_824  // 1 GB

    public let freeBytes: UInt64
    public let swapUsedBytes: UInt64
    public let decompressionPagesPerSecond: Double

    public init(
        freeBytes: UInt64,
        swapUsedBytes: UInt64,
        decompressionPagesPerSecond: Double
    ) {
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.decompressionPagesPerSecond = max(0, decompressionPagesPerSecond)
    }

    /// Builds an advisory from two samples, or nil when the machine is fine.
    ///
    /// Nil is the overwhelmingly common answer and must stay cheap: a healthy
    /// Mac takes the first `guard` and does no further work.
    public static func evaluate(
        previous: HostMemorySample,
        current: HostMemorySample
    ) -> MemoryPressureAdvisory? {
        guard current.freeBytes < lowFreeMemoryBytes else { return nil }
        guard let rate = current.decompressionRate(since: previous),
            rate >= severeDecompressionPagesPerSecond
        else { return nil }

        return MemoryPressureAdvisory(
            freeBytes: current.freeBytes,
            swapUsedBytes: current.swapUsedBytes,
            decompressionPagesPerSecond: rate
        )
    }

    /// Bytes per second being spent unpacking compressed pages. This is the
    /// number that makes the problem legible — it is pure overhead.
    public var decompressionBytesPerSecond: Double {
        decompressionPagesPerSecond * Double(HostMemoryPressureProbe.pageSize)
    }

    /// Shown in the chat. Names the cause, says it is not the model, and gives
    /// one concrete action.
    ///
    /// Deliberately free of engine and kernel vocabulary. "Decompression rate"
    /// and "compressor" are precise for us and meaningless to someone watching
    /// a chat window crawl; what they can act on is that OTHER apps are using
    /// the memory and quitting some will make this fast again.
    public var warningText: String {
        "Your Mac is out of free memory, so this model is running far slower "
            + "than it should — this isn't the model itself. Other apps are "
            + "using the memory (\(freeLabel) free). Quitting memory-heavy apps "
            + "like Docker, browsers or chat apps will speed this up a lot."
    }

    /// Compact form for a status row where the full sentence will not fit.
    public var shortLabel: String { "Low memory — \(freeLabel) free" }

    public var freeLabel: String { Self.format(bytes: freeBytes) }
    public var swapLabel: String { Self.format(bytes: swapUsedBytes) }

    static func format(bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}
