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
    func key(session: String) -> Key {
        Key(directory: directory.standardizedFileURL.path, session: session)
    }

    struct Key: Hashable, Sendable {
        let directory: String
        let session: String
    }
}

struct DiskCacheQuotaNoticePolicy {
    private var presented: Set<DiskCacheQuotaSnapshot.Key> = []
    private var active: [DiskCacheQuotaSnapshot.Key: DiskCacheQuotaSnapshot] = [:]

    /// A claimed notice remains the same notice when a chat view is recreated
    /// or the user visits another chat. A confirmed resolution retires it;
    /// later pressure does not nag again during this app launch.
    mutating func presentation(
        for snapshot: DiskCacheQuotaSnapshot, session: String
    ) -> DiskCacheQuotaSnapshot? {
        let key = snapshot.key(session: session)
        guard !snapshot.usage.isDisabled, snapshot.usage.maxBytes > 0,
            snapshot.usage.pressureAffects(session: session)
        else {
            active.removeValue(forKey: key)
            return nil
        }
        guard active[key] != nil || claim(snapshot, session: session) else { return nil }
        active[key] = snapshot
        return snapshot
    }

    /// Quota enforcement can lower usage before the next sample. The event
    /// identifies an oversized snapshot independently of current fullness.
    /// Routine evictions and trims do not consume the chat's notice.
    mutating func claim(_ snapshot: DiskCacheQuotaSnapshot, session: String?) -> Bool {
        let usage = snapshot.usage
        guard let session, !usage.isDisabled, usage.maxBytes > 0,
            usage.pressureAffects(session: session)
        else { return false }
        return presented.insert(snapshot.key(session: session)).inserted
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

    func presentation(
        for snapshot: DiskCacheQuotaSnapshot, session: String
    ) -> DiskCacheQuotaSnapshot? {
        guard !DiskCacheQuotaNoticeSuppression.isSuppressed() else { return nil }
        return policy.presentation(for: snapshot, session: session)
    }
}
