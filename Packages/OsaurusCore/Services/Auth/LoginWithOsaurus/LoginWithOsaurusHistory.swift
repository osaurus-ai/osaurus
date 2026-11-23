//
//  LoginWithOsaurusHistory.swift
//  OsaurusCore
//
//  The recent "Log in with Osaurus" requests shown in the Identity tab.
//  Nothing secret is kept: the website origin, what happened, when, and the
//  address that signed.
//

import Foundation

public struct LoginWithOsaurusHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case signedIn
        case cancelled
        case failed
    }

    public let id: UUID
    public let origin: String
    public let outcome: Outcome
    /// The OAuth error code for `cancelled` / `failed`.
    public let errorCode: String?
    public let date: Date
    /// Lowercase master address, for `signedIn`.
    public let address: String?

    public init(
        id: UUID = UUID(), origin: String, outcome: Outcome, errorCode: String? = nil, date: Date,
        address: String? = nil
    ) {
        self.id = id
        self.origin = origin
        self.outcome = outcome
        self.errorCode = errorCode
        self.date = date
        self.address = address
    }

    public var host: String {
        URLComponents(string: origin)?.host ?? origin
    }
}

@MainActor
public final class LoginWithOsaurusHistory: ObservableObject {
    public static let shared = LoginWithOsaurusHistory()

    static let defaultsKey = "ai.osaurus.loginWithOsaurus.history"
    static let maxEntries = 50

    @Published public private(set) var entries: [LoginWithOsaurusHistoryEntry]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([LoginWithOsaurusHistoryEntry].self, from: data)
        {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Newest first, capped at `maxEntries`.
    func record(_ entry: LoginWithOsaurusHistoryEntry) {
        entries = Array(([entry] + entries).prefix(Self.maxEntries))
        persist()
    }

    public func clear() {
        entries = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
