//
//  SpawnRemoteModelIdentityTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Spawn remote model identity encoding")
struct SpawnRemoteModelIdentityTests {
    @Test("round-trips provider UUID and slash-containing raw model slug")
    func roundTrip() throws {
        let providerID = UUID(uuidString: "C9412118-D6C8-4BC0-90D9-5C686C5A54C8")!
        let id = try #require(
            SpawnRemoteModelIdentity.make(
                providerId: providerID,
                modelId: "organization/team/model"
            )
        )
        let parsed = try #require(SpawnRemoteModelIdentity.parse(id))
        #expect(parsed.providerId == providerID)
        #expect(parsed.modelId == "organization/team/model")
    }

    @Test("rejects malformed or empty identities")
    func rejectsMalformedValues() {
        #expect(SpawnRemoteModelIdentity.make(providerId: UUID(), modelId: "  ") == nil)
        #expect(SpawnRemoteModelIdentity.parse(nil) == nil)
        #expect(SpawnRemoteModelIdentity.parse("") == nil)
        #expect(SpawnRemoteModelIdentity.parse("remote-provider:not-a-uuid/model") == nil)
        #expect(SpawnRemoteModelIdentity.parse("remote-provider:\(UUID())/") == nil)
        #expect(SpawnRemoteModelIdentity.parse("ordinary-provider/model") == nil)
    }
}
