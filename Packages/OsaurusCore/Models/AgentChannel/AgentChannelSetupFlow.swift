//
//  AgentChannelSetupFlow.swift
//  osaurus
//
//  Provider-independent model for the focused channel setup surface: the
//  ordered section rail, per-section completion state, and the unified
//  "Add Channel" catalog.
//

import Foundation

// MARK: - Setup Sections

/// State of one section in a channel setup flow's rail.
enum AgentChannelSetupSectionStatus: Equatable, Sendable {
    /// Not finished yet (or intentionally left unconfigured).
    case pending
    /// The section's requirements are met.
    case complete
    /// A validation error or blocker points at this section.
    case attention
}

/// One entry in a channel setup flow's section rail.
struct AgentChannelSetupSection: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let icon: String
    /// Small qualifier under the title, e.g. "Optional".
    var caption: String?

    init(id: String, title: String, icon: String, caption: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.caption = caption
    }
}

/// Pure navigation helpers over an ordered section list, shared by every
/// channel setup sheet so Back / Continue behave identically everywhere.
enum AgentChannelSetupFlow {
    static func index(of id: String, in sections: [AgentChannelSetupSection]) -> Int? {
        sections.firstIndex { $0.id == id }
    }

    static func isFirst(_ id: String, in sections: [AgentChannelSetupSection]) -> Bool {
        index(of: id, in: sections) == 0
    }

    static func isLast(_ id: String, in sections: [AgentChannelSetupSection]) -> Bool {
        guard let index = index(of: id, in: sections) else { return false }
        return index == sections.count - 1
    }

    static func next(after id: String, in sections: [AgentChannelSetupSection]) -> String? {
        guard let index = index(of: id, in: sections), index + 1 < sections.count else {
            return nil
        }
        return sections[index + 1].id
    }

    static func previous(before id: String, in sections: [AgentChannelSetupSection]) -> String? {
        guard let index = index(of: id, in: sections), index > 0 else { return nil }
        return sections[index - 1].id
    }

    /// Where a setup sheet should land when it opens: the first section whose
    /// requirements are unmet, or `fallback` when everything required is done
    /// (an already-configured channel opens on its overview/verify surface).
    static func initialSection(
        in sections: [AgentChannelSetupSection],
        required requiredIds: [String],
        isComplete: (String) -> Bool,
        fallback: String
    ) -> String {
        for section in sections where requiredIds.contains(section.id) {
            if !isComplete(section.id) {
                return section.id
            }
        }
        return fallback
    }
}

// MARK: - Provider Setup Sections

/// The sections every native provider setup flow shares, in the order a
/// message travels: connect the bot, choose what it receives, route each
/// message to an agent or workflow, choose what agents may send, then
/// test. Provider sheets map their fields into these instead of exposing
/// one long scroll of numbered steps.
enum AgentChannelProviderSetupSection: String, CaseIterable, Sendable {
    case connect
    case receiving
    case routing
    case sending
    case verify

    var title: String {
        switch self {
        case .connect: return L("Connect")
        case .receiving: return L("Receiving")
        case .routing: return L("Routing")
        case .sending: return L("Sending")
        case .verify: return L("Test")
        }
    }

    var icon: String {
        switch self {
        case .connect: return "link"
        case .receiving: return "tray.and.arrow.down"
        case .routing: return "arrow.triangle.branch"
        case .sending: return "paperplane"
        case .verify: return "checkmark.seal"
        }
    }

    var caption: String? {
        switch self {
        case .connect: return L("Account and access")
        case .receiving: return L("Rooms and people")
        case .routing: return L("Who answers")
        case .sending: return L("Posting rules")
        case .verify: return L("Live check")
        }
    }

    static var sections: [AgentChannelSetupSection] {
        allCases.map {
            AgentChannelSetupSection(id: $0.rawValue, title: $0.title, icon: $0.icon, caption: $0.caption)
        }
    }

    /// Sections whose completion gates the initial landing position;
    /// routing, sending and verify are optional or ongoing, so a configured
    /// channel opens on Test rather than an eternally "incomplete" optional
    /// section.
    static var requiredSectionIds: [String] {
        [Self.connect.rawValue, Self.receiving.rawValue]
    }
}

// MARK: - Add Channel Catalog

/// The unified "Add Channel" picker's catalog: guided native providers first,
/// the advanced custom HTTP definition last.
enum AgentChannelAddCatalog {
    static let choices: [AgentChannelKind] = [
        .discord, .slack, .telegram, .imessage, .whatsapp, .email, .n8n, .customHTTP,
    ]

    /// Custom HTTP is the advanced integration path, visually set apart from
    /// the guided native providers.
    static func isAdvanced(_ kind: AgentChannelKind) -> Bool {
        kind == .customHTTP
    }

    static func tagline(for kind: AgentChannelKind) -> String {
        switch kind {
        case .discord: return L("Guided setup — bot access to allowlisted servers and channels")
        case .slack: return L("Guided setup — bot access to allowlisted channels and DMs")
        case .telegram: return L("Guided setup — bot access to allowlisted chats and groups")
        case .imessage: return L("Guided setup — this Mac's Messages app, allowlisted chats only")
        case .whatsapp: return L("Guided setup — QR-linked WhatsApp Web bridge, allowlisted chats only")
        case .email: return L("Guided setup — Mail app or IMAP/SMTP accounts, allowlisted senders only")
        case .n8n: return L("Guided setup — n8n HTTP Request in, poll or webhook out")
        case .customHTTP: return L("Advanced — define your own HTTP JSON channel")
        }
    }
}
