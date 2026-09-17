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

/// A resident coordinator's real directory and enforced quota, including linked
/// recurrent payloads. Never substitute a saved setting for an active quota.
struct DiskCacheQuotaSnapshot: Sendable {
    let directory: URL
    let usage: DiskCacheUsage

    var key: Key {
        Key(directory: directory.standardizedFileURL.path, maxBytes: usage.maxBytes)
    }

    struct Key: Hashable, Sendable {
        let directory: String
        let maxBytes: Int
    }
}

struct DiskCacheQuotaNoticePolicy {
    private var presented: Set<DiskCacheQuotaSnapshot.Key> = []

    /// One notice per root and effective limit per app launch. A janitor can
    /// lower usage before the next sample; actual quota evictions still count.
    mutating func claim(_ snapshot: DiskCacheQuotaSnapshot) -> Bool {
        let usage = snapshot.usage
        guard !usage.isDisabled, usage.maxBytes > 0,
            usage.usedBytes >= usage.maxBytes || usage.evictions > 0
        else { return false }
        return presented.insert(snapshot.key).inserted
    }
}

/// The user's "Don't show this again" choice, kept across launches in the same
/// UserDefaults store as the app's other skip-this-notice flags.
enum DiskCacheQuotaNoticeSuppression {
    static let defaultsKey = "ssdCacheQuotaNoticeSuppressed"

    static func isSuppressed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func suppress(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }
}

@MainActor
final class DiskCacheQuotaNotices {
    static let shared = DiskCacheQuotaNotices()
    private var policy = DiskCacheQuotaNoticePolicy()

    func claim(_ snapshot: DiskCacheQuotaSnapshot) -> Bool {
        guard !DiskCacheQuotaNoticeSuppression.isSuppressed() else { return false }
        return policy.claim(snapshot)
    }
}
