//
//  ManagementBadgeStoreTests.swift
//  osaurusTests
//
//  The Settings sidebar badges are resource counts that mirror each page's
//  header. Pin the pure count mapping and the observed-count cache used for
//  tabs whose count the store cannot compute itself (Channels).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ManagementBadgeStoreTests {
    private func counts(
        customAgents: Int = 0,
        remoteAgents: Int = 0,
        workspaces: Int = 0,
        observedChannelCount: Int? = nil
    ) -> [ManagementTab: Int] {
        ManagementBadgeStore.mainActorCounts(
            connectedInferenceProviders: 3,
            tools: 12,
            skills: 4,
            customCommands: 2,
            customAgents: customAgents,
            remoteAgents: remoteAgents,
            events: 5,
            knowledgeCollections: 7,
            workspaces: workspaces,
            observedChannelCount: observedChannelCount
        )
    }

    @Test("Workspaces badge is the number of workspaces the user belongs to")
    func workspacesCount() {
        #expect(counts(workspaces: 0)[.workspaces] == 0)
        #expect(counts(workspaces: 1)[.workspaces] == 1)
        #expect(counts(workspaces: 3)[.workspaces] == 3)
    }

    @Test("Agents badge matches the Agents page header: custom + paired remote")
    func agentsCount() {
        #expect(counts(customAgents: 2, remoteAgents: 0)[.agents] == 2)
        #expect(counts(customAgents: 2, remoteAgents: 3)[.agents] == 5)
        #expect(counts(customAgents: 0, remoteAgents: 1)[.agents] == 1)
    }

    @Test("Channels badge is only present once the page has reported a count")
    func channelsCount() {
        #expect(counts(observedChannelCount: nil)[.agentChannels] == nil)
        #expect(counts(observedChannelCount: 2)[.agentChannels] == 2)
    }

    @Test("the other inventory badges pass straight through")
    func passThrough() {
        let c = counts()
        #expect(c[.providers] == 3)
        #expect(c[.tools] == 12)
        #expect(c[.skills] == 4)
        #expect(c[.commands] == 2)
        #expect(c[.automations] == 5)
        #expect(c[.knowledge] == 7)
        // Resolved off-main; never part of the synchronous map.
        #expect(c[.models] == nil)
        #expect(c[.memory] == nil)
        // Status pages list no items of the user's, so they carry no badge.
        #expect(c[.voice] == nil)
        #expect(c[.imageGeneration] == nil)
        #expect(c[.sandbox] == nil)
        // Nothing ever computes an Identity count.
        #expect(c[.identity] == nil)
    }

    @Test("background-resolved tabs are the ones carried between recomputes")
    func backgroundResolvedTabs() {
        #expect(
            Set(ManagementBadgeStore.backgroundResolvedTabs) == [.models, .memory]
        )
    }

    @Test("an observed count is cached in UserDefaults and surfaces in the snapshot")
    @MainActor
    func observedCountRoundTrip() async throws {
        let key = ManagementBadgeStore.observedCountDefaultsKey(for: .agentChannels)
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            ManagementBadgeStore.shared.reloadObservedCountsFromDefaults()
        }

        ManagementBadgeStore.shared.setObservedCount(4, for: .agentChannels)
        #expect(UserDefaults.standard.integer(forKey: key) == 4)
        #expect(ManagementBadgeStore.shared.snapshot.counts[.agentChannels] == 4)

        ManagementBadgeStore.shared.setObservedCount(0, for: .agentChannels)
        #expect(ManagementBadgeStore.shared.snapshot.counts[.agentChannels] == 0)
    }

    @Test("recompute serves observed counts from memory, not UserDefaults")
    @MainActor
    func observedCountServedFromCache() async throws {
        let key = ManagementBadgeStore.observedCountDefaultsKey(for: .agentChannels)
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            ManagementBadgeStore.shared.reloadObservedCountsFromDefaults()
        }

        ManagementBadgeStore.shared.setObservedCount(3, for: .agentChannels)
        // An out-of-band defaults write must not be re-read on the main-actor
        // recompute path (that read is what hung the main thread).
        UserDefaults.standard.set(9, forKey: key)
        ManagementBadgeStore.shared.refreshNow()
        #expect(ManagementBadgeStore.shared.snapshot.counts[.agentChannels] == 3)

        // Pushing a new count still persists it for the next launch.
        ManagementBadgeStore.shared.setObservedCount(5, for: .agentChannels)
        #expect(UserDefaults.standard.integer(forKey: key) == 5)
        #expect(ManagementBadgeStore.shared.snapshot.counts[.agentChannels] == 5)
    }
}
