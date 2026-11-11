//
//  MobileToSyncMigrationTests.swift
//  osaurusTests
//
//  The iPhone moved from the 6-digit HTTP pairing and per-agent relay
//  tunnels to Sync. Pins the one-time migration that runs when the first
//  iPhone joins Sync (only the tunnels the old pairing opened close, its key
//  is revoked, its defaults go, the pairing ends), the
//  platform detection the Devices page and hosted-chat notices branch on,
//  and the Inbox's caller-side and live-run lists.
//

import Foundation
import OsaurusSync
import SwiftUI
import Testing

@testable import OsaurusCore

@Suite("Mobile moves to Sync")
@MainActor
struct MobileToSyncMigrationTests {

    private func defaults() -> UserDefaults {
        let name = "MobileToSyncMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func key(_ label: String, revoked: Bool = false) -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(),
            label: label,
            prefix: "osk-v1.aaa",
            nonce: "nonce-\(UUID().uuidString)",
            cnt: 1,
            iss: "0xmaster",
            aud: "0xmaster",
            createdAt: Date(),
            expiration: .never,
            expiresAt: nil,
            revoked: revoked
        )
    }

    private final class Recorder {
        var enabled: Set<UUID>
        var disabled: [UUID] = []
        var revoked: [UUID] = []
        var pairingEnded = 0
        let keys: [AccessKeyInfo]

        init(enabled: Set<UUID>, keys: [AccessKeyInfo]) {
            self.enabled = enabled
            self.keys = keys
        }

        var environment: MobileConnectMigration.Environment {
            MobileConnectMigration.Environment(
                isTunnelEnabled: { [unowned self] in self.enabled.contains($0) },
                disableTunnel: { [unowned self] in
                    self.disabled.append($0)
                    self.enabled.remove($0)
                },
                accessKeys: { [unowned self] in self.keys },
                revokeKey: { [unowned self] in self.revoked.append($0) },
                endPairing: { [unowned self] in self.pairingEnded += 1 }
            )
        }
    }

    // MARK: Migration

    @Test func onlyTheTunnelsThePairingOpenedClose() throws {
        let defaults = defaults()
        let managed = UUID()
        let workspaceShared = UUID()
        let alreadyOff = UUID()
        defaults.set([managed.uuidString, alreadyOff.uuidString], forKey: MobileConnectMigration.relayManagedAgentsKey)
        defaults.set(true, forKey: MobileConnectMigration.reachAnywhereKey)
        let recorder = Recorder(enabled: [managed, workspaceShared], keys: [])

        let outcome = try #require(MobileConnectMigration.runIfNeeded(iPhoneInSync: true, defaults: defaults, environment: recorder.environment))

        #expect(outcome.tunnelsDisabled == [managed])
        #expect(recorder.disabled == [managed])
        #expect(recorder.enabled.contains(workspaceShared), "a tunnel the user turned on for a workspace stays on")
    }

    @Test func revokesOnlyThePhoneKey() throws {
        let defaults = defaults()
        defaults.set("iPhone", forKey: MobileConnectMigration.pairedDeviceKey)
        let mobile = key("Mobile")
        let renamed = key("Osaurus Connect")
        let alreadyRevoked = key("Mobile", revoked: true)
        let guest = key("Invite – Scout (abcd1234)")
        let recorder = Recorder(enabled: [], keys: [mobile, renamed, alreadyRevoked, guest])

        let outcome = try #require(MobileConnectMigration.runIfNeeded(iPhoneInSync: true, defaults: defaults, environment: recorder.environment))

        #expect(Set(outcome.keysRevoked) == [mobile.id, renamed.id])
        #expect(!recorder.revoked.contains(guest.id))
        #expect(!recorder.revoked.contains(alreadyRevoked.id))
    }

    @Test func clearsDefaultsAndCarriesKeepAwake() throws {
        let defaults = defaults()
        defaults.set(false, forKey: MobileConnectMigration.keepAwakeKey)
        defaults.set(true, forKey: MobileConnectMigration.reachAnywhereKey)
        defaults.set(["x"], forKey: MobileConnectMigration.relayManagedAgentsKey)
        defaults.set("iPhone", forKey: MobileConnectMigration.pairedDeviceKey)
        let recorder = Recorder(enabled: [], keys: [])

        _ = try #require(MobileConnectMigration.runIfNeeded(iPhoneInSync: true, defaults: defaults, environment: recorder.environment))

        for key in MobileConnectMigration.legacyDefaultsKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) is cleared")
        }
        #expect(defaults.object(forKey: SyncPhoneDevices.keepAwakeDefaultsKey) as? Bool == false)
        #expect(!SyncPhoneDevices.isKeepAwakeEnabled(in: defaults))
    }

    @Test func waitsForAnIPhoneInSyncThenRunsOnce() throws {
        let paired = defaults()
        paired.set(true, forKey: MobileConnectMigration.reachAnywhereKey)
        let phoneKey = key("Mobile")
        let recorder = Recorder(enabled: [], keys: [phoneKey])

        #expect(
            MobileConnectMigration.runIfNeeded(iPhoneInSync: false, defaults: paired, environment: recorder.environment)
                == nil)
        #expect(!MobileConnectMigration.isRetired(defaults: paired), "the 6-digit pairing keeps working until then")
        #expect(recorder.revoked.isEmpty)
        #expect(paired.object(forKey: MobileConnectMigration.reachAnywhereKey) != nil)
        #expect(recorder.pairingEnded == 0)

        let outcome = try #require(
            MobileConnectMigration.runIfNeeded(iPhoneInSync: true, defaults: paired, environment: recorder.environment))
        #expect(outcome.keysRevoked == [phoneKey.id])
        #expect(MobileConnectMigration.isRetired(defaults: paired))
        #expect(recorder.pairingEnded == 1)

        #expect(
            MobileConnectMigration.runIfNeeded(iPhoneInSync: true, defaults: paired, environment: recorder.environment)
                == nil)
        #expect(recorder.pairingEnded == 1)
    }

    @Test func retiresOnAMacThatNeverPaired() throws {
        let fresh = defaults()
        let recorder = Recorder(enabled: [], keys: [])
        let outcome = try #require(
            MobileConnectMigration.runIfNeeded(iPhoneInSync: true, defaults: fresh, environment: recorder.environment))
        #expect(outcome == .init())
        #expect(MobileConnectMigration.isRetired(defaults: fresh))
    }

    @Test func ignoresTheV1DoneKey() {
        let earlierBuild = defaults()
        earlierBuild.set(true, forKey: "mobileConnectRetiredToSync.v1")
        #expect(!MobileConnectMigration.isRetired(defaults: earlierBuild))
    }

    // MARK: Platform

    private func device(_ id: String, platform: String, revoked: Bool = false, isSelf: Bool = false) -> Device {
        Device(id: id, user: "u", name: id, platform: platform, lastSeenMs: nil, revoked: revoked, isSelf: isSelf)
    }

    @Test func platformNames() {
        #expect(SyncDevicePlatform("ios") == .iPhone)
        #expect(SyncDevicePlatform("iOS") == .iPhone)
        #expect(SyncDevicePlatform("ipados") == .iPhone)
        #expect(SyncDevicePlatform("macos") == .mac)
        #expect(SyncDevicePlatform("macOS") == .mac)
        #expect(SyncDevicePlatform("linux") == .other)
        #expect(SyncDevicePlatform("windows") == .windows)
        #expect(SyncDevicePlatform("Windows") == .windows)
        #expect(SyncDevicePlatform.iPhone.symbol == "iphone")
        #expect(SyncDevicePlatform.windows.symbol == "pc")
    }

    @Test func everyNonMacDeviceReadsTheMacsFeeds() {
        #expect(!SyncPhoneDevices.hasActiveFeedReader([device("mac", platform: "macos")]))
        #expect(SyncPhoneDevices.hasActiveFeedReader([device("pc", platform: "windows")]))
        #expect(!SyncPhoneDevices.hasActiveFeedReader([device("pc", platform: "windows", revoked: true)]))
        #expect(!SyncPhoneDevices.hasActivePhone([device("pc", platform: "windows")]), "keep-awake stays iPhone-only")
    }

    @Test func activePhoneIgnoresRevokedAndSelf() {
        #expect(!SyncPhoneDevices.hasActivePhone([device("mac", platform: "macos")]))
        #expect(!SyncPhoneDevices.hasActivePhone([device("p", platform: "ios", revoked: true)]))
        #expect(!SyncPhoneDevices.hasActivePhone([device("p", platform: "ios", isSelf: true)]))
        #expect(SyncPhoneDevices.hasActivePhone([device("mac", platform: "macos"), device("p", platform: "ios")]))
    }

    @Test func isPhoneByDeviceKey() {
        let devices = [device("mac-1", platform: "macos"), device("phone-1", platform: "ios")]
        #expect(SyncPhoneDevices.isPhone(deviceKey: "phone-1", devices: devices))
        #expect(!SyncPhoneDevices.isPhone(deviceKey: "mac-1", devices: devices))
        #expect(!SyncPhoneDevices.isPhone(deviceKey: nil, devices: devices))
        #expect(!SyncPhoneDevices.isPhone(deviceKey: "unknown", devices: devices))
    }

    // MARK: Inbox

    @Test func waitingOnOthersAddsRefreshesAndClears() {
        let list = WaitingOnOthers()
        let session = UUID()
        let start = Date(timeIntervalSince1970: 100)
        list.note(
            approvalId: "a1", phase: "waiting", sessionId: session, agentAddress: "0xabc",
            agentName: "Scout", owner: "@alice", tool: "web_fetch", now: start)
        list.note(
            approvalId: "a1", phase: "waiting", sessionId: session, agentAddress: "0xabc",
            agentName: "Scout", owner: "@alice", tool: "web_fetch", now: start.addingTimeInterval(30))
        #expect(list.items.count == 1)
        #expect(list.items.first?.since == start, "a refresh keeps when the wait began")

        list.note(
            approvalId: "a1", phase: "approved", sessionId: session, agentAddress: nil,
            agentName: "Scout", owner: "@alice", tool: "web_fetch")
        #expect(list.items.isEmpty)

        list.note(
            approvalId: "a2", phase: "waiting", sessionId: session, agentAddress: nil,
            agentName: "Scout", owner: "@alice", tool: "shell")
        list.clear(sessionId: session)
        #expect(list.items.isEmpty, "a stopped chat waits on nothing")
    }

    @Test func liveNowNamesPeopleAndOwnDevices() {
        let agentId = UUID()
        let phoneSession = UUID()
        let guest = Participant(kind: .invitePeer, wallet: "0x9c3e00000000000000000000000000000000011aa")
        let rows = InboxLiveRow.rows(
            inbound: [
                .init(runKey: "r1", taskId: UUID(), agentId: agentId, caller: guest, startedAt: Date(timeIntervalSince1970: 20))
            ],
            hosted: [
                phoneSession: .init(deviceKey: "phone-1", agentId: agentId, startedAt: Date(timeIntervalSince1970: 10))
            ],
            devices: [device("phone-1", platform: "ios")]
        )
        #expect(rows.count == 2)
        #expect(rows.first?.isOwnDevice == true, "oldest first")
        #expect(rows.first?.sessionId == phoneSession)
        #expect(rows.first?.who.contains("phone-1") == true)
        #expect(rows.last?.isOwnDevice == false)
        #expect(rows.last?.avatarSeed == guest.wallet)
    }

    // MARK: Attribution

    @Test func participantColorIsStableAndMonogramSkipsPrefixes() {
        #expect(ParticipantAvatar.hue(for: "0xABC") == ParticipantAvatar.hue(for: "0xabc"))
        #expect(ParticipantAvatar.hue(for: "alice") != ParticipantAvatar.hue(for: "bob"))
        #expect(ParticipantAvatar.monogramSource("@alice") == "alice")
        #expect(ParticipantAvatar.monogramSource("0x9c3e…11aa") == "9c3e…11aa")
        #expect(ParticipantAvatar.isPerson(Participant(kind: .invitePeer)))
        #expect(!ParticipantAvatar.isPerson(Participant(kind: .owner)))
    }

    @Test func channelSendersReadAsVia() {
        let sender = Participant(kind: .channelSender, channel: "slack", channelUsername: "bob")
        #expect(ParticipantFormatter.short(sender) == "@bob via Slack")
    }
}
