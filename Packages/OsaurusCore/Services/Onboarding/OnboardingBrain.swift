//
//  OnboardingBrain.swift
//  osaurus
//
//  Where the first-run chat runs, read from app state. One value drives the
//  opening's variant, whether personal-data asks are offered, the disclosure
//  on a provider, and the label under each reply.
//

import Foundation

public enum OnboardingBrainState: Sendable, Equatable {
    /// A local model answers. `comfortable` when it is rated compatible
    /// with this Mac's memory; only then does the opening say so.
    case local(comfortable: Bool)
    /// The private model is downloading and the temporary Osaurus Cloud
    /// model answers until it lands.
    case bridged
    /// The private model is downloading and Osaurus Cloud is unreachable:
    /// nothing answers yet.
    case downloadingLocked
    /// A cloud model the person chose: Osaurus Cloud, a provider key, or a
    /// harness. Carries the name the label shows.
    case provider(String)
    /// Osaurus Cloud was chosen and has not connected yet: nothing answers
    /// until it does, and another brain can still be chosen.
    case cloudConnecting
    /// No brain committed.
    case none

    public static let osaurusCloudName = "Osaurus Cloud"

    public struct Inputs: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case local(modelName: String)
            case foundation
            case remote(providerName: String, isOsaurusRouter: Bool)
            case none
        }
        public var pendingLocalDownload: Bool
        public var source: Source
        /// Osaurus Cloud was chosen and its model is not pinned yet.
        public var cloudPending: Bool
        /// Rates a local model against this Mac's memory.
        public var isCompatible: @Sendable (String) -> Bool

        public init(
            pendingLocalDownload: Bool, source: Source, cloudPending: Bool = false,
            isCompatible: @escaping @Sendable (String) -> Bool
        ) {
            self.pendingLocalDownload = pendingLocalDownload
            self.source = source
            self.cloudPending = cloudPending
            self.isCompatible = isCompatible
        }

        public static func == (lhs: Inputs, rhs: Inputs) -> Bool {
            lhs.pendingLocalDownload == rhs.pendingLocalDownload && lhs.source == rhs.source
                && lhs.cloudPending == rhs.cloudPending
        }
    }

    public static func resolve(_ inputs: Inputs) -> OnboardingBrainState {
        if inputs.pendingLocalDownload {
            if case .remote(_, true) = inputs.source { return .bridged }
            return .downloadingLocked
        }
        switch inputs.source {
        case .local(let name): return .local(comfortable: inputs.isCompatible(name))
        case .foundation: return .local(comfortable: false)
        case .remote(let name, let isRouter): return .provider(isRouter ? osaurusCloudName : name)
        case .none: return inputs.cloudPending ? .cloudConnecting : .none
        }
    }

    /// A model can answer in this chat.
    public var canAnswer: Bool {
        switch self {
        case .local, .bridged, .provider: return true
        case .downloadingLocked, .cloudConnecting, .none: return false
        }
    }

    /// Asks that read mail, calendar, notes, files, or code wait for the
    /// private model while the bridge answers, and while nothing does.
    public var holdsPersonalAsks: Bool {
        switch self {
        case .bridged, .downloadingLocked, .cloudConnecting, .none: return true
        case .local, .provider: return false
        }
    }

    /// The provider a personal-data ask sends data to, said before the
    /// macOS dialog. Nil on this Mac.
    public var disclosedProvider: String? {
        if case .provider(let name) = self { return name }
        return nil
    }

    /// The label for a reply generated now.
    public func runLocation(offline: Bool) -> ChatRunLocation? {
        switch self {
        case .local: return offline ? .thisMacOffline : .thisMac
        case .bridged: return .provider(Self.osaurusCloudName)
        case .provider(let name): return .provider(name)
        case .downloadingLocked, .cloudConnecting, .none: return nil
        }
    }
}

extension ChatRunLocation {
    /// "On this Mac · 42 tok/s", "Osaurus Cloud", "On this Mac, offline".
    public func label(tokensPerSecond: Double?) -> String {
        switch self {
        case .thisMac:
            guard let rate = tokensPerSecond, rate > 0 else { return L("On this Mac") }
            return String(format: L("On this Mac · %d tok/s"), Int(rate.rounded()))
        case .thisMacOffline:
            return L("On this Mac, offline")
        case .provider(let name):
            return name
        }
    }
}
