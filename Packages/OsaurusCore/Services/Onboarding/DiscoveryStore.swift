//
//  DiscoveryStore.swift
//  osaurus
//
//  What discovery remembers: the items retired for good, the items a card
//  has shown, and the last day a new card was shown, so at most one new
//  card appears per day. A card already seen may show again until it is
//  done or dismissed. One setting turns discovery off.
//

import Foundation

struct DiscoveryState: Codable, Equatable, Sendable {
    var retired: Set<DiscoveryItem> = []
    var seen: Set<DiscoveryItem> = []
    /// Items whose step was taken, for a step that leaves no app state of
    /// its own, such as reviewing memory.
    var taken: Set<DiscoveryItem> = []
    /// `yyyy-MM-dd` of the last day a new card was shown.
    var lastNewDay: String?

    init(
        retired: Set<DiscoveryItem> = [],
        seen: Set<DiscoveryItem> = [],
        taken: Set<DiscoveryItem> = [],
        lastNewDay: String? = nil
    ) {
        self.retired = retired
        self.seen = seen
        self.taken = taken
        self.lastNewDay = lastNewDay
    }

    /// An item no longer in the catalog is skipped, so the rest of the
    /// saved state survives its removal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func items(_ key: CodingKeys) throws -> Set<DiscoveryItem> {
            Set((try c.decodeIfPresent([String].self, forKey: key) ?? []).compactMap(DiscoveryItem.init(rawValue:)))
        }
        retired = try items(.retired)
        seen = try items(.seen)
        taken = try items(.taken)
        lastNewDay = try c.decodeIfPresent(String.self, forKey: .lastNewDay)
    }
}

struct DiscoveryStore {
    static let enabledKey = "discoveryCardsEnabled"
    static let stateKey = "discoveryState"

    var defaults: UserDefaults = .standard

    /// Default on.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func load() -> DiscoveryState {
        guard let data = defaults.data(forKey: Self.stateKey),
            let state = try? JSONDecoder().decode(DiscoveryState.self, from: data)
        else { return DiscoveryState() }
        return state
    }

    func save(_ state: DiscoveryState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The card for a new chat: on a day with no new card yet, the first
    /// open item not seen before; otherwise the first open item already
    /// seen. Marks a new card seen and the day used.
    static func pick(
        order: [DiscoveryItem],
        isOpen: (DiscoveryItem) -> Bool,
        state: inout DiscoveryState,
        today: String
    ) -> DiscoveryItem? {
        let candidates = order.filter { !state.retired.contains($0) && isOpen($0) }
        if state.lastNewDay != today, let fresh = candidates.first(where: { !state.seen.contains($0) }) {
            state.seen.insert(fresh)
            state.lastNewDay = today
            return fresh
        }
        return candidates.first { state.seen.contains($0) }
    }
}
