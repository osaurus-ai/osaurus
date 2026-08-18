//
//  MasterMnemonicStoreIsolationTests.swift
//  OsaurusCoreTests
//
//  Keep the direct Security.framework mnemonic store behind the shared
//  disabled-test-host policy.
//

import Foundation
import LocalAuthentication
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite("MasterMnemonicStore test-host isolation", .serialized)
struct MasterMnemonicStoreIsolationTests {
    @Test("disabled test hosts fail closed for mnemonic store operations")
    func disabledHostFailsClosed() {
        #expect(ProcessDataRootPolicy.isRecognizedTestHostProcess)
        #expect(KeychainQueryHelpers.disablesKeychainForProcess)

        let words = Array(repeating: "abandon", count: 24)
        do {
            try MasterMnemonicStore.store(words)
            Issue.record("Disabled test host unexpectedly wrote the recovery phrase")
        } catch let error as OsaurusIdentityError {
            guard case .keychainWriteFailed = error else {
                Issue.record("Expected keychainWriteFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected OsaurusIdentityError, got \(error)")
        }

        #expect(!MasterMnemonicStore.exists())

        let context = LAContext()
        context.interactionNotAllowed = true
        do {
            _ = try MasterMnemonicStore.load(context: context)
            Issue.record("Disabled test host unexpectedly read the recovery phrase")
        } catch let error as OsaurusIdentityError {
            guard case .keychainReadFailed = error else {
                Issue.record("Expected keychainReadFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected OsaurusIdentityError, got \(error)")
        }

        #expect(MasterMnemonicStore.delete())
    }

    @Test("each mnemonic operation gates Security.framework access")
    func sourceGatesPrecedeSecurityCalls() throws {
        let source = try Self.source()

        let store = try Self.method(
            in: source,
            declaration: "public static func store",
            endMarker: "    // MARK: - Existence"
        )
        try Self.requireGateBeforeCall(
            in: store,
            call: "SecItemAdd",
            operation: "store"
        )

        let exists = try Self.method(
            in: source,
            declaration: "public static func exists",
            endMarker: "    // MARK: - Read"
        )
        try Self.requireGateBeforeCall(
            in: exists,
            call: "SecItemCopyMatching",
            operation: "exists"
        )

        let load = try Self.method(
            in: source,
            declaration: "public static func load",
            endMarker: "    // MARK: - Delete"
        )
        try Self.requireGateBeforeCall(
            in: load,
            call: "SecItemCopyMatching",
            operation: "load"
        )

        let delete = try Self.method(
            in: source,
            declaration: "public static func delete",
            endMarker: nil
        )
        try Self.requireGateBeforeCall(
            in: delete,
            call: "SecItemDelete",
            operation: "delete"
        )
    }

    private static func source() throws -> String {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: coreRoot.appendingPathComponent(
                "Identity/MasterMnemonicStore.swift"
            ),
            encoding: .utf8
        )
    }

    private static func method(
        in source: String,
        declaration: String,
        endMarker: String?
    ) throws -> String {
        let start = try #require(source.range(of: declaration)?.lowerBound)
        let tail = source[start...]
        guard let endMarker else { return String(tail) }
        let end = try #require(tail.range(of: endMarker)?.lowerBound)
        return String(tail[..<end])
    }

    private static func requireGateBeforeCall(
        in method: String,
        call: String,
        operation: String
    ) throws {
        let securityCall = try #require(method.range(of: call))
        let prefix = method[..<securityCall.lowerBound]
        let gate = try #require(
            prefix.range(
                of: "KeychainQueryHelpers.performIfServiceAccessRemainsAllowed",
                options: .backwards
            )
        )
        #expect(
            gate.lowerBound < securityCall.lowerBound,
            "\(operation) must revalidate its service immediately before \(call)"
        )
    }
}
