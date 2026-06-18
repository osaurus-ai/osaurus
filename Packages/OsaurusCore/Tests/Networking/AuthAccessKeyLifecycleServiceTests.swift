//
//  AuthAccessKeyLifecycleServiceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct AuthAccessKeyLifecycleServiceTests {
    @Test func create_normalizesLabelAndRejectsBlankLabels() throws {
        let manager = FakeAccessKeyLifecycleManager()
        let service = AccessKeyLifecycleService(manager: manager)

        let created = try service.create(label: "  Desktop   Client  ", expiration: .days90)
        #expect(created.info.label == "Desktop Client")

        #expect(throws: AccessKeyLifecycleError.emptyLabel) {
            _ = try service.create(label: "   ", expiration: .days90)
        }
    }

    @Test func create_rejectsOverlongLabelsBeforeKeyGeneration() {
        let manager = FakeAccessKeyLifecycleManager()
        let service = AccessKeyLifecycleService(manager: manager)
        let longLabel = String(repeating: "a", count: AccessKeyLifecycleService.maximumLabelLength + 1)

        #expect(throws: AccessKeyLifecycleError.labelTooLong(80)) {
            _ = try service.create(label: longLabel, expiration: .days90)
        }
        #expect(manager.generatedLabels.isEmpty)
    }

    @Test func revokeAndRemove_deletesMetadataAfterRecordingRevocation() throws {
        let existing = AccessKeyInfo.fixture(label: "CLI")
        let manager = FakeAccessKeyLifecycleManager(keys: [existing])
        let service = AccessKeyLifecycleService(manager: manager)

        let removed = try service.revokeAndRemove(id: existing.id)

        #expect(removed.id == existing.id)
        #expect(manager.reloadCount == 1)
        #expect(manager.deletedIds == [existing.id])
        #expect(manager.listKeys().isEmpty)
    }

    @Test func revokeAndRemove_reportsPersistenceFailures() {
        let existing = AccessKeyInfo.fixture(label: "Sticky")
        let manager = FakeAccessKeyLifecycleManager(keys: [existing])
        manager.keepDeletedIdsInMetadata = true
        let service = AccessKeyLifecycleService(manager: manager)

        #expect(throws: AccessKeyLifecycleError.removalDidNotPersist) {
            _ = try service.revokeAndRemove(id: existing.id)
        }
    }
}

private final class FakeAccessKeyLifecycleManager: AccessKeyLifecycleManaging {
    var keys: [AccessKeyInfo]
    var generatedLabels: [String] = []
    var generatedAgentIndexes: [UInt32?] = []
    var deletedIds: [UUID] = []
    var reloadCount = 0
    var keepDeletedIdsInMetadata = false

    init(keys: [AccessKeyInfo] = []) {
        self.keys = keys
    }

    func generate(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32?
    ) throws -> (fullKey: String, info: AccessKeyInfo) {
        generatedLabels.append(label)
        generatedAgentIndexes.append(agentIndex)
        let info = AccessKeyInfo.fixture(label: label, expiration: expiration)
        keys.append(info)
        return ("osk-v1.fake.\(info.id.uuidString)", info)
    }

    func delete(id: UUID) {
        deletedIds.append(id)
        guard !keepDeletedIdsInMetadata else { return }
        keys.removeAll { $0.id == id }
    }

    func listKeys() -> [AccessKeyInfo] {
        keys
    }

    func reload() {
        reloadCount += 1
    }
}

private extension AccessKeyInfo {
    static func fixture(
        label: String,
        expiration: AccessKeyExpiration = .days90,
        id: UUID = UUID()
    ) -> AccessKeyInfo {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return AccessKeyInfo(
            id: id,
            label: label,
            prefix: "osk-v1.fake",
            nonce: id.uuidString.lowercased(),
            cnt: 1,
            iss: "0x1111111111111111111111111111111111111111",
            aud: "0x1111111111111111111111111111111111111111",
            createdAt: created,
            expiration: expiration,
            expiresAt: expiration.expirationDate(from: created)
        )
    }
}
