//
//  AgentChannelDispatchRouterTests.swift
//  osaurus
//
//  Resolution coverage for multi-agent channel routing: alias overrides,
//  per-room mapping, provider default fallback, and backward-compatible
//  decoding of configs written before routes existed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent Channel dispatch router")
struct AgentChannelDispatchRouterTests {
    private let salesAgent = UUID()
    private let supportAgent = UUID()
    private let defaultAgent = UUID()

    private func settings(
        routes: [AgentChannelDispatchRoute],
        defaultAgent: UUID? = nil
    ) -> AgentChannelInboundDispatchConfiguration {
        AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: defaultAgent,
            routes: routes
        )
    }

    @Test
    func roomRouteSendsRoomMessagesToItsAgent() {
        let config = settings(
            routes: [AgentChannelDispatchRoute(roomId: "C-SALES", agentId: salesAgent)],
            defaultAgent: defaultAgent
        )
        let resolved = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-SALES", content: "how are numbers?"
        )
        #expect(resolved?.agentId == salesAgent)
        #expect(resolved?.matchedRule == "room:C-SALES")
        #expect(resolved?.content == "how are numbers?")

        let other = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-OTHER", content: "hello"
        )
        #expect(other?.agentId == defaultAgent)
        #expect(other?.matchedRule == "default")
    }

    @Test
    func aliasOverrideBeatsRoomDefaultAndStripsPrefix() {
        let config = settings(
            routes: [
                AgentChannelDispatchRoute(roomId: "C-SHARED", agentId: salesAgent),
                AgentChannelDispatchRoute(
                    roomId: "C-SHARED", agentId: supportAgent, nameAliases: ["support"]
                ),
            ],
            defaultAgent: defaultAgent
        )
        let aliased = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-SHARED", content: "support: reset my password"
        )
        #expect(aliased?.agentId == supportAgent)
        #expect(aliased?.matchedRule == "alias:support")
        #expect(aliased?.content == "reset my password")

        let plain = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-SHARED", content: "what changed this week?"
        )
        #expect(plain?.agentId == salesAgent)
        #expect(plain?.matchedRule == "room:C-SHARED")
    }

    @Test
    func aliasMatchingIsCaseInsensitiveAndAcceptsAtPrefix() {
        let config = settings(
            routes: [
                AgentChannelDispatchRoute(agentId: supportAgent, nameAliases: ["Support"])
            ]
        )
        for content in ["SUPPORT: hi", "@support hi", "support, hi", "support hi"] {
            let resolved = AgentChannelDispatchRouter.resolve(
                settings: config, roomId: "C-ANY", content: content
            )
            #expect(resolved?.agentId == supportAgent, "content: \(content)")
            #expect(resolved?.content == "hi", "content: \(content)")
        }
    }

    @Test
    func aliasRequiresDelimiterSoPrefixWordsDoNotHijack() {
        let config = settings(
            routes: [
                AgentChannelDispatchRoute(agentId: supportAgent, nameAliases: ["sales"])
            ],
            defaultAgent: defaultAgent
        )
        let resolved = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-ANY", content: "salesforce is down"
        )
        #expect(resolved?.agentId == defaultAgent)
        #expect(resolved?.matchedRule == "default")
    }

    @Test
    func longerAliasWinsOverShorterAndRoomScopedBeatsGlobal() {
        let euAgent = UUID()
        let config = settings(
            routes: [
                AgentChannelDispatchRoute(agentId: salesAgent, nameAliases: ["sales"]),
                AgentChannelDispatchRoute(agentId: euAgent, nameAliases: ["sales-eu"]),
            ]
        )
        let resolved = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-ANY", content: "sales-eu: forecast?"
        )
        #expect(resolved?.agentId == euAgent)

        let scoped = settings(
            routes: [
                AgentChannelDispatchRoute(agentId: salesAgent, nameAliases: ["bot"]),
                AgentChannelDispatchRoute(roomId: "C-ROOM", agentId: supportAgent, nameAliases: ["bot"]),
            ]
        )
        let scopedResolved = AgentChannelDispatchRouter.resolve(
            settings: scoped, roomId: "C-ROOM", content: "bot: hi"
        )
        #expect(scopedResolved?.agentId == supportAgent)
    }

    @Test
    func aliasOnlyRoomRouteDoesNotClaimUnaliasedMessages() {
        let config = settings(
            routes: [
                AgentChannelDispatchRoute(
                    roomId: "C-ROOM", agentId: supportAgent, nameAliases: ["support"]
                )
            ]
        )
        let resolved = AgentChannelDispatchRouter.resolve(
            settings: config, roomId: "C-ROOM", content: "hello there"
        )
        #expect(resolved == nil)
    }

    @Test
    func disabledOrUnroutableConfigurationsResolveToNil() {
        var config = settings(
            routes: [AgentChannelDispatchRoute(roomId: "C-A", agentId: salesAgent)]
        )
        config.enabled = false
        #expect(
            AgentChannelDispatchRouter.resolve(settings: config, roomId: "C-A", content: "hi") == nil
        )

        let empty = settings(routes: [])
        #expect(
            AgentChannelDispatchRouter.resolve(settings: empty, roomId: "C-A", content: "hi") == nil
        )
    }

    @Test
    func isConfiguredAcceptsRoutesWithoutDefaultAgent() {
        let routesOnly = settings(
            routes: [AgentChannelDispatchRoute(roomId: "C-A", agentId: salesAgent)]
        )
        #expect(routesOnly.isConfigured)
        #expect(routesOnly.referencedAgentIds == [salesAgent])

        let both = settings(
            routes: [AgentChannelDispatchRoute(roomId: "C-A", agentId: salesAgent)],
            defaultAgent: defaultAgent
        )
        #expect(Set(both.referencedAgentIds) == Set([salesAgent, defaultAgent]))
    }

    @Test
    func legacyConfigWithoutRoutesDecodes() throws {
        let legacy = Data(
            """
            {
              "enabled": true,
              "targetAgentId": "\(defaultAgent.uuidString)",
              "requireMention": true,
              "continueThreads": true,
              "autoReplyEnabled": false
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(
            AgentChannelInboundDispatchConfiguration.self, from: legacy
        )
        #expect(decoded.enabled)
        #expect(decoded.targetAgentId == defaultAgent)
        #expect(decoded.routes.isEmpty)
        #expect(decoded.isConfigured)

        let roundTripped = try JSONDecoder().decode(
            AgentChannelInboundDispatchConfiguration.self,
            from: JSONEncoder().encode(
                settings(
                    routes: [
                        AgentChannelDispatchRoute(
                            roomId: "C-A", agentId: salesAgent, nameAliases: [" Sales ", "sales"]
                        )
                    ]
                )
            )
        )
        #expect(roundTripped.routes.count == 1)
        #expect(roundTripped.routes[0].nameAliases == ["sales"])
    }
}
