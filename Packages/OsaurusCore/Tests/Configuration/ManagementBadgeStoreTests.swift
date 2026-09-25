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
        installedThemes: Int = 0,
        workspaces: Int = 0,
        observedChannelCount: Int? = nil
    ) -> [ManagementTab: Int] {
        ManagementBadgeStore.mainActorCounts(
            connectedInferenceProviders: 3,
            sandboxPlugins: 1,
            tools: 12,
            skills: 4,
            customCommands: 2,
            customAgents: customAgents,
            remoteAgents: remoteAgents,
            schedules: 5,
            watchers: 6,
            knowledgeCollections: 7,
            downloadedSpeechModels: 1,
            installedThemes: installedThemes,
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

    @Test("Themes badge matches the Themes page header: every installed theme")
    func themesCount() {
        #expect(counts(installedThemes: 5)[.themes] == 5)
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
        #expect(c[.sandbox] == 1)
        #expect(c[.tools] == 12)
        #expect(c[.skills] == 4)
        #expect(c[.commands] == 2)
        #expect(c[.schedules] == 5)
        #expect(c[.watchers] == 6)
        #expect(c[.knowledge] == 7)
        #expect(c[.voice] == 1)
        // Resolved off-main; never part of the synchronous map.
        #expect(c[.models] == nil)
        #expect(c[.imageGeneration] == nil)
        #expect(c[.memory] == nil)
        // Nothing ever computes an Identity count.
        #expect(c[.identity] == nil)
    }

    @Test("background-resolved tabs are the ones carried between recomputes")
    func backgroundResolvedTabs() {
        #expect(
            Set(ManagementBadgeStore.backgroundResolvedTabs) == [.models, .imageGeneration, .memory]
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
            ManagementBadgeStore.shared.refreshNow()
        }

        ManagementBadgeStore.shared.setObservedCount(4, for: .agentChannels)
        #expect(UserDefaults.standard.integer(forKey: key) == 4)
        #expect(ManagementBadgeStore.shared.snapshot.counts[.agentChannels] == 4)

        ManagementBadgeStore.shared.setObservedCount(0, for: .agentChannels)
        #expect(ManagementBadgeStore.shared.snapshot.counts[.agentChannels] == 0)
    }
}
