//
//  WorkspaceAuditLogTests.swift
//  osaurus
//
//  Hash-chained audit trail: append/verify, tamper detection (edited record,
//  truncated tail, reordered lines, removed head), export, event coverage for
//  the typed recorders, and persistence of workspace key records across a
//  host restart (attribution + revocation survive).
//

import Foundation
import Testing

@testable import OsaurusCore

private func makeTempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeLog(_ directory: URL) async -> WorkspaceAuditLog {
    let log = WorkspaceAuditLog()
    await log.setSeams(directoryURL: { directory })
    return log
}

/// Whole-second date so records round-trip byte-equal through ISO 8601.
private func wholeSeconds(fromNow seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + seconds).rounded(.down))
}

private func sampleRecord(
    role: String = "member",
    expiresIn: TimeInterval = 600
) -> WorkspaceAgentAccessHost.WorkspaceKeyRecord {
    WorkspaceAgentAccessHost.WorkspaceKeyRecord(
        keyId: UUID(),
        workspaceId: "ws-audit",
        accountId: "acct-9",
        wallet: TestKeys.aliceAddress.lowercased(),
        role: role,
        agentAddressLower: "0x00000000000000000000000000000000deadbeef",
        attestationToken: "tok.sig",
        attestationExpiresAt: wholeSeconds(fromNow: expiresIn)
    )
}

// MARK: - Chain

@Suite("Workspace audit log chain")
struct WorkspaceAuditLogChainTests {
    @Test func appendBuildsAVerifiableChain() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-chain"

        let first = try #require(await log.append(.workspaceCreated, workspaceId: ws, actor: .me(), details: ["name": "Ops"]))
        let second = try #require(await log.append(.agentShared, workspaceId: ws, agentAddress: "0xABC", agentName: "HR"))
        let third = try #require(await log.append(.inviteCreated, workspaceId: ws, target: "inv-1"))

        #expect(first.seq == 1)
        #expect(first.prevHash == WorkspaceAuditLog.genesisHash)
        #expect(second.seq == 2)
        #expect(second.prevHash == first.hash)
        #expect(third.prevHash == second.hash)
        #expect(second.agentAddress == "0xabc")  // normalized
        #expect(first.hash.count == 64)

        let records = await log.records(workspaceId: ws)
        #expect(records.map(\.seq) == [1, 2, 3])
        #expect(records.map(\.event) == [.workspaceCreated, .agentShared, .inviteCreated])

        let verification = await log.verify(workspaceId: ws)
        #expect(verification.isIntact)
        #expect(verification.recordCount == 3)

        // Head sidecar points at the tail.
        let head = try String(contentsOf: dir.appendingPathComponent("\(ws).head"), encoding: .utf8)
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "3:\(third.hash)")
    }

    @Test func emptyWorkspaceVerifiesAsIntactWithZeroRecords() async {
        let log = await makeLog(makeTempDirectory("audit"))
        let verification = await log.verify(workspaceId: "never-written")
        #expect(verification.isIntact)
        #expect(verification.recordCount == 0)
        #expect(await log.records(workspaceId: "never-written").isEmpty)
        #expect(await log.exportURL(workspaceId: "never-written") == nil)
    }

    @Test func editingAMiddleRecordIsDetected() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-tamper"
        for i in 0 ..< 4 {
            _ = await log.append(.runStarted, workspaceId: ws, target: "run-\(i)", details: ["model": "m\(i)"])
        }
        let file = dir.appendingPathComponent("\(ws).jsonl")
        var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        // Flip a detail value in record #2 without touching its stored hash.
        lines[1] = lines[1].replacingOccurrences(of: "\"m1\"", with: "\"gpt-999\"")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let verification = await log.verify(workspaceId: ws)
        #expect(!verification.isIntact)
        #expect(verification.problems.contains(.hashMismatch(seq: 2)))
        // Later links are still consistent with the (unchanged) stored hashes.
        #expect(!verification.problems.contains(.brokenLink(seq: 3)))
    }

    @Test func truncatingTheTailIsDetectedViaHead() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-truncate"
        for _ in 0 ..< 3 {
            _ = await log.append(.runFinished, workspaceId: ws, details: ["success": "true"])
        }
        let file = dir.appendingPathComponent("\(ws).jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        try (lines.prefix(2).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let verification = await log.verify(workspaceId: ws)
        #expect(!verification.isIntact)
        #expect(verification.problems.contains(.headMismatch(expectedSeq: 3, actualSeq: 2)))
        #expect(verification.recordCount == 2)
    }

    @Test func deletingAMiddleRecordBreaksSequenceAndLink() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-delete"
        for _ in 0 ..< 3 {
            _ = await log.append(.keyMinted, workspaceId: ws)
        }
        let file = dir.appendingPathComponent("\(ws).jsonl")
        var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        lines.remove(at: 1)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let verification = await log.verify(workspaceId: ws)
        #expect(verification.problems.contains(.sequenceGap(seq: 3, expected: 2)))
        #expect(verification.problems.contains(.brokenLink(seq: 3)))
    }

    @Test func removingTheHeadSidecarIsDetected() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-nohead"
        _ = await log.append(.keyRevoked, workspaceId: ws)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(ws).head"))
        let verification = await log.verify(workspaceId: ws)
        #expect(!verification.isIntact)
        #expect(verification.problems.contains(.headMismatch(expectedSeq: 0, actualSeq: 1)))
    }

    @Test func garbageLineIsReportedAndChainContinues() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-garbage"
        _ = await log.append(.scopeDenied, workspaceId: ws)
        let file = dir.appendingPathComponent("\(ws).jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        let verification = await log.verify(workspaceId: ws)
        #expect(verification.problems.contains(.malformedLine(lineNumber: 2)))
        #expect(verification.recordCount == 1)
    }

    @Test func reopeningContinuesTheChainFromDisk() async throws {
        let dir = makeTempDirectory("audit")
        let ws = "ws-reopen"
        let firstLog = await makeLog(dir)
        let a = try #require(await firstLog.append(.workspaceCreated, workspaceId: ws))
        // A fresh actor (host restart) must pick up seq/hash from the file.
        let secondLog = await makeLog(dir)
        let b = try #require(await secondLog.append(.agentShared, workspaceId: ws))
        #expect(b.seq == a.seq + 1)
        #expect(b.prevHash == a.hash)
        #expect(await secondLog.verify(workspaceId: ws).isIntact)
    }

    @Test func exportCopiesLogAndHead() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let ws = "ws-export"
        _ = await log.append(.memberRemoved, workspaceId: ws, target: "acct-2")
        let destination = makeTempDirectory("audit-export")
        let exported = try await log.export(workspaceId: ws, to: destination)
        #expect(exported.lastPathComponent == "\(ws).jsonl")
        #expect(FileManager.default.fileExists(atPath: exported.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("\(ws).head").path))
        let original = try Data(contentsOf: dir.appendingPathComponent("\(ws).jsonl"))
        #expect(try Data(contentsOf: exported) == original)
        #expect(await log.exportURL(workspaceId: ws) == dir.appendingPathComponent("\(ws).jsonl"))
    }

    @Test func workspaceIdIsSanitizedForTheFileName() async throws {
        let dir = makeTempDirectory("audit")
        let log = await makeLog(dir)
        let hostile = "../../escape/ws"
        let record = try #require(await log.append(.workspaceCreated, workspaceId: hostile))
        // The record keeps the original id; the file name is constrained.
        #expect(record.workspaceId == hostile)
        #expect(WorkspaceAuditLog.sanitizeWorkspaceId(hostile) == "escapews")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.contains("escapews.jsonl"))
        #expect(await log.append(.workspaceCreated, workspaceId: "///") == nil)
    }

    @Test func detailsAreBoundedAndNeverCarryLongContent() async throws {
        let log = await makeLog(makeTempDirectory("audit"))
        let record = try #require(
            await log.append(
                .runFinished, workspaceId: "ws-bound",
                details: ["summary": String(repeating: "x", count: 5000), "k": "v"]
            )
        )
        #expect(record.details["summary"]?.count == 512)
        #expect(record.details["k"] == "v")
    }

    @Test func observersAreNotifiedPerWorkspace() async throws {
        let log = await makeLog(makeTempDirectory("audit"))
        let box = ObservedIds()
        let id = await log.addObserver { ws in box.append(ws) }
        _ = await log.append(.inviteRevoked, workspaceId: "ws-obs")
        // Observer hop is main-actor; give it a beat.
        for _ in 0 ..< 50 where box.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(box.values == ["ws-obs"])
        await log.removeObserver(id)
        _ = await log.append(.inviteRevoked, workspaceId: "ws-obs")
        try await Task.sleep(for: .milliseconds(30))
        #expect(box.values == ["ws-obs"])
    }

    private final class ObservedIds: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _values
        }
        func append(_ v: String) {
            lock.lock()
            defer { lock.unlock() }
            _values.append(v)
        }
    }
}

// MARK: - Typed recorders

@Suite("Workspace audit typed recorders")
struct WorkspaceAuditRecorderTests {
    @Test func grantMintsTwoRecordsWithRoleAndKeyId() async throws {
        let log = await makeLog(makeTempDirectory("audit"))
        let record = sampleRecord(role: "admin")
        await log.recordAttestationGranted(record: record, agentName: "HR", sealed: true)
        let rows = await log.records(workspaceId: record.workspaceId)
        #expect(rows.map(\.event) == [.attestationGranted, .keyMinted])
        #expect(rows[0].actor?.wallet == record.wallet)
        #expect(rows[0].actor?.role == "admin")
        #expect(rows[0].actor?.accountId == "acct-9")
        #expect(rows[0].agentName == "HR")
        #expect(rows[1].target == record.keyId.uuidString)
        #expect(rows[1].details["sealed"] == "true")
        // The attestation token itself must never be persisted in the trail.
        let raw = try String(contentsOf: try #require(await log.exportURL(workspaceId: record.workspaceId)), encoding: .utf8)
        #expect(!raw.contains("tok.sig"))
    }

    @Test func revocationCarriesReason() async {
        let log = await makeLog(makeTempDirectory("audit"))
        let record = sampleRecord()
        await log.recordKeyRevoked(record: record, reason: .agentUnshared)
        await log.recordKeyRevoked(record: record, reason: .workspaceDeleted)
        await log.recordKeyRevoked(record: record, reason: .replacedByRefresh)
        let rows = await log.records(workspaceId: record.workspaceId)
        #expect(rows.map { $0.details["reason"] } == ["agent_unshared", "workspace_deleted", "replaced_by_refresh"])
        #expect(rows.allSatisfy { $0.event == .keyRevoked })
    }

    @Test func runLifecycleRecordsModelToolsAndOutcome() async {
        let log = await makeLog(makeTempDirectory("audit"))
        let record = sampleRecord()
        let agentId = UUID()
        await log.recordRunStarted(record: record, agentId: agentId, runKey: "r1", model: "m", callerName: "Alice")
        await log.recordRunFinished(
            record: record, agentId: agentId, runKey: "r1", model: "m",
            success: false, summary: "Stopped", toolNames: ["read_file", "shell"], toolErrorCount: 1
        )
        await log.recordRunStopped(record: record, agentId: agentId, runKey: "r1")
        await log.recordRunRejected(record: record, agentId: agentId, reason: "model_override", detail: "gpt-x")

        let rows = await log.records(workspaceId: record.workspaceId)
        #expect(rows.map(\.event) == [.runStarted, .runFinished, .runStoppedByOwner, .runRejected])
        #expect(rows[0].actor?.name == "Alice")
        #expect(rows[0].details["model"] == "m")
        #expect(rows[1].details["tools"] == "read_file,shell")
        #expect(rows[1].details["tool_count"] == "2")
        #expect(rows[1].details["tool_errors"] == "1")
        #expect(rows[1].details["success"] == "false")
        #expect(rows[2].actor?.isSelf == true)
        #expect(rows[2].details["caller_wallet"] == record.wallet)
        #expect(rows[3].details["reason"] == "model_override")
        #expect(rows[3].details["detail"] == "gpt-x")
    }

    @Test func attestationDeniedCarriesReasonCodeAndStatus() async throws {
        let log = await makeLog(makeTempDirectory("audit"))
        let factory = ScopePolicyAttestationFactory()
        let token = try factory.token(workspaceId: "ws-denied", wallet: TestKeys.bobAddress, role: "viewer")
        let attestation = try WorkspaceMembershipAttestation.verify(
            token: token, publicKeyBase64URL: factory.publicKeyBase64URL
        )
        await log.recordAttestationDenied(attestation: attestation, agentAddress: "0xABC", rejection: .notShared)
        let rows = await log.records(workspaceId: "ws-denied")
        #expect(rows.count == 1)
        #expect(rows[0].event == .attestationDenied)
        #expect(rows[0].actor?.wallet == TestKeys.bobAddress.lowercased())
        #expect(rows[0].actor?.role == "viewer")
        #expect(rows[0].details["reason"] == "not_shared")
        #expect(rows[0].details["http_status"] == String(WorkspaceRedeemRejection.notShared.httpStatus))
    }

    @Test func ownerActionsAreAttributedToSelf() async {
        let log = await makeLog(makeTempDirectory("audit"))
        await log.recordOwnerAction(.memberRoleChanged, workspaceId: "ws-own", target: "acct-2", details: ["role": "viewer"])
        let rows = await log.records(workspaceId: "ws-own")
        #expect(rows.first?.actor?.isSelf == true)
        #expect(rows.first?.target == "acct-2")
    }

    @Test func everyEventKindHasACategory() {
        for kind in WorkspaceAuditEventKind.allCases {
            _ = kind.category
        }
        #expect(WorkspaceAuditEventKind.scopeDenied.category == .denials)
        #expect(WorkspaceAuditEventKind.keyRevoked.category == .access)
        #expect(WorkspaceAuditEventKind.runStoppedByOwner.category == .runs)
        #expect(WorkspaceAuditEventKind.billingPreferenceChanged.category == .administration)
    }
}

// MARK: - Key record persistence

@Suite("Workspace key record persistence", .serialized)
struct WorkspaceKeyRecordPersistenceTests {
    @Test func recordRoundTripsWithRoleAndDefaultsLegacyRole() throws {
        let record = sampleRecord(role: "admin")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoded = try decoder.decode(WorkspaceAgentAccessHost.WorkspaceKeyRecord.self, from: data)
        #expect(decoded.role == "admin")
        #expect(decoded.keyId == record.keyId)
        #expect(decoded.attestationToken == "tok.sig")

        // Records written before `role` existed still load.
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "role")
        let legacy = try decoder.decode(
            WorkspaceAgentAccessHost.WorkspaceKeyRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.role == "member")
    }

    @Test func persistedRecordsSurviveAHostRestartAndExpiredOnesArePruned() async throws {
        let dir = makeTempDirectory("keys")
        let file = dir.appendingPathComponent("keys.json")
        let live = sampleRecord(expiresIn: 600)
        let expired = sampleRecord(expiresIn: -5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["nonce-live": live, "nonce-expired": expired]).write(to: file)

        let host = WorkspaceAgentAccessHost()
        await host.setSeams(keyRecordsFileURL: { file })

        // Attribution restored from disk...
        let restored = await host.workspaceKeyRecord(forKeyNonce: "nonce-live")
        #expect(restored == live)
        // ...expired records are gone...
        #expect(await host.workspaceKeyRecord(forKeyNonce: "nonce-expired") == nil)
        #expect(await host.liveKeyRecords() == [live])
        // ...and the prune was written back.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(
            [String: WorkspaceAgentAccessHost.WorkspaceKeyRecord].self, from: Data(contentsOf: file)
        )
        #expect(onDisk.keys.sorted() == ["nonce-live"])
    }

    @Test func invalidateRemovesFromDiskAndAudits() async throws {
        let dir = makeTempDirectory("keys")
        let file = dir.appendingPathComponent("keys.json")
        let auditDir = makeTempDirectory("audit")
        let record = sampleRecord()
        let other = WorkspaceAgentAccessHost.WorkspaceKeyRecord(
            keyId: UUID(), workspaceId: "ws-other", accountId: "a", wallet: record.wallet, role: "member",
            agentAddressLower: record.agentAddressLower, attestationToken: "t", attestationExpiresAt: wholeSeconds(fromNow: 600)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["n1": record, "n2": other]).write(to: file)

        // Point the shared audit log at a scratch directory for this test
        // (the host's revocation path records through the shared instance).
        await WorkspaceAuditLog.shared.setSeams(directoryURL: { auditDir })
        defer { Task { await WorkspaceAuditLog.shared.setSeams(directoryURL: { OsaurusPaths.workspaceAudit() }) } }

        let host = WorkspaceAgentAccessHost()
        await host.setSeams(keyRecordsFileURL: { file })
        await host.invalidateKeys(workspaceId: record.workspaceId, agentAddress: record.agentAddressLower.uppercased())

        #expect(await host.workspaceKeyRecord(forKeyNonce: "n1") == nil)
        #expect(await host.workspaceKeyRecord(forKeyNonce: "n2") == other)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(
            [String: WorkspaceAgentAccessHost.WorkspaceKeyRecord].self, from: Data(contentsOf: file)
        )
        #expect(onDisk.keys.sorted() == ["n2"])

        let audit = await WorkspaceAuditLog.shared.records(workspaceId: record.workspaceId)
        #expect(audit.map(\.event) == [.keyRevoked])
        #expect(audit.first?.details["reason"] == "agent_unshared")
        #expect(audit.first?.target == record.keyId.uuidString)

        // Whole-workspace revocation empties the file (removed, not left as `{}`).
        await host.invalidateKeys(workspaceId: "ws-other")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await host.liveKeyRecords().isEmpty)
    }
}
