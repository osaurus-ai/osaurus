//
//  SandboxPathSanitizerTests.swift
//  osaurusTests
//
//  Pins down the rejection reasons for every failure mode of
//  `SandboxPathSanitizer.validate(_:agentHome:)`. Without these, the
//  model-facing errors could silently regress to "Invalid path" with no
//  hint about what's actually wrong.
//

import Foundation
import Testing

@testable import OsaurusCore

private let agentHome = "/workspace/agents/test-agent"

@Suite
struct SandboxPathSanitizerTests {

    @Test func relativePathResolvesUnderHome() {
        let result = SandboxPathSanitizer.validate("notes.txt", agentHome: agentHome)
        guard case .success(let resolved) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resolved == "\(agentHome)/notes.txt")
    }

    @Test func absolutePathUnderHomeIsAccepted() {
        let result = SandboxPathSanitizer.validate("\(agentHome)/sub/x", agentHome: agentHome)
        guard case .success(let resolved) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resolved == "\(agentHome)/sub/x")
    }

    @Test func absolutePathUnderSharedWorkspaceIsAccepted() {
        let result = SandboxPathSanitizer.validate("/workspace/shared/data.csv", agentHome: agentHome)
        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
    }

    @Test func emptyPathRejected() {
        let result = SandboxPathSanitizer.validate("", agentHome: agentHome)
        #expect(result == .failure(.empty))
    }

    @Test func traversalRejected() {
        let result = SandboxPathSanitizer.validate("../etc/passwd", agentHome: agentHome)
        #expect(result == .failure(.traversal))
    }

    @Test func nullByteRejected() {
        let result = SandboxPathSanitizer.validate("bad\0name", agentHome: agentHome)
        #expect(result == .failure(.nullByte))
    }

    @Test func dangerousCharactersRejected() {
        // Each of these breaks single-quoted shell escaping. Assert we
        // reject one distinct character so the model gets a specific
        // rejection reason instead of a generic "Invalid path".
        for ch: Character in [";", "|", "&", "$", "`", "'", "\""] {
            let path = "file\(ch)name.txt"
            let result = SandboxPathSanitizer.validate(path, agentHome: agentHome)
            #expect(result == .failure(.dangerousChar(ch)), "char=\(ch)")
        }
    }

    @Test func absolutePathOutsideAllowedRootsRejected() {
        let result = SandboxPathSanitizer.validate("/etc/passwd", agentHome: agentHome)
        #expect(result == .failure(.outsideAllowedRoots))
    }

    @Test func legacySanitizeReturnsNilOnFailure() {
        // Back-compat API kept for call sites that don't need the rejection
        // reason. Must not go stale from the Result-returning one.
        #expect(SandboxPathSanitizer.sanitize("", agentHome: agentHome) == nil)
        #expect(SandboxPathSanitizer.sanitize("../x", agentHome: agentHome) == nil)
        #expect(SandboxPathSanitizer.sanitize("ok.txt", agentHome: agentHome) == "\(agentHome)/ok.txt")
    }

    @Test func rejectionReasonsAreModelReadable() {
        // The `reason` strings are what end up in the model-facing error
        // envelope's `message`. Smoke-test the shape so nobody regresses
        // them to empty strings / Swift debug descriptions.
        #expect(SandboxPathRejection.empty.reason.contains("empty"))
        #expect(SandboxPathRejection.traversal.reason.contains(".."))
        #expect(SandboxPathRejection.nullByte.reason.contains("NUL"))
        #expect(SandboxPathRejection.dangerousChar("$").reason.contains("$"))
        #expect(SandboxPathRejection.outsideAllowedRoots.reason.contains("agent home"))
    }
}
