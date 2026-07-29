//
//  AgentChannelDestinationPresentationTests.swift
//  osaurus
//
//  Presentation-layer contract for destination rows: provider IDs stay
//  authoritative for routing, but what the user reads is a resolved name,
//  a normalized conversation type, and the raw route only as technical
//  detail.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelRoomKindTests {
    @Test func mapsSlackProviderKinds() {
        #expect(AgentChannelRoomKind.from(providerKind: "channel") == .channel)
        #expect(AgentChannelRoomKind.from(providerKind: "private_channel") == .privateChannel)
        #expect(AgentChannelRoomKind.from(providerKind: "im") == .directMessage)
        #expect(AgentChannelRoomKind.from(providerKind: "mpim") == .groupDirectMessage)
    }

    @Test func mapsTelegramProviderKinds() {
        #expect(AgentChannelRoomKind.from(providerKind: "private") == .directMessage)
        #expect(AgentChannelRoomKind.from(providerKind: "group") == .group)
        #expect(AgentChannelRoomKind.from(providerKind: "supergroup") == .group)
        #expect(AgentChannelRoomKind.from(providerKind: "channel") == .channel)
    }

    @Test func mapsDiscordAndUnknownProviderKinds() {
        #expect(AgentChannelRoomKind.from(providerKind: "room") == .channel)
        #expect(AgentChannelRoomKind.from(providerKind: "") == .unknown)
        #expect(AgentChannelRoomKind.from(providerKind: "something_new") == .unknown)
    }

    @Test func onlyChannelKindsUseHashPrefix() {
        #expect(AgentChannelRoomKind.channel.usesHashPrefix)
        #expect(AgentChannelRoomKind.privateChannel.usesHashPrefix)
        #expect(!AgentChannelRoomKind.directMessage.usesHashPrefix)
        #expect(!AgentChannelRoomKind.groupDirectMessage.usesHashPrefix)
        #expect(!AgentChannelRoomKind.group.usesHashPrefix)
    }

    @Test func plainChannelsCarryNoBadge() {
        #expect(AgentChannelRoomKind.channel.badgeLabel == nil)
        #expect(AgentChannelRoomKind.unknown.badgeLabel == nil)
        #expect(AgentChannelRoomKind.directMessage.badgeLabel != nil)
        #expect(AgentChannelRoomKind.groupDirectMessage.badgeLabel != nil)
    }
}

struct AgentChannelRoomDescriptorTests {
    @Test func channelNamesGainHashPrefix() {
        let descriptor = AgentChannelRoomDescriptor(name: "content", kind: .channel)
        #expect(descriptor.formattedName == "#content")
    }

    @Test func alreadyPrefixedNamesAreNotDoubled() {
        let descriptor = AgentChannelRoomDescriptor(name: "#content", kind: .channel)
        #expect(descriptor.formattedName == "#content")
    }

    @Test func directMessageNamesStayPlain() {
        let descriptor = AgentChannelRoomDescriptor(name: "Eric Jang", kind: .directMessage)
        #expect(descriptor.formattedName == "Eric Jang")
    }
}

struct AgentChannelDestinationPresentationMakeTests {
    private func binding(
        label: String = "",
        roomId: String = "C0BE4GHDMCT",
        connectionId: String = "slack"
    ) -> AgentChannelBinding {
        AgentChannelBinding(
            id: "test-binding",
            agentId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            connectionId: connectionId,
            roomId: roomId,
            label: label,
            outboundMode: .confirm
        )
    }

    @Test func resolvedChannelLeadsWithNameAndKeepsRawRoute() {
        let presentation = AgentChannelDestinationPresentation.make(
            binding: binding(),
            descriptor: AgentChannelRoomDescriptor(name: "content", kind: .channel),
            providerName: "Slack",
            agentName: "Dinoki"
        )
        #expect(presentation.title == "#content")
        #expect(presentation.titleIsResolved)
        #expect(presentation.subtitle == "Dinoki · Slack")
        #expect(presentation.typeBadge == nil)
        #expect(presentation.technicalRoute == "slack · C0BE4GHDMCT")
    }

    @Test func directMessageShowsPersonNameWithBadge() {
        let presentation = AgentChannelDestinationPresentation.make(
            binding: binding(roomId: "D0AB1CD2EF3"),
            descriptor: AgentChannelRoomDescriptor(name: "Eric Jang", kind: .directMessage),
            providerName: "Slack",
            agentName: nil
        )
        #expect(presentation.title == "Eric Jang")
        #expect(presentation.subtitle == "Slack")
        #expect(presentation.typeBadge != nil)
    }

    @Test func customLabelWinsOverResolvedName() {
        let presentation = AgentChannelDestinationPresentation.make(
            binding: binding(label: "Launch announcements"),
            descriptor: AgentChannelRoomDescriptor(name: "content", kind: .channel),
            providerName: "Slack",
            agentName: "Dinoki"
        )
        #expect(presentation.title == "Launch announcements")
        #expect(presentation.titleIsResolved)
    }

    @Test func automaticPatternLabelIsTreatedAsFallbackNotCustomName() {
        // Automatic bindings are labeled "<Provider> · <roomId>" at derivation
        // time; a resolved room name must replace that pattern.
        let presentation = AgentChannelDestinationPresentation.make(
            binding: binding(label: "Slack · C0BE4GHDMCT"),
            descriptor: AgentChannelRoomDescriptor(name: "content", kind: .channel),
            providerName: "Slack",
            agentName: "Dinoki"
        )
        #expect(presentation.title == "#content")
    }

    @Test func unresolvedRoomFallsBackToProviderAndRawId() {
        let presentation = AgentChannelDestinationPresentation.make(
            binding: binding(),
            descriptor: nil,
            providerName: "Slack",
            agentName: "Dinoki"
        )
        #expect(presentation.title == "Slack · C0BE4GHDMCT")
        #expect(!presentation.titleIsResolved)
        #expect(presentation.typeBadge == nil)
    }

    @Test func descriptorEqualToRawIdDoesNotCountAsResolved() {
        let presentation = AgentChannelDestinationPresentation.make(
            binding: binding(),
            descriptor: AgentChannelRoomDescriptor(name: "C0BE4GHDMCT", kind: .unknown),
            providerName: "Slack",
            agentName: nil
        )
        #expect(presentation.title == "Slack · C0BE4GHDMCT")
        #expect(!presentation.titleIsResolved)
    }
}

struct SlackConversationDMResolutionTests {
    @Test func decodesDMPeerUserId() throws {
        let json = """
            {"id": "D0AB1CD2EF3", "is_im": true, "user": "U0MIKE"}
            """
        let conversation = try JSONDecoder().decode(
            SlackConversation.self,
            from: Data(json.utf8)
        )
        #expect(conversation.isIM)
        #expect(conversation.user == "U0MIKE")
    }

    @Test func dmResolvesToPersonNameFromUserMap() {
        let dm = SlackConversation(id: "D0AB1CD2EF3", user: "U0MIKE", isIM: true)
        #expect(dm.resolvedDisplayName(userNames: ["U0MIKE": "Mike"]) == "Mike")
    }

    @Test func dmWithoutMappedUserFallsBackToId() {
        let dm = SlackConversation(id: "D0AB1CD2EF3", user: "U0MIKE", isIM: true)
        #expect(dm.resolvedDisplayName(userNames: [:]) == "D0AB1CD2EF3")
    }

    @Test func namedChannelIgnoresUserMap() {
        let channel = SlackConversation(id: "C11111", name: "content", isChannel: true)
        #expect(channel.resolvedDisplayName(userNames: ["U0MIKE": "Mike"]) == "content")
    }
}

@MainActor
struct AgentChannelRoomDirectoryTests {
    @Test func resolvesRoomsAcrossSpacesAndSkipsNoticeRows() async throws {
        let directory = AgentChannelRoomDirectory(
            listSpaces: { _ in [["id": "T12345", "name": "Acme"]] },
            listRooms: { _, _ in
                [
                    ["id": "C11111", "name": "content", "kind": "channel"],
                    ["id": "D22222", "name": "Mike", "kind": "im"],
                    ["id": "pagination_notice", "name": "truncated", "kind": "notice"],
                ]
            }
        )

        directory.prepare(connectionIds: ["slack"])
        try await waitForLoad(directory, connectionId: "slack", roomId: "C11111")

        let channel = directory.descriptor(connectionId: "slack", roomId: "C11111")
        #expect(channel?.name == "content")
        #expect(channel?.kind == .channel)

        let dm = directory.descriptor(connectionId: "slack", roomId: "D22222")
        #expect(dm?.name == "Mike")
        #expect(dm?.kind == .directMessage)

        #expect(directory.descriptor(connectionId: "slack", roomId: "pagination_notice") == nil)
    }

    @Test func failedLoadLeavesDescriptorsEmpty() async throws {
        struct Failure: Error {}
        let directory = AgentChannelRoomDirectory(
            listSpaces: { _ in throw Failure() },
            listRooms: { _, _ in [] }
        )

        directory.prepare(connectionIds: ["slack"])
        try await Task.sleep(for: .milliseconds(100))

        #expect(directory.descriptor(connectionId: "slack", roomId: "C11111") == nil)
    }

    private func waitForLoad(
        _ directory: AgentChannelRoomDirectory,
        connectionId: String,
        roomId: String
    ) async throws {
        for _ in 0 ..< 100 {
            if directory.descriptor(connectionId: connectionId, roomId: roomId) != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Room directory never resolved \(connectionId) · \(roomId)")
    }
}
