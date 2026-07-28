//
//  AgentChannelDestinationPresentation.swift
//  osaurus
//
//  Human-readable presentation for channel rooms and outbound destinations.
//  Provider IDs (C0…, D0…, chat ids) stay authoritative for routing and
//  storage; this layer only decides what the user reads on screen — names
//  first, IDs as secondary technical detail.
//

import Foundation

// MARK: - Room Kind

/// Normalized conversation type across providers, derived from each
/// provider's own type strings (Slack `im`/`mpim`/`private_channel`,
/// Telegram `private`/`group`/`supergroup`, Discord rooms, …).
enum AgentChannelRoomKind: Equatable, Sendable {
    case channel
    case privateChannel
    case directMessage
    case groupDirectMessage
    case group
    case unknown

    /// Map a provider kind string (from `listRooms` / provider list APIs)
    /// into the normalized kind. Unrecognized strings stay `.unknown` and
    /// render without a type badge rather than guessing.
    static func from(providerKind: String) -> AgentChannelRoomKind {
        switch providerKind.lowercased() {
        case "channel", "room", "public_channel":
            return .channel
        case "private_channel":
            return .privateChannel
        case "im", "private", "dm":
            return .directMessage
        case "mpim":
            return .groupDirectMessage
        case "group", "supergroup":
            return .group
        default:
            return .unknown
        }
    }

    /// SF Symbol conveying the conversation type.
    var icon: String {
        switch self {
        case .channel: return "number"
        case .privateChannel: return "lock.fill"
        case .directMessage: return "person.fill"
        case .groupDirectMessage: return "person.2.fill"
        case .group: return "person.3.fill"
        case .unknown: return "bubble.left.fill"
        }
    }

    /// Short badge label for types that need calling out. Plain channels
    /// are the default case and carry no badge.
    var badgeLabel: String? {
        switch self {
        case .channel: return nil
        case .privateChannel: return L("Private")
        case .directMessage: return L("DM")
        case .groupDirectMessage: return L("Group DM")
        case .group: return L("Group")
        case .unknown: return nil
        }
    }

    /// Whether names of this kind read as channels and take a leading "#".
    var usesHashPrefix: Bool {
        switch self {
        case .channel, .privateChannel: return true
        case .directMessage, .groupDirectMessage, .group, .unknown: return false
        }
    }
}

// MARK: - Room Descriptor

/// What we know about one provider room beyond its raw id.
struct AgentChannelRoomDescriptor: Equatable, Sendable {
    let name: String
    let kind: AgentChannelRoomKind

    /// Name as shown to the user: channels read as "#name", conversations
    /// read as the person or group name. A name equal to the raw id stays
    /// unprefixed so IDs never masquerade as channel names.
    var formattedName: String {
        guard !name.isEmpty else { return name }
        if kind.usesHashPrefix, !name.hasPrefix("#") {
            return "#\(name)"
        }
        return name
    }
}

// MARK: - Destination Presentation

/// Everything a destination row renders, resolved once from the binding
/// plus whatever room metadata is available. Falls back to the binding's
/// stored label / raw route when the room could not be resolved.
struct AgentChannelDestinationPresentation: Equatable {
    /// Primary row title, e.g. "#content", "Eric Jang", or a custom label.
    let title: String
    /// Secondary line, e.g. "Dinoki · Slack" or just "Slack".
    let subtitle: String
    /// Optional conversation-type badge ("DM", "Group DM", "Private").
    let typeBadge: String?
    /// Conversation-type icon.
    let icon: String
    /// Raw route for tooltips and technical detail, e.g. "slack · C0BE4GHDMCT".
    let technicalRoute: String
    /// Whether the title is a resolved name rather than a raw-id fallback.
    let titleIsResolved: Bool

    static func make(
        binding: AgentChannelBinding,
        descriptor: AgentChannelRoomDescriptor?,
        providerName: String,
        agentName: String?
    ) -> AgentChannelDestinationPresentation {
        let route = "\(binding.connectionId) · \(binding.roomId)"
        // Automatic bindings are labeled "<Provider> · <roomId>" at derivation
        // time; that pattern is a fallback, not an operator-chosen name.
        let autoPatternLabels = [
            route,
            "\(providerName) · \(binding.roomId)",
        ]
        let customLabel: String? = {
            let label = binding.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !autoPatternLabels.contains(label) else { return nil }
            return label
        }()

        let title: String
        let titleIsResolved: Bool
        if let customLabel {
            title = customLabel
            titleIsResolved = true
        } else if let descriptor, !descriptor.name.isEmpty, descriptor.name != binding.roomId {
            title = descriptor.formattedName
            titleIsResolved = true
        } else {
            title = "\(providerName) · \(binding.roomId)"
            titleIsResolved = false
        }

        let subtitle = [agentName, providerName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let kind = descriptor?.kind ?? .unknown
        return AgentChannelDestinationPresentation(
            title: title,
            subtitle: subtitle,
            typeBadge: kind.badgeLabel,
            icon: kind.icon,
            technicalRoute: route,
            titleIsResolved: titleIsResolved
        )
    }
}
