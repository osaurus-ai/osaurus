//
//  ForwardVersionClassificationTests.swift
//  OsaurusCoreTests — Storage
//
//  A store refused because its file came from a NEWER build must classify as
//  `.forwardVersion`, never `.migration`.
//
//  The distinction is the whole point. `.migration` tells the user "a schema
//  migration failed" and offers Reset — which, for an intact file written by a
//  newer Osaurus, destroys exactly the data they opened the panel worried
//  about. Users bounce between release channels and betas, so a downgrade is a
//  routine state, not a fault.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ForwardVersionClassificationTests {

    @Test func forwardVersionRefusalIsNotAMigrationFailure() {
        let memory = MemoryDatabaseError.databaseFromNewerVersion(found: 11, expected: 10)
        #expect(StorageOpenIssueKind.classify(memory) == .forwardVersion)

        let knowledge = KnowledgeDatabaseError.databaseFromNewerVersion(found: 9, expected: 4)
        #expect(StorageOpenIssueKind.classify(knowledge) == .forwardVersion)
    }

    /// The classifier is structural, not string-matched. The refusal messages
    /// contain "schema v", which the `.migration` rule also matches, so a
    /// reordering or a reworded message must not silently start recommending
    /// Reset again.
    @Test func classificationDoesNotDependOnMessageWording() {
        let error = MemoryDatabaseError.databaseFromNewerVersion(found: 11, expected: 10)
        #expect(error.localizedDescription.lowercased().contains("schema v"))
        #expect(StorageOpenIssueKind.classify(error) == .forwardVersion)
    }

    /// Conformance is per VALUE, not per type. Every other case on the same
    /// enum is a real fault and must keep its own classification.
    @Test func otherErrorsOnTheSameEnumAreUnaffected() {
        #expect(!MemoryDatabaseError.failedToOpen("disk I/O").isForwardVersion)
        #expect(!MemoryDatabaseError.migrationFailed("v7 rebuild").isForwardVersion)
        #expect(!MemoryDatabaseError.notOpen.isForwardVersion)

        // A genuine migration failure still reads as one.
        #expect(
            StorageOpenIssueKind.classify(MemoryDatabaseError.migrationFailed("v7 rebuild"))
                == .migration
        )
        // "file is not a database" still reads as corruption, so Reset stays
        // the right advice there.
        #expect(
            StorageOpenIssueKind.classify(
                MemoryDatabaseError.failedToOpen("file is encrypted or is not a database")
            ) == .corrupt
        )
    }

    /// Memory's migrations are NOT additive (v5 drops tables, v7 drops a
    /// column, v10 drops an orphan column), so unlike the knowledge index it
    /// cannot simply open a schema-ahead file. Refusing is correct here; the
    /// bug was only ever what the UI then told the user to do about it.
    @Test func memoryStillRefusesRatherThanForwardOpening() {
        let error = MemoryDatabaseError.databaseFromNewerVersion(found: 11, expected: 10)
        let message = error.localizedDescription
        #expect(message.contains("Refusing to open"))
        #expect(message.contains("v11"))
        #expect(message.contains("v10"))
    }
}
