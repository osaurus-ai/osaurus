//
//  ActivityLogSettings.swift
//  osaurus
//
//  Retention + content policy for the persisted Insights activity log.
//  JSON on disk at `~/.osaurus/config/activity-log.json`, mirroring
//  `PrivacyFilterStore`: a locked in-memory snapshot so the logging hot
//  path never pays a disk read.
//

import Foundation

public struct ActivityLogSettings: Codable, Equatable, Sendable {
    /// Days of activity to keep. `nil` keeps everything.
    public var retentionDays: Int?
    /// When false, request/response bodies, wire bodies, tool arguments and
    /// results are replaced with a marker before persistence. Metadata,
    /// sizes, destinations and tool names are always kept.
    public var storeContent: Bool

    public static let `default` = ActivityLogSettings(retentionDays: 30, storeContent: true)

    public static let retentionChoices: [Int?] = [7, 30, 90, 365, nil]

    public static func retentionLabel(_ days: Int?) -> String {
        guard let days else { return L("Keep forever") }
        switch days {
        case 7: return L("7 days")
        case 30: return L("30 days")
        case 90: return L("90 days")
        case 365: return L("1 year")
        default: return String(format: L("%d days"), days)
        }
    }

    public init(retentionDays: Int?, storeContent: Bool) {
        self.retentionDays = retentionDays
        self.storeContent = storeContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays)
        storeContent = try c.decodeIfPresent(Bool.self, forKey: .storeContent) ?? true
    }

    /// Cutoff date for pruning, or nil when retention is unlimited.
    public func retentionCutoff(now: Date = Date()) -> Date? {
        guard let retentionDays, retentionDays > 0 else { return nil }
        return now.addingTimeInterval(-Double(retentionDays) * 86_400)
    }
}

extension Notification.Name {
    static let activityLogSettingsChanged = Notification.Name("ai.osaurus.activityLogSettingsChanged")
}

public enum ActivityLogSettingsStore {
    private nonisolated(unsafe) static var cached: ActivityLogSettings?
    private nonisolated(unsafe) static var overrideURL: URL?
    private static let lock = NSLock()

    /// Test hook. Pass nil to restore the real path.
    public nonisolated static func setOverrideFileURL(_ url: URL?) {
        lock.lock()
        overrideURL = url
        cached = nil
        lock.unlock()
    }

    public nonisolated static func snapshot() -> ActivityLogSettings {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        return load() ?? .default
    }

    public nonisolated static func load() -> ActivityLogSettings? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(ActivityLogSettings.self, from: Data(contentsOf: url))
            lock.lock()
            cached = decoded
            lock.unlock()
            return decoded
        } catch {
            print("[Osaurus] Failed to load ActivityLogSettings: \(error)")
            return nil
        }
    }

    public nonisolated static func save(_ settings: ActivityLogSettings) {
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: [.atomic])
            lock.lock()
            cached = settings
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .activityLogSettingsChanged, object: settings)
            }
        } catch {
            print("[Osaurus] Failed to save ActivityLogSettings: \(error)")
        }
    }

    private nonisolated static func fileURL() -> URL {
        lock.lock()
        let override = overrideURL
        lock.unlock()
        return override ?? OsaurusPaths.activityLogConfigFile()
    }
}
