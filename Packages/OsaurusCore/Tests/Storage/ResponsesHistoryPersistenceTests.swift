import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

/// Protocol fixtures deliberately include opaque and future fields. A flattened
/// text reconstruction is not an equivalent history snapshot.
enum ResponsesHistoryFixture {
    static func items() throws -> [JSONValue] {
        try JSONDecoder().decode([JSONValue].self, from: Data(#"""
        [
          {"type":"reasoning","id":"rs_original","encrypted_content":"opaque+/==","summary":[{"type":"summary_text","text":"actual reasoning"}],"future":{"version":2}},
          {"type":"message","id":"msg_commentary","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Checking.","annotations":[]}]},
          {"type":"function_call","id":"fc_b","call_id":"call_b","name":"read_file","arguments":"{\"count\":\"7\"}","future":["b",1]},
          {"type":"function_call","id":"fc_a","call_id":"call_a","name":"read_file","arguments":"{\"path\":\"a.md\"}"},
          {"type":"future_provider_item","id":"opaque_item","payload":{"bytes":"unchanged","ordered":[3,1,2]}}
        ]
        """#.utf8))
    }

    static func signedBlocks() throws -> [JSONValue] {
        try JSONDecoder().decode([JSONValue].self, from: Data(#"""
        [{"type":"thinking","thinking":"actual signed reasoning","signature":"actual-provider-signature+/==","future":{"keep":true}},
         {"type":"redacted_thinking","data":"opaque-redacted+/==","future":[1,2]}]
        """#.utf8))
    }

    static var calls: [ToolCall] {
        [
            ToolCall(id: "call_b", type: "function", function: ToolCallFunction(name: "read_file", arguments: #"{"count":"7"}"#)),
            ToolCall(id: "call_a", type: "function", function: ToolCallFunction(name: "read_file", arguments: #"{"path":"a.md"}"#)),
        ]
    }

    static func turn() throws -> ChatTurnData {
        ChatTurnData(
            role: .assistant, content: "Checking.", toolCalls: calls,
            toolResults: ["call_b": "seven", "call_a": "file a"],
            toolCallDurations: ["call_b": 1.25, "call_a": 0.5], thinkingDuration: 2.5,
            thinking: "actual reasoning", createdAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 110), lastOutputAt: Date(timeIntervalSince1970: 109),
            generationTokenCount: 77, timeToFirstToken: 0.25, generationTokensPerSecond: 12.5,
            terminalStopReason: "tool_calls", reasoningItemId: "rs_original", reasoningEncrypted: "opaque+/==",
            responsesOutputItems: try items(), inputTokenCount: 1024, cachedInputTokenCount: 900
        )
    }

    static func encoded(_ turn: ChatTurnData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(turn)
    }

    /// Keep exact whole-snapshot comparison, but expose the actual differing
    /// keys/values in Swift Testing instead of an opaque Data inequality.
    static func differingFields(_ actual: ChatTurnData, _ expected: ChatTurnData) throws -> [String] {
        let actualJSON = try JSONDecoder().decode(JSONValue.self, from: encoded(actual))
        let expectedJSON = try JSONDecoder().decode(JSONValue.self, from: encoded(expected))
        guard case .object(let actualFields) = actualJSON, case .object(let expectedFields) = expectedJSON else {
            return ["Turn snapshot did not encode as a JSON object"]
        }
        return Set(actualFields.keys).union(expectedFields.keys).sorted().compactMap { key in
            guard actualFields[key] != expectedFields[key] else { return nil }
            return "\(key): actual=\(String(describing: actualFields[key])) expected=\(String(describing: expectedFields[key]))"
        }
    }

    /// SQL REAL dates cross the reference-date/Unix-epoch Double boundary.
    /// Require the exact stored Unix value and bound reference-date rounding
    /// by that value's ULP; every other field still uses the exact keyed diff.
    static func sqliteRoundTripDifferences(_ actual: ChatTurnData, _ expected: ChatTurnData) throws -> [String] {
        var represented = expected
        var dateDifferences: [String] = []
        let dates: [(String, WritableKeyPath<ChatTurnData, Date?>)] = [
            ("createdAt", \.createdAt), ("completedAt", \.completedAt),
            ("lastOutputAt", \.lastOutputAt), ("requestedAt", \.requestedAt),
        ]
        for (name, key) in dates {
            switch (actual[keyPath: key], expected[keyPath: key]) {
            case (nil, nil): break
            case (.some(let actualDate), .some(let expectedDate)):
                let storedUnix = expectedDate.timeIntervalSince1970
                let error = abs(actualDate.timeIntervalSinceReferenceDate - expectedDate.timeIntervalSinceReferenceDate)
                if actualDate.timeIntervalSince1970 == storedUnix, error <= storedUnix.ulp {
                    represented[keyPath: key] = actualDate
                } else {
                    dateDifferences.append("\(name): reference-date error=\(error), Unix Double ULP=\(storedUnix.ulp), actual Unix=\(actualDate.timeIntervalSince1970), expected Unix=\(storedUnix)")
                }
            default:
                dateDifferences.append("\(name): optional date presence changed")
            }
        }
        return dateDifferences + (try differingFields(actual, represented))
    }
}

@Suite(.serialized)
struct ResponsesHistoryPersistenceTests {
    @Test func sqliteComparisonAcceptsOnlyDateRepresentationAndRetainsExactNativeChecks() throws {
        var expected = try ResponsesHistoryFixture.turn()
        expected.createdAt = Date(timeIntervalSinceReferenceDate: 814_669_037.393262)
        var actual = expected
        actual.createdAt = expected.createdAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970) }
        let strictDifferences = try ResponsesHistoryFixture.differingFields(actual, expected)
        #expect(strictDifferences.contains { $0.hasPrefix("createdAt:") })
        let representedDifferences = try ResponsesHistoryFixture.sqliteRoundTripDifferences(actual, expected)
        #expect(representedDifferences.isEmpty)
        actual.reasoningEncrypted = "changed native bytes"
        let nativeDifferences = try ResponsesHistoryFixture.sqliteRoundTripDifferences(actual, expected)
        #expect(nativeDifferences.contains { $0.hasPrefix("reasoningEncrypted:") })
        actual = expected
        actual.createdAt = expected.createdAt.map { $0.addingTimeInterval($0.timeIntervalSince1970.ulp * 4) }
        let shiftedDifferences = try ResponsesHistoryFixture.sqliteRoundTripDifferences(actual, expected)
        #expect(shiftedDifferences.contains { $0.hasPrefix("createdAt:") })
        actual = expected
        actual.completedAt = nil
        let presenceDifferences = try ResponsesHistoryFixture.sqliteRoundTripDifferences(actual, expected)
        #expect(presenceDifferences.contains { $0 == "completedAt: optional date presence changed" })
    }

    private func withPlaintextRoot(_ body: @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("responses-sqlite-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()
            try await body()
        }
    }

    @Test(arguments: ["sync", "async", "append"])
    func nativeStateSurvivesActualDiskCloseAndNewDatabaseInstance(writePath: String) async throws {
        try await withPlaintextRoot {
            let db = ChatHistoryDatabase()
            try db.open()
            defer { db.close() }
            let native = try ResponsesHistoryFixture.turn()
            var signed = ChatTurnData(role: .assistant, content: "Signed answer", thinking: "actual signed reasoning")
            signed.anthropicThinkingBlocks = try ResponsesHistoryFixture.signedBlocks()
            let user = ChatTurnData(role: .user, content: "Read both files")
            let session = ChatSessionData(turns: [user, native, signed])
            switch writePath {
            case "async":
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    db.saveSessionAsync(session, onSaved: { continuation.resume() }, onDropped: { _ in
                        continuation.resume(throwing: NSError(domain: "ResponsesHistoryPersistenceTests", code: 1))
                    })
                }
            case "append":
                var initial = session
                initial.turns = [user]
                try db.saveSession(initial)
                try db.appendTurn(sessionId: session.id, turn: native)
                try db.appendTurn(sessionId: session.id, turn: signed)
            default: try db.saveSession(session)
            }
            db.close()
            let reopened = ChatHistoryDatabase()
            try reopened.open()
            defer { reopened.close() }
            let loaded = try #require(reopened.loadSession(id: session.id))
            #expect(loaded.turns.map(\.id) == session.turns.map(\.id))
            for (actual, expected) in zip(loaded.turns, session.turns) {
                #expect(try ResponsesHistoryFixture.encoded(actual) == ResponsesHistoryFixture.encoded(expected))
            }
        }
    }

    @Test func nativeOnlyChangesAndClearsAreNotSkippedByIncrementalHash() async throws {
        try await withPlaintextRoot {
            let db = ChatHistoryDatabase()
            try db.open()
            defer { db.close() }
            let baseline = ChatTurnData(role: .assistant, content: "Unchanged answer", thinking: "Unchanged reasoning")
            var session = ChatSessionData(turns: [baseline])
            try db.saveSession(session)
            var variants: [ChatTurnData] = []
            var changed = baseline; changed.reasoningItemId = "rs_late"; variants.append(changed)
            changed = baseline; changed.reasoningEncrypted = "encrypted-late+/=="; variants.append(changed)
            changed = baseline; changed.responsesOutputItems = try ResponsesHistoryFixture.items(); variants.append(changed)
            changed = baseline; changed.anthropicThinkingBlocks = try ResponsesHistoryFixture.signedBlocks(); variants.append(changed)
            changed = baseline; changed.inputTokenCount = 0; variants.append(changed)
            changed = baseline; changed.cachedInputTokenCount = 0; variants.append(changed)
            for variant in variants {
                #expect(ChatHistoryDatabase.contentHash(for: variant) != ChatHistoryDatabase.contentHash(for: baseline))
                for expected in [variant, baseline] {
                    session.turns = [expected]
                    try db.saveSession(session)
                    let loaded = try #require(db.loadSession(id: session.id)?.turns.first)
                    #expect(try ResponsesHistoryFixture.encoded(loaded) == ResponsesHistoryFixture.encoded(expected))
                }
            }
            db.close()
            try db.open()
            let loaded = try #require(db.loadSession(id: session.id)?.turns.first)
            #expect(loaded.inputTokenCount == nil && loaded.cachedInputTokenCount == nil)
        }
    }

    @Test func existingV21DatabaseMigratesWithoutFabricatingNativeState() async throws {
        try await withPlaintextRoot {
            let db = ChatHistoryDatabase()
            try db.open()
            let legacy = ChatTurnData(role: .assistant, content: "Before upgrade", thinking: "Original reasoning")
            let session = ChatSessionData(turns: [legacy])
            try db.saveSession(session)
            db.close()
            let conn = try EncryptedSQLiteOpener.open(path: OsaurusPaths.chatHistoryDatabaseFile().path, key: nil)
            defer { sqlite3_close(conn) }
            // Remove only v22 columns to produce the actual prior production
            // schema, retaining all v21 indexes, rows and migration state.
            let columns = ["reasoning_item_id", "reasoning_encrypted", "responses_output_items",
                           "anthropic_thinking_blocks", "input_token_count", "cached_input_token_count"]
            for column in columns { try Self.exec(conn, "ALTER TABLE turns DROP COLUMN \(column)") }
            try Self.exec(conn, "PRAGMA user_version = 21")
            try db.open()
            defer { db.close() }
            let loaded = try #require(db.loadSession(id: session.id)?.turns.first)
            #expect(try ResponsesHistoryFixture.encoded(loaded) == ResponsesHistoryFixture.encoded(legacy))
            var updated = session
            updated.turns.append(try ResponsesHistoryFixture.turn())
            try db.saveSession(updated)
            db.close()
            try db.open()
            let after = try #require(db.loadSession(id: session.id))
            #expect(try ResponsesHistoryFixture.encoded(after.turns[1]) == ResponsesHistoryFixture.encoded(updated.turns[1]))
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(conn, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            #expect(Int(sqlite3_column_int(statement, 0)) == ChatHistoryDatabase.latestSchemaVersion)
        }
    }

    private static func exec(_ conn: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(conn, sql, nil, nil, &error)
        guard result != SQLITE_OK else { return }
        let message = error.map { String(cString: $0) } ?? "SQLite error"
        sqlite3_free(error)
        throw NSError(domain: "ResponsesHistoryPersistenceTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor
    @Test func lightweightCodecRetainsNativeFieldsAndAcceptsOldSnapshots() throws {
        let native = try ResponsesHistoryFixture.turn()
        let turn = ChatTurn(from: native)
        turn.anthropicThinkingBlocks = try ResponsesHistoryFixture.signedBlocks()
        let encoded = try JSONEncoder().encode(turn.toPersisted())
        let restored = ChatTurn.fromPersisted(try JSONDecoder().decode(ChatTurn.Persisted.self, from: encoded))
        #expect(restored.id == native.id)
        #expect(restored.reasoningItemId == native.reasoningItemId && restored.reasoningEncrypted == native.reasoningEncrypted)
        #expect(restored.responsesOutputItems == native.responsesOutputItems)
        #expect(restored.anthropicThinkingBlocks == turn.anthropicThinkingBlocks)
        #expect(restored.inputTokenCount == native.inputTokenCount && restored.cachedInputTokenCount == native.cachedInputTokenCount)
        let oldJSON = Data("{\"id\":\"\(UUID().uuidString)\",\"role\":\"assistant\",\"content\":\"Legacy answer\"}".utf8)
        let old = ChatTurn.fromPersisted(try JSONDecoder().decode(ChatTurn.Persisted.self, from: oldJSON))
        #expect(old.content == "Legacy answer" && old.responsesOutputItems.isEmpty && old.anthropicThinkingBlocks.isEmpty)
        #expect(old.reasoningItemId == nil && old.reasoningEncrypted == nil)
        #expect(old.inputTokenCount == nil && old.cachedInputTokenCount == nil)
    }

    @MainActor
    @Test(arguments: [SessionSource.http, .plugin, .workspace])
    func realHTTPPluginAndWorkspaceWriterPreservesNativeHistory(source: SessionSource) async throws {
        try await ChatHistoryTestStorage.run {
            let externalKey = "native-writer-\(UUID().uuidString)"
            let assistant = ChatMessage(
                role: "assistant", content: "Checking.", tool_calls: ResponsesHistoryFixture.calls, tool_call_id: nil,
                reasoning_content: "actual reasoning", reasoning_item_id: "rs_original", reasoning_encrypted: "opaque+/==",
                responses_output_items: try ResponsesHistoryFixture.items()
            )
            let signed = ChatMessage(
                role: "assistant", content: "Signed answer", tool_calls: nil, tool_call_id: nil,
                reasoning_content: "actual signed reasoning", anthropic_thinking_blocks: try ResponsesHistoryFixture.signedBlocks()
            )
            let messages = [
                ChatMessage(role: "system", content: "Not persisted"),
                ChatMessage(role: "user", content: "Read both files"), assistant,
                ChatMessage(role: "tool", content: "file a", tool_calls: nil, tool_call_id: "call_a"),
                ChatMessage(role: "tool", content: "seven", tool_calls: nil, tool_call_id: "call_b"), signed,
            ]
            if source == .plugin {
                PluginHostContext.persistInference(pluginId: "native-plugin", agentId: nil,
                    externalSessionKey: externalKey, finalMessages: messages, model: "fixture-native")
            } else {
                ChatHistoryWriter.persist(source: source,
                    sourcePluginId: source == .workspace ? ChatHistoryWriter.workspacePseudoPluginId : nil,
                    agentId: nil, externalKey: externalKey, finalMessages: messages, model: "fixture-native")
            }
            let db = ChatHistoryDatabase.shared
            let metadata = try #require(db.loadAllMetadata().first { $0.externalSessionKey == externalKey })
            db.close()
            try db.open()
            let loaded = try #require(db.loadSession(id: metadata.id))
            #expect(loaded.source == source)
            #expect(loaded.turns.map(\.role) == [.user, .assistant, .tool, .tool, .assistant])
            let actual = loaded.turns[1]
            #expect(actual.thinking == "actual reasoning")
            #expect(actual.reasoningItemId == "rs_original" && actual.reasoningEncrypted == "opaque+/==")
            #expect(actual.responsesOutputItems == (try ResponsesHistoryFixture.items()))
            #expect(actual.toolCalls?.map(\.id) == ["call_b", "call_a"])
            #expect(actual.toolCalls?.first?.function.arguments == #"{"count":"7"}"#)
            #expect(actual.toolResults == ["call_a": "file a", "call_b": "seven"])
            #expect(actual.inputTokenCount == nil && actual.cachedInputTokenCount == nil, "ChatMessage does not report usage")
            #expect(loaded.turns.last?.anthropicThinkingBlocks == (try ResponsesHistoryFixture.signedBlocks()))
            #expect(loaded.turns.last?.thinking == "actual signed reasoning")
        }
    }
}
