//
//  ChatSessionImporterTests.swift
//  osaurusTests
//
//  Pin the external-export parsers: ChatGPT's message tree must
//  linearize along current_node, Claude's flat chat_messages must map
//  sender → role, the generic schema must round-trip, and unrecognized
//  payloads must fail with a typed error instead of importing garbage.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatSessionImporterTests {

    // MARK: - ChatGPT

    private let chatGPTExport = """
        [
          {
            "title": "Rust lifetimes",
            "create_time": 1750000000.0,
            "update_time": 1750000100.0,
            "conversation_id": "abc-123",
            "current_node": "n3",
            "mapping": {
              "root": {"id": "root", "parent": null, "children": ["n1"]},
              "n1": {
                "id": "n1", "parent": "root", "children": ["n2", "n2b"],
                "message": {
                  "author": {"role": "user"},
                  "create_time": 1750000000.0,
                  "content": {"content_type": "text", "parts": ["Explain lifetimes"]}
                }
              },
              "n2b": {
                "id": "n2b", "parent": "n1", "children": [],
                "message": {
                  "author": {"role": "assistant"},
                  "content": {"content_type": "text", "parts": ["Abandoned branch"]}
                }
              },
              "n2": {
                "id": "n2", "parent": "n1", "children": ["n3"],
                "message": {
                  "author": {"role": "assistant"},
                  "create_time": 1750000050.0,
                  "content": {"content_type": "text", "parts": ["Lifetimes are…"]}
                }
              },
              "n3": {
                "id": "n3", "parent": "n2", "children": [],
                "message": {
                  "author": {"role": "system"},
                  "metadata": {"is_visually_hidden_from_conversation": true},
                  "content": {"content_type": "text", "parts": ["hidden"]}
                }
              }
            }
          }
        ]
        """

    @Test func chatGPTLinearizesCanonicalPath() throws {
        let imported = try ChatSessionImporter.parse(data: Data(chatGPTExport.utf8))
        #expect(imported.count == 1)
        let session = try #require(imported.first).session

        #expect(session.title == "Rust lifetimes")
        #expect(session.source == .imported)
        #expect(session.externalSessionKey == "chatgpt:abc-123")
        // Canonical path only: user + assistant; the abandoned branch and
        // the visually-hidden system node are dropped.
        #expect(session.turns.count == 2)
        #expect(session.turns[0].role == .user)
        #expect(session.turns[0].content == "Explain lifetimes")
        #expect(session.turns[1].role == .assistant)
        #expect(session.turns[1].content == "Lifetimes are…")
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_750_000_100))
    }

    @Test func chatGPTFallsBackToDeepestLeafWithoutCurrentNode() throws {
        let export = chatGPTExport.replacingOccurrences(
            of: "\"current_node\": \"n3\",", with: "")
        let imported = try ChatSessionImporter.parse(data: Data(export.utf8))
        let session = try #require(imported.first).session
        // Deepest "last child" chain is root → n1 → n2b.
        #expect(session.turns.map(\.content) == ["Explain lifetimes", "Abandoned branch"])
    }

    // MARK: - Claude

    private let claudeExport = """
        [
          {
            "uuid": "conv-1",
            "name": "Trip planning",
            "created_at": "2026-05-01T09:00:00.000000Z",
            "updated_at": "2026-05-01T09:05:00.000000Z",
            "chat_messages": [
              {
                "sender": "human",
                "created_at": "2026-05-01T09:00:00.000000Z",
                "content": [{"type": "text", "text": "Plan a trip to Kyoto"}]
              },
              {
                "sender": "assistant",
                "created_at": "2026-05-01T09:01:00.000000Z",
                "text": "Sure — here's a 3-day plan."
              }
            ]
          }
        ]
        """

    @Test func claudeMapsSenderToRole() throws {
        let imported = try ChatSessionImporter.parse(data: Data(claudeExport.utf8))
        let session = try #require(imported.first).session

        #expect(session.title == "Trip planning")
        #expect(session.externalSessionKey == "claude:conv-1")
        #expect(session.turns.count == 2)
        #expect(session.turns[0].role == .user)
        #expect(session.turns[0].content == "Plan a trip to Kyoto")
        #expect(session.turns[1].role == .assistant)
        #expect(session.turns[1].content == "Sure — here's a 3-day plan.")
    }

    // MARK: - Gemini (Takeout MyActivity.json)

    private let geminiExport = """
        [
          {
            "header": "Gemini Apps",
            "title": "Prompted explain monads simply",
            "time": "2026-06-01T10:00:00.000Z",
            "products": ["Gemini Apps"],
            "activityControls": ["Gemini Apps Activity"],
            "safeHtmlItem": [
              {"html": "<p>A monad is a &quot;box&quot;.</p><ul><li>wrap</li><li>chain</li></ul>"}
            ]
          },
          {
            "header": "Gemini Apps",
            "title": "Used Gemini Apps",
            "time": "2026-06-01T09:00:00.000Z",
            "products": ["Gemini Apps"]
          },
          {
            "header": "Gemini Apps",
            "title": "Prompted what's 2+2",
            "time": "2026-06-02T08:30:00.000Z",
            "products": ["Gemini Apps"]
          }
        ]
        """

    @Test func geminiActivityEntriesBecomeIndividualSessions() throws {
        let imported = try ChatSessionImporter.parse(data: Data(geminiExport.utf8))

        // The "Used Gemini Apps" row has no prompt and is dropped.
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.format == .gemini })

        let first = try #require(imported.first).session
        #expect(first.turns.count == 2)
        #expect(first.turns[0].role == .user)
        #expect(first.turns[0].content == "explain monads simply")
        #expect(first.turns[1].role == .assistant)
        #expect(first.turns[1].content == "A monad is a \"box\".\n- wrap\n- chain")
        #expect(first.externalSessionKey == "gemini:2026-06-01T10:00:00.000Z")
        #expect(
            first.createdAt == ISO8601DateFormatter().date(from: "2026-06-01T10:00:00Z")
        )
    }

    @Test func geminiPromptWithoutResponseImportsAsUserOnlySession() throws {
        let imported = try ChatSessionImporter.parse(data: Data(geminiExport.utf8))
        let promptOnly = try #require(
            imported.first(where: { $0.session.turns[0].content == "what's 2+2" })
        ).session

        #expect(promptOnly.turns.count == 1)
        #expect(promptOnly.turns[0].role == .user)
    }

    // MARK: - Open WebUI

    private let openWebUIExport = """
        [
          {
            "id": "owui-1",
            "title": "Llama chat",
            "created_at": 1750100000,
            "updated_at": 1750100060,
            "chat": {
              "title": "Llama chat",
              "models": ["llama3:latest"],
              "messages": [
                {"id": "m1", "parentId": null, "role": "user", "content": "What is a tensor?", "timestamp": 1750100000},
                {"id": "m2", "parentId": "m1", "role": "assistant", "model": "llama3:latest", "content": "A multi-dimensional array with transformation rules.", "timestamp": 1750100060, "done": true}
              ],
              "history": {"currentId": "m2"}
            }
          }
        ]
        """

    @Test func openWebUIExportMapsChatMessages() throws {
        let imported = try ChatSessionImporter.parse(data: Data(openWebUIExport.utf8))

        #expect(imported.count == 1)
        let entry = try #require(imported.first)
        #expect(entry.format == .openWebUI)
        #expect(entry.session.title == "Llama chat")
        #expect(entry.session.externalSessionKey == "openwebui:owui-1")
        #expect(entry.session.turns.count == 2)
        #expect(entry.session.turns[0].role == .user)
        #expect(entry.session.turns[1].content == "A multi-dimensional array with transformation rules.")
        #expect(entry.session.createdAt == Date(timeIntervalSince1970: 1_750_100_000))
        #expect(entry.session.updatedAt == Date(timeIntervalSince1970: 1_750_100_060))
    }

    @Test func openWebUIRecordWithoutMessagesIsDropped() throws {
        let export = """
            [
              {"id": "empty", "title": "No chat", "chat": {"messages": []}},
              \(openWebUIExport.dropFirst().dropLast())
            ]
            """
        let imported = try ChatSessionImporter.parse(data: Data(export.utf8))
        #expect(imported.count == 1)
    }

    // MARK: - Grok (account export)

    private let grokExport = """
        {
          "conversations": [
            {
              "conversation": {
                "conversation_id": "grok-conv-1",
                "title": "Mars colony logistics",
                "create_time": {"$date": {"$numberLong": "1750000000000"}},
                "modify_time": {"$date": {"$numberLong": "1750000200000"}}
              },
              "responses": [
                {"response": {"sender": "human", "message": "How much water does a 100-person Mars base need?", "create_time": {"$date": {"$numberLong": "1750000000000"}}}},
                {"response": {"sender": "assistant", "message": "Roughly 5 tons/day before recycling; closed-loop systems cut that by ~90%.", "create_time": {"$date": {"$numberLong": "1750000100000"}}}}
              ]
            },
            {
              "conversation": {
                "_id": {"$oid": "665f1e2a9b3c4d5e6f708192"},
                "title": "Flat senders",
                "create_time": {"$date": "2026-06-15T12:00:00.000Z"}
              },
              "responses": [
                {"sender": "user", "message": "ping"},
                {"sender": "grok", "message": "pong"}
              ]
            }
          ]
        }
        """

    @Test func grokExportParsesNestedResponsesAndMongoDates() throws {
        let imported = try ChatSessionImporter.parse(data: Data(grokExport.utf8))

        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.format == .grok })

        let first = try #require(imported.first).session
        #expect(first.title == "Mars colony logistics")
        #expect(first.externalSessionKey == "grok:grok-conv-1")
        #expect(first.turns.count == 2)
        #expect(first.turns[0].role == .user)
        #expect(first.turns[1].role == .assistant)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(first.updatedAt == Date(timeIntervalSince1970: 1_750_000_200))
    }

    @Test func grokExportAcceptsFlatResponsesAndOidIds() throws {
        let imported = try ChatSessionImporter.parse(data: Data(grokExport.utf8))
        let flat = try #require(imported.last).session

        #expect(flat.externalSessionKey == "grok:665f1e2a9b3c4d5e6f708192")
        #expect(flat.turns.count == 2)
        #expect(flat.turns[0].content == "ping")
        #expect(flat.turns[1].role == .assistant)
        #expect(flat.createdAt == ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
    }

    // MARK: - Generic schema

    @Test func genericSchemaParsesAndTitlesFromFirstUserTurn() throws {
        let export = """
            {
              "conversations": [
                {
                  "id": "g1",
                  "messages": [
                    {"role": "user", "content": "hello there", "timestamp": 1750000000},
                    {"role": "assistant", "content": "hi!"}
                  ]
                }
              ]
            }
            """
        let imported = try ChatSessionImporter.parse(data: Data(export.utf8))
        let session = try #require(imported.first).session
        #expect(session.externalSessionKey == "import:g1")
        #expect(session.title == "hello there")
        #expect(session.turns.count == 2)
        #expect(session.turns[0].createdAt == Date(timeIntervalSince1970: 1_750_000_000))
    }

    @Test func genericContentAcceptsStringArraysAndTextBlocks() throws {
        // Regression: hand-rolled exports carry assistant content as an
        // array of strings (or typed text blocks); those turns were
        // silently dropped, importing a user-only conversation.
        let export = """
            {
              "title": "Quotes",
              "messages": [
                {"role": "user", "content": "write quotes"},
                {"role": "assistant", "content": ["first quote", "second quote"]},
                {"role": "user", "content": "more"},
                {"role": "assistant", "content": [{"type": "text", "text": "third quote"}]}
              ]
            }
            """
        let imported = try ChatSessionImporter.parse(data: Data(export.utf8))
        let session = try #require(imported.first).session
        #expect(session.turns.count == 4)
        #expect(session.turns[1].role == .assistant)
        #expect(session.turns[1].content == "first quote\n\nsecond quote")
        #expect(session.turns[3].content == "third quote")
    }

    @Test func genericSingleConversationObjectIsAccepted() throws {
        let export = """
            {"messages": [{"role": "user", "content": "solo"}]}
            """
        let imported = try ChatSessionImporter.parse(data: Data(export.utf8))
        #expect(imported.count == 1)
        #expect(imported.first?.session.turns.first?.content == "solo")
    }

    // MARK: - Zip archives

    /// Builds a real zip in memory (CRCs left zero — the reader doesn't
    /// verify them) so the archive path is tested without fixtures.
    private func makeZip(_ entries: [(name: String, data: Data, deflate: Bool)]) throws -> Data {
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }

        var zip = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let payload =
                entry.deflate
                ? try (entry.data as NSData).compressed(using: .zlib) as Data
                : entry.data
            let method = entry.deflate ? 8 : 0
            let localOffset = zip.count

            zip.append(Data([0x50, 0x4B, 0x03, 0x04]))
            zip.append(u16(20) + u16(0) + u16(method) + u16(0) + u16(0) + u32(0))
            zip.append(u32(payload.count) + u32(entry.data.count) + u16(name.count) + u16(0))
            zip.append(name)
            zip.append(payload)

            central.append(Data([0x50, 0x4B, 0x01, 0x02]))
            central.append(u16(20) + u16(20) + u16(0) + u16(method) + u16(0) + u16(0) + u32(0))
            central.append(u32(payload.count) + u32(entry.data.count) + u16(name.count))
            central.append(u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(localOffset))
            central.append(name)
        }
        let centralOffset = zip.count
        zip.append(central)
        zip.append(Data([0x50, 0x4B, 0x05, 0x06]))
        zip.append(u16(0) + u16(0) + u16(entries.count) + u16(entries.count))
        zip.append(u32(central.count) + u32(centralOffset) + u16(0))
        return zip
    }

    @Test func zippedChatGPTExportImportsConversationsAndSkipsSidecars() throws {
        let zip = try makeZip([
            ("user.json", Data("{\"id\": \"user-1\"}".utf8), false),
            ("conversations.json", Data(chatGPTExport.utf8), true),
        ])
        let imported = try ChatSessionImporter.parse(data: zip)

        #expect(imported.count == 1)
        let session = try #require(imported.first).session
        #expect(session.title == "Rust lifetimes")
        #expect(session.externalSessionKey == "chatgpt:abc-123")
    }

    @Test func zippedTakeoutFindsNestedGeminiActivity() throws {
        let zip = try makeZip([
            ("Takeout/Gemini Apps/MyActivity.json", Data(geminiExport.utf8), true)
        ])
        let imported = try ChatSessionImporter.parse(data: zip)

        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.format == .gemini })
    }

    @Test func zipWithoutConversationsThrows() throws {
        let zip = try makeZip([
            ("user.json", Data("{\"id\": \"user-1\"}".utf8), false)
        ])
        #expect(throws: ChatSessionImporter.ImportError.self) {
            _ = try ChatSessionImporter.parse(data: zip)
        }
    }

    // MARK: - Rejection

    @Test func rejectsUnrecognizedJSON() {
        let export = Data("{\"foo\": 1}".utf8)
        #expect(throws: ChatSessionImporter.ImportError.self) {
            _ = try ChatSessionImporter.parse(data: export)
        }
    }

    @Test func rejectsNonJSON() {
        let export = Data("# just markdown".utf8)
        #expect(throws: ChatSessionImporter.ImportError.self) {
            _ = try ChatSessionImporter.parse(data: export)
        }
    }

    @Test func conversationWithoutUserTurnsIsDropped() {
        let export = Data(
            """
            {"conversations": [{"messages": [{"role": "assistant", "content": "orphan"}]}]}
            """.utf8)
        #expect(throws: ChatSessionImporter.ImportError.self) {
            _ = try ChatSessionImporter.parse(data: export)
        }
    }
}
