//
//  TriggerSourceConfigs.swift
//  osaurus
//
//  Configs of the source kinds that pull from a URL or listen to the app
//  itself: an RSS / Atom / JSON feed, a server-sent events stream, failed
//  runs, and app events (launch, an automation turned on or edited).
//

import Foundation

/// New items in an RSS, Atom or JSON feed, checked on an interval.
public struct RSSSourceConfig: Codable, Equatable, Sendable {
    public var url: String
    public var pollIntervalSeconds: Int
    /// What the first check after a relaunch does with items published
    /// while the app was closed.
    public var catchUp: SourceCatchUpPolicy
    /// New items one check hands on; older ones in a burst are skipped.
    public var maxItemsPerTick: Int

    public static let defaultPollIntervalSeconds = 900
    public static let pollIntervalRange = 60...86_400
    public static let defaultMaxItemsPerTick = 20
    public static let maxItemsPerTickRange = 1...100

    public init(
        url: String = "",
        pollIntervalSeconds: Int = RSSSourceConfig.defaultPollIntervalSeconds,
        catchUp: SourceCatchUpPolicy = .latestOnly,
        maxItemsPerTick: Int = RSSSourceConfig.defaultMaxItemsPerTick
    ) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pollIntervalSeconds = Self.pollIntervalRange.clamp(pollIntervalSeconds)
        self.catchUp = catchUp
        self.maxItemsPerTick = Self.maxItemsPerTickRange.clamp(maxItemsPerTick)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
            pollIntervalSeconds: try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
                ?? Self.defaultPollIntervalSeconds,
            catchUp: try c.decodeIfPresent(SourceCatchUpPolicy.self, forKey: .catchUp) ?? .latestOnly,
            maxItemsPerTick: try c.decodeIfPresent(Int.self, forKey: .maxItemsPerTick) ?? Self.defaultMaxItemsPerTick)
    }

    /// The feed URL when it is a usable http(s) URL.
    public var feedURL: URL? { TriggerSourceURL.parse(url) }
}

/// Messages on a server-sent events (`text/event-stream`) endpoint.
public struct SSESourceConfig: Codable, Equatable, Sendable {
    public var url: String
    /// Request headers sent on connect. Not secrets: they are stored and
    /// exported as written.
    public var headers: [String: String]
    /// SSE `event:` names that fire; empty = every message.
    public var eventNames: [String]
    /// Reconnect when nothing (not even a comment) arrives for this long;
    /// nil = never.
    public var heartbeatTimeoutSeconds: Int?

    public static let heartbeatTimeoutRange = 10...3600

    public init(
        url: String = "",
        headers: [String: String] = [:],
        eventNames: [String] = [],
        heartbeatTimeoutSeconds: Int? = nil
    ) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned: [String: String] = [:]
        for (name, value) in headers {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { cleaned[key] = value }
        }
        self.headers = cleaned
        self.eventNames = ChannelMessageSourceConfig.normalizedRooms(eventNames)
        self.heartbeatTimeoutSeconds = heartbeatTimeoutSeconds.map(Self.heartbeatTimeoutRange.clamp)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
            headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
            eventNames: try c.decodeIfPresent([String].self, forKey: .eventNames) ?? [],
            heartbeatTimeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .heartbeatTimeoutSeconds))
    }

    public var streamURL: URL? { TriggerSourceURL.parse(url) }
}

/// A workflow run (or an automation's run) that failed.
public struct RunFailedSourceConfig: Codable, Equatable, Sendable {
    /// Workflows whose failures fire; empty = any workflow.
    public var workflowIDs: [UUID]
    /// Also fire when an automation that runs an agent fails.
    public var includeAutomationRuns: Bool

    public init(workflowIDs: [UUID] = [], includeAutomationRuns: Bool = false) {
        var seen = Set<UUID>()
        self.workflowIDs = workflowIDs.filter { seen.insert($0).inserted }
        self.includeAutomationRuns = includeAutomationRuns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workflowIDs: try c.decodeIfPresent([UUID].self, forKey: .workflowIDs) ?? [],
            includeAutomationRuns: try c.decodeIfPresent(Bool.self, forKey: .includeAutomationRuns) ?? false)
    }
}

/// Something that happened to the app or to this automation.
public enum AppEventReason: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Osaurus finished starting.
    case appLaunched = "app_launched"
    /// This automation was created turned on, or turned on.
    case automationEnabled = "automation_enabled"
    /// This automation was saved with changes while on.
    case automationUpdated = "automation_updated"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appLaunched: L("Osaurus starts")
        case .automationEnabled: L("This automation is turned on")
        case .automationUpdated: L("This automation is changed")
        }
    }
}

public struct AppEventsSourceConfig: Codable, Equatable, Sendable {
    /// In `AppEventReason.allCases` order, no repeats.
    public var reasons: [AppEventReason]

    public init(reasons: [AppEventReason] = [.appLaunched]) {
        let wanted = Set(reasons)
        self.reasons = AppEventReason.allCases.filter(wanted.contains)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(reasons: try c.decodeIfPresent([AppEventReason].self, forKey: .reasons) ?? [.appLaunched])
    }

    public func fires(on reason: AppEventReason) -> Bool { reasons.contains(reason) }
}

/// Something another Mac app did, as `NSWorkspace` reports it.
public enum MacAppEvent: String, Codable, CaseIterable, Sendable, Identifiable {
    case launched
    case quit
    /// Came to the front.
    case activated
    /// Stopped being the front app.
    case deactivated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .launched: L("Opens")
        case .quit: L("Quits")
        case .activated: L("Comes to the front")
        case .deactivated: L("Leaves the front")
        }
    }

    /// What the app does, after its name: "opens".
    public var verb: String {
        switch self {
        case .launched: L("opens")
        case .quit: L("quits")
        case .activated: L("comes to the front")
        case .deactivated: L("leaves the front")
        }
    }

    /// What the app did, after its name: "opened".
    public var pastVerb: String {
        switch self {
        case .launched: L("opened")
        case .quit: L("quit")
        case .activated: L("came to the front")
        case .deactivated: L("left the front")
        }
    }

    /// The event as the middle of a sentence: "Xcode opens".
    public func sentence(_ app: String) -> String {
        switch self {
        case .launched: L("\(app) opens")
        case .quit: L("\(app) quits")
        case .activated: L("\(app) comes to the front")
        case .deactivated: L("\(app) leaves the front")
        }
    }
}

/// The "Mac App" automation: fires when the chosen app opens, quits, or
/// comes to or leaves the front. Only while Osaurus runs; what happened
/// while it was closed is not caught up.
public struct MacAppSourceConfig: Codable, Equatable, Sendable {
    /// The app's bundle identifier; empty until one is chosen.
    public var bundleID: String
    /// The app's name as chosen, for summaries when it is not installed.
    public var name: String
    /// In `MacAppEvent.allCases` order, no repeats.
    public var events: [MacAppEvent]

    public init(bundleID: String = "", name: String = "", events: [MacAppEvent] = [.launched]) {
        self.bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = Set(events)
        self.events = MacAppEvent.allCases.filter(wanted.contains)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            events: try c.decodeIfPresent([MacAppEvent].self, forKey: .events) ?? [.launched])
    }

    public func fires(on event: MacAppEvent, bundleID other: String?) -> Bool {
        guard let other, !bundleID.isEmpty, events.contains(event) else { return false }
        return bundleID.caseInsensitiveCompare(other) == .orderedSame
    }

    /// The name to show: as chosen, else the bundle id.
    public var displayName: String { name.isEmpty ? bundleID : name }

    /// "Xcode opens or quits"; "Xcode opens, quits, or comes to the front".
    public var phrase: String {
        let app = bundleID.isEmpty ? L("an app") : displayName
        guard events.count > 1 else { return (events.first ?? .launched).sentence(app) }
        return "\(app) \(Self.orList(events.map(\.verb)))"
    }

    /// Why a run started: "Xcode opened"; "Xcode opened or quit".
    public var pastPhrase: String {
        let app = bundleID.isEmpty ? L("An app") : displayName
        return "\(app) \(Self.orList((events.isEmpty ? [.launched] : events).map(\.pastVerb)))"
    }

    private static func orList(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        let head = items.dropLast()
        return head.count == 1 ? L("\(head.joined()) or \(last)") : L("\(head.joined(separator: ", ")), or \(last)")
    }
}

enum TriggerSourceURL {
    /// An http(s) URL with a host; nil otherwise.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

extension ClosedRange where Bound == Int {
    fileprivate func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
