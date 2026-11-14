import Foundation
import MLXLMCommon

/// A polling task must never keep the previous chat's identity or an old
/// streaming/alert gate after SwiftUI updates the input card.
struct SSDQuotaNoticePollContext: Equatable {
    let model: String?
    let session: UUID?
    let eligible: Bool
    var cacheSettings: VMLXServerCacheSettings = .init()
}

/// A cache root's measured usage and capacity loss, including linked recurrent
/// payloads. Resident models report the enforced quota; idle roots resolve the
/// saved policy while retaining confirmed per-chat pressure metadata.
struct DiskCacheQuotaSnapshot: Sendable {
    let directory: URL
    let usage: DiskCacheUsage

    /// One notice per (cache folder, chat) per launch, even if later turns
    /// produce more oversized snapshots.
}
