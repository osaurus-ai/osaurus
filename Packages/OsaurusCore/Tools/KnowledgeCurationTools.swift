//
//  KnowledgeCurationTools.swift
//  osaurus
//
//  Staleness-ticket tools over knowledge collections:
//    `flag_knowledge_stale`   — file a staleness ticket
//    `list_knowledge_tickets` — browse tickets in the granted scope
//    `update_knowledge_ticket` — claim or release a ticket
//
//  Tickets are ANNOTATIONS: filing one never mutates a collection. They
//  solve a different problem from writing — an agent noticing drift it is
//  not currently being asked to fix, which is an asynchronous signal to a
//  human rather than a consent gate on a pending action. Documents are
//  written by `write_knowledge` / `delete_knowledge`, each approved at
//  call time in the permission modal.
//
//  `propose_knowledge_update` and the curator role it belonged to were
//  removed: that design asked for consent twice (the tool was already
//  `.ask`, and its result was an inert draft needing a second approval),
//  and returning pending meant the agent could never verify its own
//  work — the failure mode behind osaurus#2439.
//
//  Scoping matches the retrieval tools: grants resolve from the calling
//  agent at execution time via `KnowledgeToolScope`.
//

import Foundation

extension Notification.Name {
    /// Posted after a ticket or proposal mutation so the Knowledge tab
    /// review UI can refresh.
    public static let knowledgeCurationChanged = Notification.Name("knowledgeCurationChanged")
}

private func postCurationChanged() {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .knowledgeCurationChanged, object: nil)
    }
}

// MARK: - flag_knowledge_stale

final class FlagKnowledgeStaleTool: OsaurusTool, @unchecked Sendable {
    let name = "flag_knowledge_stale"
    // NOTE: compact-prompt models only see the FIRST sentence of this
    // description (`oneLineToolDescription`, ≤180 chars), so the routing
    // rule has to live there rather than in a follow-up sentence
    // (live-observed miss with Ornith-1.0-9B).
    //
    // That rule INVERTED when the corpus became writable. It used to be
    // "update request ⇒ file a ticket", because nothing could edit a
    // document. Now an update request goes straight to `write_knowledge`,
    // and a ticket is only for drift nobody asked you to fix. Leaving the
    // old wording would send every update request back through a queue that
    // no longer leads anywhere.
    let description =
        "Leave a note that a knowledge document looks outdated, when fixing it is NOT the "
        + "current task. To actually change a document, use `write_knowledge` instead. "
        + "Use this for drift you notice in passing (changed APIs, superseded practices, "
        + "broken references). It only records the note for the user; nothing on disk changes."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Document path relative to its collection, e.g. `wordpress/plugins.md`."),
            ]),
            "reason": .object([
                "type": .string("string"),
                "description": .string("Why the document appears stale, in one or two sentences."),
            ]),
            "evidence": .object([
                "type": .string("string"),
                "description": .string("Optional: what you observed (error output, release notes, contradicting source)."),
            ]),
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: the collection name. Required only when the same path exists in more than one granted collection."
                ),
            ]),
        ]),
        "required": .array([.string("path"), .string("reason")]),
    ])

    /// Cancellation audit: one bounded SQLite ticket insert (plus grant/index
    /// lookups) — no network, no external processes, no detached work; the
    /// body terminates promptly and drains trivially.
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(args, "path", expected: "collection-relative document path", tool: name)
        guard case .value(let pathRaw) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let relPath = pathRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envelope = KnowledgeCurationToolSupport.validateRelPath(relPath, tool: name) {
            return envelope
        }

        let reasonReq = requireString(args, "reason", expected: "short explanation of the suspected drift", tool: name)
        guard case .value(let reasonRaw) = reasonReq else { return reasonReq.failureEnvelope ?? "" }
        let reason = reasonRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `reason` must not be whitespace-only.",
                field: "reason",
                expected: "short explanation of the suspected drift",
                tool: name
            )
        }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections, _) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        // The ticket must target a real, granted document.
        let located = KnowledgeCurationToolSupport.locateDocument(
            relPath: relPath,
            in: collections,
            tool: name
        )
        guard case .success(let match) = located else {
            if case .failure(let envelope) = located { return envelope }
            return ""
        }
        let collectionId = match.collection.id.uuidString

        // Dedupe: one open ticket per document is enough signal.
        if let existing = try? KnowledgeDatabase.shared.openTicket(
            collectionId: collectionId,
            relPath: relPath
        ) {
            return ToolEnvelope.success(
                tool: name,
                text:
                    "Ticket #\(existing.id) is already open for `\(relPath)` "
                    + "(reason: \(existing.reason)). No duplicate filed."
            )
        }

        let evidence = ((args["evidence"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let createdBy = ChatExecutionContext.knowledgeAgentId?.uuidString ?? ""
        do {
            let ticketId = try KnowledgeDatabase.shared.createTicket(
                collectionId: collectionId,
                relPath: relPath,
                reason: reason,
                evidence: evidence,
                createdBy: createdBy
            )
            postCurationChanged()
            return ToolEnvelope.success(
                tool: name,
                text:
                    "Filed ticket #\(ticketId) against [\(match.collection.name)] \(relPath). "
                    + "A curator will review it; the document is unchanged."
            )
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not file the ticket: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
    }
}

// MARK: - list_knowledge_tickets

final class ListKnowledgeTicketsTool: OsaurusTool, @unchecked Sendable {
    let name = "list_knowledge_tickets"
    let description =
        "List staleness tickets for the agent's granted knowledge "
        + "collections. Check `open` tickets before flagging (duplicates "
        + "are rejected) or when working a curation queue."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "collection": .object([
                "type": .string("string"),
                "description": .string("Optional: restrict to one granted collection by name."),
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("open"),
                    .string("in_progress"),
                    .string("proposed"),
                    .string("resolved"),
                    .string("dismissed"),
                ]),
                "description": .string("Optional: filter by ticket status (default: open)."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum tickets to return (default 25, max 100)."),
            ]),
        ]),
        "required": .array([]),
    ])

    /// Cancellation audit: one capped (`limit` ≤ 100) SQLite ticket listing —
    /// no network, no external processes, no detached work; the body
    /// terminates promptly and drains trivially.
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections, _) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        let statusRaw = ((args["status"] as? String) ?? "open").lowercased()
        guard let status = KnowledgeTicketStatus(rawValue: statusRaw) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown status `\(statusRaw)`.",
                field: "status",
                expected: "one of open|in_progress|proposed|resolved|dismissed",
                tool: name
            )
        }
        let limit = max(1, min(100, ArgumentCoercion.int(args["limit"]) ?? 25))

        let tickets =
            (try? KnowledgeDatabase.shared.listTickets(
                collectionIds: collections.map { $0.id.uuidString },
                status: status,
                limit: limit
            )) ?? []

        if tickets.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                text: "No \(status.rawValue) knowledge tickets in the granted collections."
            )
        }

        let nameById = KnowledgeToolScope.namesById(collections)
        var out = "Found \(tickets.count) \(status.rawValue) ticket(s):\n\n"
        for ticket in tickets {
            let collectionName = nameById[ticket.collectionId] ?? ticket.collectionId
            out += "#\(ticket.id) [\(collectionName)] \(ticket.relPath)\n"
            out += "  reason: \(ticket.reason)\n"
            if !ticket.evidence.isEmpty {
                let preview = ticket.evidence.prefix(200)
                out += "  evidence: \(preview)\(ticket.evidence.count > 200 ? "…" : "")\n"
            }
            out += "  filed: \(ticket.createdAt.prefix(10))\n\n"
        }
        return ToolEnvelope.success(tool: name, text: out)
    }
}

// MARK: - update_knowledge_ticket

final class UpdateKnowledgeTicketTool: OsaurusTool, @unchecked Sendable {
    let name = "update_knowledge_ticket"
    let description =
        "Claim or release a staleness ticket while working a curation "
        + "queue. Set `in_progress` before researching a ticket so other "
        + "scheduled runs skip it, or `open` to release one you cannot finish. "
        + "Curator agents only; resolution happens via proposal approval, "
        + "not this tool."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "ticket_id": .object([
                "type": .string("integer"),
                "description": .string("The ticket to update."),
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([.string("in_progress"), .string("open")]),
                "description": .string("`in_progress` to claim, `open` to release."),
            ]),
        ]),
        "required": .array([.string("ticket_id"), .string("status")]),
    ])

    /// Cancellation audit: one bounded SQLite status update behind the
    /// curator-role check — no network, no external processes, no detached
    /// work; the body terminates promptly and drains trivially.
    /// (`propose_knowledge_update` deliberately stays unaudited: its
    /// interactive permission gate can stall a bounded child like `clarify`.)
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        guard let ticketId = ArgumentCoercion.int(args["ticket_id"]) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `ticket_id` must be an integer.",
                field: "ticket_id",
                expected: "an existing ticket id",
                tool: name
            )
        }
        let statusRaw = ((args["status"] as? String) ?? "").lowercased()
        guard let newStatus = KnowledgeTicketStatus(rawValue: statusRaw),
            newStatus == .inProgress || newStatus == .open
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `status` must be `in_progress` or `open`.",
                field: "status",
                expected: "in_progress|open",
                tool: name
            )
        }

        // Curator gate at execution time, same as propose.
        guard let agentId = ChatExecutionContext.knowledgeAgentId else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Knowledge tools require an active agent context.",
                tool: name
            )
        }
        let isCurator = await MainActor.run {
            AgentManager.shared.effectiveCapabilities(for: agentId).knowledgeCuratorEnabled
        }
        guard isCurator else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "This agent is not a knowledge curator.",
                tool: name
            )
        }

        let scope = await KnowledgeToolScope.resolve(tool: name, collectionName: nil)
        guard case .granted(let collections, _) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        guard let ticket = try? KnowledgeDatabase.shared.getTicket(id: ticketId),
            collections.contains(where: { $0.id.uuidString == ticket.collectionId })
        else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message: "No ticket #\(ticketId) in the granted collections.",
                field: "ticket_id",
                tool: name
            )
        }

        // Only the open ↔ in_progress transitions are agent-drivable;
        // proposed/resolved/dismissed belong to the review flow.
        let allowed: Bool =
            (ticket.status == .open && newStatus == .inProgress)
            || (ticket.status == .inProgress && newStatus == .open)
        guard allowed else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Ticket #\(ticketId) is `\(ticket.status.rawValue)`; only open tickets can be claimed and only in_progress tickets released.",
                tool: name
            )
        }

        do {
            try KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: newStatus)
            postCurationChanged()
            let verb = newStatus == .inProgress ? "claimed" : "released"
            return ToolEnvelope.success(tool: name, text: "Ticket #\(ticketId) \(verb).")
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not update the ticket: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
    }
}


// MARK: - Shared helpers

enum KnowledgeCurationToolSupport {
    /// Same confinement contract as `read_knowledge`: relative, no
    /// escapes. Returns a failure envelope on violation.
    static func validateRelPath(_ relPath: String, tool: String) -> String? {
        guard !relPath.isEmpty, !relPath.hasPrefix("/"), !relPath.hasPrefix("~"),
            !relPath.components(separatedBy: "/").contains("..")
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `path` must be a collection-relative path without `..` components.",
                field: "path",
                expected: "relative path inside the collection, e.g. `guides/setup.md`",
                tool: tool
            )
        }
        return nil
    }

    enum Located {
        case success((collection: KnowledgeCollection, document: KnowledgeDocument))
        case failure(String)
    }

    /// Find an indexed document among the granted collections; ambiguity
    /// and misses return ready-to-return failure envelopes.
    static func locateDocument(
        relPath: String,
        in collections: [KnowledgeCollection],
        tool: String
    ) -> Located {
        var matches: [(collection: KnowledgeCollection, document: KnowledgeDocument)] = []
        for collection in collections {
            if let document = try? KnowledgeDatabase.shared.getDocument(
                collectionId: collection.id.uuidString,
                relPath: relPath
            ) {
                matches.append((collection, document))
            }
        }
        guard let match = matches.first else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No knowledge document at `\(relPath)` in the granted collections.",
                    tool: tool
                )
            )
        }
        if matches.count > 1 {
            let names = matches.map(\.collection.name).joined(separator: ", ")
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Path `\(relPath)` exists in multiple collections (\(names)). Pass `collection` to disambiguate.",
                    field: "collection",
                    expected: "one of: \(names)",
                    tool: tool
                )
            )
        }
        return .success(match)
    }
}
