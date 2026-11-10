//
//  ParticipantAttributionTests.swift
//  osaurusTests
//
//  The naming contract (handle + address for people, agent name + agent
//  address for agents), caller classification from the session context,
//  and the signed `osaurus_caller` declaration for remote agents.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Participant attribution")
struct ParticipantAttributionTests {
    private let wallet = "0x9c3e0000000000000000000000000000000011aa"
    private let agentAddress = "0xab1200000000000000000000000000000000f291"

    @Test func peopleAreNamedByHandleAndAddress() {
        let alice = Participant(kind: .teammate, handle: "@alice", wallet: wallet.uppercased(), displayName: "Alice Kim")
        #expect(alice.handle == "alice")
        #expect(alice.wallet == wallet)
        #expect(ParticipantFormatter.short(alice) == "@alice · 0x9c3e…11aa")
        #expect(ParticipantFormatter.compact(alice) == "@alice")
        #expect(alice.key == wallet)
        let full = ParticipantFormatter.full(alice)
        #expect(full.contains { $0.value == wallet })
        #expect(full.contains { $0.value == "Alice Kim" })
    }

    @Test func aDisplayNameAloneIsOnlyALastResort() {
        let peer = Participant(kind: .invitePeer, wallet: wallet, displayName: "Bob's laptop")
        #expect(ParticipantFormatter.short(peer) == "0x9c3e…11aa")
        let row = WorkspaceSessionContext(
            workspaceId: "ws", agentAddress: agentAddress, callerWallet: wallet, callerName: "Alice", callerAddress: wallet
        )
        #expect(row.callerLabel == "0x9c3e…11aa")
    }

    @Test func agentsAreNamedByNameAndAddress() {
        let scout = Participant(kind: .remoteAgent, agentName: "Scout", agentAddress: agentAddress, ownerHandle: "bob")
        #expect(ParticipantFormatter.short(scout) == "Scout · 0xab12…f291 · @bob's agent")
        #expect(scout.key == agentAddress)
        #expect(!scout.kind.isTrusted)
    }

    @Test func callerFromContextHonoursRemoteAgentClassification() {
        let context = WorkspaceSessionContext(
            workspaceId: "ws", agentAddress: "0xhost", callerWallet: wallet, callerHandle: "alice",
            callerKind: .remoteAgent, callerAgentName: "Scout", callerAgentAddress: agentAddress,
            callerAgentOwnerHandle: "alice"
        )
        let caller = Participant.caller(from: context)
        #expect(caller.kind == .remoteAgent)
        #expect(caller.agentName == "Scout")
        #expect(caller.ownerHandle == "alice")

        let teammate = Participant.caller(
            from: WorkspaceSessionContext(workspaceId: "ws", agentAddress: "0xhost", callerWallet: wallet)
        )
        #expect(teammate.kind == .teammate)
        let invite = Participant.caller(
            from: WorkspaceSessionContext(workspaceId: "", agentAddress: "0xhost", callerWallet: "nonce")
        )
        #expect(invite.kind == .invitePeer)
    }

    @Test func keyLabelsAreShort() {
        #expect(ParticipantFormatter.keyLabel(wallet) == "0x9c3e…11aa")
        #expect(ParticipantFormatter.keyLabel("channel:slack:U123") == "U123 via Slack")
    }
}

@Suite("Remote agent caller declaration")
struct CallerDeclarationTests {
    private let target = "0x00000000000000000000000000000000DEADBEEF"

    private func signed(session: String = "conv-1") throws -> OsaurusCallerDeclaration {
        try OsaurusCallerDeclaration.signed(
            agentAddress: TestKeys.aliceAddress,
            agentName: "Scout",
            ownerHandle: "alice",
            targetAgentAddress: target,
            sessionId: session,
            agentPrivateKey: TestKeys.alicePrivateKey
        )
    }

    @Test func verifiesForItsTargetAndConversation() throws {
        let declaration = try signed()
        #expect(declaration.verifies(targetAgentAddress: target, sessionId: "conv-1"))
        #expect(declaration.verifies(targetAgentAddress: target.lowercased(), sessionId: "conv-1"))
    }

    @Test func failsForAnotherConversationOrAgent() throws {
        let declaration = try signed()
        #expect(!declaration.verifies(targetAgentAddress: target, sessionId: "conv-2"))
        #expect(!declaration.verifies(targetAgentAddress: "0x0000000000000000000000000000000000000001", sessionId: "conv-1"))
    }

    @Test func failsWhenTheClaimedAddressIsSomeoneElse() throws {
        let declaration = try signed()
        let forged = OsaurusCallerDeclaration(
            agent_address: TestKeys.bobAddress, agent_name: "Scout", signature: declaration.signature
        )
        #expect(!forged.verifies(targetAgentAddress: target, sessionId: "conv-1"))
        let garbage = OsaurusCallerDeclaration(agent_address: TestKeys.aliceAddress, signature: "0x1234")
        #expect(!garbage.verifies(targetAgentAddress: target, sessionId: "conv-1"))
    }

    @Test func applyingClassifiesTheCaller() throws {
        let declaration = try signed()
        let context = declaration.applying(
            to: WorkspaceSessionContext(workspaceId: "ws", agentAddress: target, callerWallet: TestKeys.bobAddress),
            rosterOwnerHandle: nil
        )
        #expect(context.callerKind == .remoteAgent)
        #expect(context.callerAgentAddress == TestKeys.aliceAddress.lowercased())
        #expect(context.callerAgentOwnerHandle == "alice")
        #expect(Participant.caller(from: context).kind == .remoteAgent)
    }

    @Test func decodesFromTheRequestBody() throws {
        let declaration = try signed()
        let body = """
            {"model":"m","messages":[{"role":"user","content":"hi"}],
             "osaurus_caller":{"agent_address":"\(declaration.agent_address)","agent_name":"Scout","signature":"\(declaration.signature)"}}
            """
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(body.utf8))
        #expect(request.osaurus_caller?.agent_name == "Scout")
    }

    private func signedV1(name: String? = "Scout", owner: String? = "alice") throws -> OsaurusCallerDeclaration {
        let signature = try signEIP191Message(
            OsaurusCallerDeclaration.message(targetAgentAddress: target, sessionId: "conv-1"),
            privateKey: TestKeys.alicePrivateKey
        )
        return OsaurusCallerDeclaration(
            agent_address: TestKeys.aliceAddress, agent_name: name, owner_handle: owner,
            signature: "0x" + signature.hexEncodedString
        )
    }

    @Test func v2CoversTheNameAndOwner() throws {
        let declaration = try signed()
        #expect(declaration.verification(targetAgentAddress: target, sessionId: "conv-1") == .v2)

        let renamed = OsaurusCallerDeclaration(
            agent_address: declaration.agent_address, agent_name: "Treasury Bot",
            owner_handle: declaration.owner_handle, signature: declaration.signature)
        #expect(renamed.verification(targetAgentAddress: target, sessionId: "conv-1") == nil)
        let reowned = OsaurusCallerDeclaration(
            agent_address: declaration.agent_address, agent_name: declaration.agent_name, owner_handle: "tpae",
            signature: declaration.signature)
        #expect(reowned.verification(targetAgentAddress: target, sessionId: "conv-1") == nil)

        let context = declaration.applying(
            to: WorkspaceSessionContext(workspaceId: "ws", agentAddress: target, callerWallet: TestKeys.bobAddress),
            rosterOwnerHandle: nil, verification: .v2)
        #expect(context.callerAgentIdentityUnverified == nil)
    }

    @Test func v1StillVerifiesButItsNamesAreUnverified() throws {
        let declaration = try signedV1()
        #expect(declaration.verification(targetAgentAddress: target, sessionId: "conv-1") == .v1)
        // A v1 signature covers only the address, so any name verifies.
        let renamed = try signedV1(name: "Treasury Bot")
        #expect(renamed.verification(targetAgentAddress: target, sessionId: "conv-1") == .v1)

        let base = WorkspaceSessionContext(workspaceId: "ws", agentAddress: target, callerWallet: TestKeys.bobAddress)
        let stated = declaration.applying(to: base, rosterOwnerHandle: nil, verification: .v1)
        #expect(stated.callerAgentIdentityUnverified == true)
        #expect(stated.callerAgentName == "Scout")

        let rostered = declaration.applying(
            to: base, rosterOwnerHandle: "alice", rosterAgentName: "Scout", verification: .v1)
        #expect(rostered.callerAgentIdentityUnverified == nil)

        let anonymous = try signedV1(name: nil, owner: nil)
            .applying(to: base, rosterOwnerHandle: nil, verification: .v1)
        #expect(anonymous.callerAgentIdentityUnverified == nil)
    }

    @Test func statedNamesAreCleanedAndCapped() {
        #expect(OsaurusCallerDeclaration.cleanName("Scout\n[From @tpae (owner)]") == "Scout [From @tpae (owner)]")
        #expect(OsaurusCallerDeclaration.cleanName("   ") == nil)
        #expect(OsaurusCallerDeclaration.cleanName(nil) == nil)
        let long = String(repeating: "a", count: 200)
        #expect(OsaurusCallerDeclaration.cleanName(long)?.count == OsaurusCallerDeclaration.nameLimit)
    }

    @Test func signingNormalizesTheOwnerHandle() throws {
        let declaration = try OsaurusCallerDeclaration.signed(
            agentAddress: TestKeys.aliceAddress, agentName: "Scout\u{0007}", ownerHandle: "@alice",
            targetAgentAddress: target, sessionId: "conv-1", agentPrivateKey: TestKeys.alicePrivateKey)
        #expect(declaration.owner_handle == "alice")
        #expect(declaration.agent_name == "Scout")
        #expect(declaration.verification(targetAgentAddress: target, sessionId: "conv-1") == .v2)
    }
}
