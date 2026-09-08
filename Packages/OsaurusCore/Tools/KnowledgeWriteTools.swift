//
//  KnowledgeWriteTools.swift
//  OsaurusCore — Knowledge
//
//  `write_knowledge`: create or replace documents in a granted collection,
//  gated by the ordinary tool-permission modal.
//
//  This replaces the curator/proposal/approval architecture. That design
//  asked twice — `propose_knowledge_update` was already `.ask`, and its result
//  was still only a pending draft needing a second approval in the Knowledge
//  tab — and, worse, it returned "pending", so the agent could never confirm
//  what it had actually done. In osaurus#2439 that inability to verify is what
//  drove a model to guess, fabricate progress, and loop for 24 hours. Writing
//  on approval returns a real result the agent can check with
//  `search_knowledge`, which closes the loop.
//
//  Batch-shaped from the start: the task that exposed all this was importing
//  62 documents, and one modal over a reviewable manifest is the difference
//  between a usable flow and 62 approval cards.
//

import Foundation

final class WriteKnowledgeTool: OsaurusTool, PermissionedTool, KnowledgeWritePreviewingTool,
    @unchecked Sendable
{
    let name = "write_knowledge"

    let description =
        // The routing rule lives in the FIRST sentence deliberately. Compact
        // prompts show only that much (`oneLineToolDescription`), and a model
        // that never learns to prefer `edit_knowledge` restates long documents
        // and truncates them. Pinned by a test.
        "Create NEW documents in this agent's knowledge collections, or replace one outright, "
        + "but to change PART of an existing document use `edit_knowledge` instead, since "
        + "restating a long document is slow and risks truncating it. "
        + "Pass every document for a task in ONE call: `documents` is an array, and one call is "
        + "one approval. The user reviews the paths and a diff of each change before anything is "
        + "written, then the documents are saved and indexed immediately. Content is whole markdown "
        + "documents; when replacing one, carry its existing `---` frontmatter across. Use "
        + "`search_knowledge` afterwards to confirm what landed. "
        + "To remove documents use `delete_knowledge`."

    /// The user reviews and approves each call in the permission modal, which
    /// renders paths + diffs rather than raw JSON (see `approvalPreview`).
    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    /// Aligned with the indexer's oversized-file skip so an approved write
    /// stays indexable.
    static let maxContentBytes = 2 * 1024 * 1024
    /// Bounds one call. Far above any real import, low enough that a
    /// runaway loop cannot queue an unreviewable manifest.
    static let maxDocumentsPerCall = 200

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Collection name. Required only when more than one collection is granted."
                ),
            ]),
            "documents": .object([
                "type": .string("array"),
                "description": .string(
                    "The documents to write. Send them all in one call, not one call each."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Collection-relative markdown path, e.g. `usage/how-to-deploy.md`."
                            ),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string(
                                "The complete markdown document. Not a diff. When replacing an "
                                    + "existing document, KEEP its `---` frontmatter block: "
                                    + "`read_knowledge` shows the body without it, so you must "
                                    + "write it back yourself or the document loses its title, "
                                    + "type and tags."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("content")]),
                ]),
            ]),
            "rationale": .object([
                "type": .string("string"),
                "description": .string(
                    "One line on why these documents are being written. Shown to the user in the "
                        + "approval card."
                ),
            ]),
        ]),
        "required": .array([.string("documents")]),
    ])

    init() {}

    // MARK: - Approval preview

    func approvalPreview(argumentsJSON: String) async -> KnowledgeWritePreview? {
        guard let args = Self.parsedArguments(argumentsJSON) else { return nil }
        guard case .granted(let collections, _) = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        ),
            let collection = collections.first, collections.count == 1
        else {
            // Ambiguous or ungranted: the body returns a precise error. Fall
            // back to the JSON card rather than showing a manifest against a
            // collection we might have guessed wrong.
            return nil
        }
        return KnowledgeWritePreviewBuilder.build(
            collection: collection,
            argumentsJSON: argumentsJSON,
            isDelete: false,
            schema: parameters
        )
    }

    // MARK: - Execute

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let documentsReq = Self.documents(from: args, tool: name)
        guard case .success(let documents) = documentsReq else {
            return documentsReq.failureEnvelope ?? ""
        }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections, _) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        // Writing needs ONE unambiguous target. Reads can span every grant;
        // guessing which collection to mutate is not the same call.
        guard collections.count == 1, let collection = collections.first else {
            let names = collections.map(\.name).joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "More than one collection is granted, so `collection` is required for a write. "
                    + "Granted collections: \(names).",
                field: "collection",
                expected: "one of the agent's granted collection names",
                tool: name
            )
        }
        guard collection.isEnabled, collection.folderExists else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Collection \(collection.name) is unavailable (disabled, or its folder is missing).",
                tool: name,
                retryable: false
            )
        }

        let rationale = (args["rationale"] as? String) ?? ""
        // Groups this call's writes so the whole import can be reverted as a
        // unit. Falls back to a fresh id rather than "" so an untracked
        // surface still gets a revertable batch.
        let runId = (ChatExecutionContext.currentRunId ?? UUID()).uuidString
        let createdBy = ChatExecutionContext.currentAgentId?.uuidString ?? ""

        // Best-effort per document with an explicit per-document result: one
        // bad path must not discard 61 good documents after the user already
        // approved the batch.
        var written: [KnowledgeWriteOutcome] = []
        var failures: [(path: String, reason: String)] = []
        for document in documents {
            do {
                let outcome = try await KnowledgeWriteService.shared.write(
                    collection: collection,
                    relPath: document.path,
                    content: document.content,
                    runId: runId,
                    createdBy: createdBy,
                    rationale: rationale
                )
                written.append(outcome)
            } catch {
                failures.append(
                    (
                        document.path,
                        (error as? KnowledgeWriteError)?.errorDescription
                            ?? error.localizedDescription
                    )
                )
            }
        }

        return Self.resultEnvelope(
            tool: name,
            collection: collection,
            written: written,
            failures: failures,
            runId: runId
        )
    }

    // MARK: - Arguments

    struct PendingDocument: Equatable {
        var path: String
        var content: String
    }

    enum DocumentsResult {
        case success([PendingDocument])
        case failure(String)

        var failureEnvelope: String? {
            if case .failure(let envelope) = self { return envelope }
            return nil
        }
    }

    /// Parse and validate `documents`.
    ///
    /// Accepts the singular `{path, content}` shape too: a model handed an
    /// array parameter reliably sends one of each, and rejecting the singular
    /// form costs a whole turn to relearn a detail that changes nothing about
    /// what the user reviews.
    static func documents(from args: [String: Any], tool: String) -> DocumentsResult {
        var pending: [PendingDocument] = []

        if let raw = args["documents"] as? [[String: Any]] {
            for entry in raw {
                guard let path = (entry["path"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
                else {
                    return .failure(
                        ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message: "Every entry in `documents` needs a non-empty `path`.",
                            field: "documents",
                            expected: "array of {path, content}",
                            tool: tool
                        )
                    )
                }
                pending.append(
                    PendingDocument(
                        path: path,
                        // Same normalization the approval preview applied, so
                        // the diff the user approved is what lands.
                        content: KnowledgeWriteService.strippingReadPreamble(
                            (entry["content"] as? String) ?? "")
                    )
                )
            }
        } else if let path = (args["path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        {
            pending.append(
                PendingDocument(
                    path: path,
                    content: KnowledgeWriteService.strippingReadPreamble(
                        (args["content"] as? String) ?? "")
                )
            )
        }

        guard !pending.isEmpty else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "No documents to write. Pass `documents` as an array of "
                        + "{path, content} entries.",
                    field: "documents",
                    expected: "non-empty array of {path, content}",
                    tool: tool
                )
            )
        }
        guard pending.count <= maxDocumentsPerCall else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "\(pending.count) documents in one call exceeds the limit of "
                        + "\(maxDocumentsPerCall). Split the import into smaller batches.",
                    field: "documents",
                    expected: "at most \(maxDocumentsPerCall) documents",
                    tool: tool
                )
            )
        }
        // Two entries for one path in a single approved batch means the user
        // reviewed a diff that the second write immediately invalidates.
        var seen: Set<String> = []
        for document in pending where !seen.insert(document.path).inserted {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`\(document.path)` appears more than once. Each path may be written "
                        + "once per call.",
                    field: "documents",
                    expected: "unique paths",
                    tool: tool
                )
            )
        }
        if let oversized = pending.first(where: { $0.content.utf8.count > maxContentBytes }) {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`\(oversized.path)` is larger than the \(maxContentBytes / (1024 * 1024))MB "
                        + "limit for an indexable document.",
                    field: "documents",
                    expected: "document content under \(maxContentBytes / (1024 * 1024))MB",
                    tool: tool
                )
            )
        }
        return .success(pending)
    }

    static func parsedArguments(_ argumentsJSON: String) -> [String: Any]? {
        guard let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - Result

    /// Report per document, and name the verification step.
    ///
    /// The agent has to be able to tell exactly what landed — the whole reason
    /// this tool exists instead of a proposal queue — so partial success is
    /// reported as partial success rather than collapsed into one boolean.
    static func resultEnvelope(
        tool: String,
        collection: KnowledgeCollection,
        written: [KnowledgeWriteOutcome],
        failures: [(path: String, reason: String)],
        runId: String
    ) -> String {
        if written.isEmpty, !failures.isEmpty {
            let detail = failures.map { "- \($0.path): \($0.reason)" }.joined(separator: "\n")
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Nothing was written to \(collection.name).\n\(detail)",
                tool: tool,
                retryable: false
            )
        }

        let created = written.filter { $0.operation == .create }.count
        let replaced = written.filter { $0.operation == .replace }.count
        var parts: [String] = []
        if created > 0 { parts.append("\(created) created") }
        if replaced > 0 { parts.append("\(replaced) replaced") }

        var text = "Wrote \(written.count) document(s) to [\(collection.name)]"
        if !parts.isEmpty { text += " (\(parts.joined(separator: ", ")))" }
        text += ":\n"
        // Collection-qualified and backticked: the chat renderer links code
        // spans that resolve to a real knowledge document, and models tend to
        // echo this form when telling the user where the file landed.
        text += written.map { "- `\(collection.name)/\($0.relPath)`" }.joined(separator: "\n")

        if !failures.isEmpty {
            text += "\n\nNot written (\(failures.count)):\n"
            text += failures.map { "- \($0.path): \($0.reason)" }.joined(separator: "\n")
        }
        text +=
            "\n\nThese are live in the collection now. Confirm with `search_knowledge` before "
            + "reporting them as done."
        return ToolEnvelope.success(tool: tool, text: text)
    }
}

// MARK: - delete_knowledge

/// Remove documents from a granted collection.
///
/// A separate tool from `write_knowledge`, not a mode of it, and conforming to
/// `PerCallApprovalTool` so no lease or blanket grant can ever cover it.
/// Deletion is the highest-blast-radius operation here and it is precisely
/// what went wrong in osaurus#2439: asked to "delete all of them", the agent
/// ran `rm -rf` on a sandbox directory, reported 62 documents deleted from a
/// collection that never held them, and left the real source untouched to be
/// re-found hours later.
///
/// Every delete is logged with the full prior content, so the Knowledge tab
/// can restore it. That is what makes approving one at a glance defensible.
final class DeleteKnowledgeTool: OsaurusTool, PermissionedTool, KnowledgeWritePreviewingTool,
    PerCallApprovalTool, @unchecked Sendable
{
    let name = "delete_knowledge"

    let description =
        "Delete documents from one of this agent's knowledge collections. The user reviews the "
        + "exact paths and their contents before anything is removed, and approves EVERY call "
        + "individually. Pass all paths for a task in one call. Deletions are recorded and can be "
        + "restored from the Knowledge tab. Use `write_knowledge` to add or replace instead."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    /// Same bound as a write: one reviewable manifest per call.
    static let maxPathsPerCall = WriteKnowledgeTool.maxDocumentsPerCall

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Collection name. Required only when more than one collection is granted."
                ),
            ]),
            "paths": .object([
                "type": .string("array"),
                "description": .string(
                    "Collection-relative document paths to delete. Send them all in one call."
                ),
                "items": .object(["type": .string("string")]),
            ]),
            "rationale": .object([
                "type": .string("string"),
                "description": .string(
                    "Why these documents are being removed. Required, and shown to the user in "
                        + "the approval card."
                ),
            ]),
        ]),
        "required": .array([.string("paths"), .string("rationale")]),
    ])

    init() {}

    func approvalPreview(argumentsJSON: String) async -> KnowledgeWritePreview? {
        guard let args = WriteKnowledgeTool.parsedArguments(argumentsJSON) else { return nil }
        guard case .granted(let collections, _) = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        ),
            let collection = collections.first, collections.count == 1
        else { return nil }
        return KnowledgeWritePreviewBuilder.build(
            collection: collection,
            argumentsJSON: argumentsJSON,
            isDelete: true,
            schema: parameters
        )
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathsReq = Self.paths(from: args, tool: name)
        guard case .success(let validated) = pathsReq else { return pathsReq.failureEnvelope ?? "" }
        // `DocumentsResult` is shared with the write path for its
        // validated-list-or-failure-envelope shape; a delete carries no
        // content, so take just the paths.
        let paths = validated.map(\.path)

        // Required, not optional as it is for a write: a deletion with no
        // stated reason is not something a reviewer can judge.
        let rationale = ((args["rationale"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rationale.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`rationale` is required for a deletion. Say why these documents go.",
                field: "rationale",
                expected: "one line explaining the deletion",
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
        guard collections.count == 1, let collection = collections.first else {
            let names = collections.map(\.name).joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "More than one collection is granted, so `collection` is required for a "
                    + "deletion. Granted collections: \(names).",
                field: "collection",
                expected: "one of the agent's granted collection names",
                tool: name
            )
        }
        guard collection.isEnabled, collection.folderExists else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Collection \(collection.name) is unavailable (disabled, or its folder is missing).",
                tool: name,
                retryable: false
            )
        }

        let runId = (ChatExecutionContext.currentRunId ?? UUID()).uuidString
        let createdBy = ChatExecutionContext.currentAgentId?.uuidString ?? ""

        var removed: [KnowledgeWriteOutcome] = []
        var failures: [(path: String, reason: String)] = []
        for path in paths {
            do {
                removed.append(
                    try await KnowledgeWriteService.shared.delete(
                        collection: collection,
                        relPath: path,
                        runId: runId,
                        createdBy: createdBy,
                        rationale: rationale
                    )
                )
            } catch {
                failures.append(
                    (
                        path,
                        (error as? KnowledgeWriteError)?.errorDescription
                            ?? error.localizedDescription
                    )
                )
            }
        }

        return Self.resultEnvelope(
            tool: name,
            collection: collection,
            removed: removed,
            failures: failures
        )
    }

    // MARK: - Arguments

    static func paths(from args: [String: Any], tool: String) -> WriteKnowledgeTool.DocumentsResult
    {
        var paths: [String] = []
        if let raw = args["paths"] as? [String] {
            paths = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else if let single = args["path"] as? String {
            paths = [single.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        paths = paths.filter { !$0.isEmpty }

        guard !paths.isEmpty else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No paths to delete. Pass `paths` as an array of document paths.",
                    field: "paths",
                    expected: "non-empty array of collection-relative paths",
                    tool: tool
                )
            )
        }
        guard paths.count <= maxPathsPerCall else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "\(paths.count) paths in one call exceeds the limit of \(maxPathsPerCall). "
                        + "Split the deletion into smaller batches.",
                    field: "paths",
                    expected: "at most \(maxPathsPerCall) paths",
                    tool: tool
                )
            )
        }
        var seen: Set<String> = []
        for path in paths where !seen.insert(path).inserted {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`\(path)` appears more than once.",
                    field: "paths",
                    expected: "unique paths",
                    tool: tool
                )
            )
        }
        return .success(paths.map { WriteKnowledgeTool.PendingDocument(path: $0, content: "") })
    }

    // MARK: - Result

    static func resultEnvelope(
        tool: String,
        collection: KnowledgeCollection,
        removed: [KnowledgeWriteOutcome],
        failures: [(path: String, reason: String)]
    ) -> String {
        if removed.isEmpty {
            let detail = failures.map { "- \($0.path): \($0.reason)" }.joined(separator: "\n")
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Nothing was deleted from \(collection.name).\n\(detail)",
                tool: tool,
                retryable: false
            )
        }

        var text = "Deleted \(removed.count) document(s) from [\(collection.name)]:\n"
        text += removed.map { "- \($0.relPath)" }.joined(separator: "\n")
        if !failures.isEmpty {
            text += "\n\nNot deleted (\(failures.count)):\n"
            text += failures.map { "- \($0.path): \($0.reason)" }.joined(separator: "\n")
        }
        // The agent must not report a deletion it cannot see the effect of —
        // the failure that started all this was confidently reporting 62
        // documents gone from a collection that never had them.
        text +=
            "\n\nThese are gone from the collection now, and restorable from the Knowledge tab. "
            + "Confirm with `search_knowledge` before reporting them as removed."
        return ToolEnvelope.success(tool: tool, text: text)
    }
}

// MARK: - edit_knowledge

/// Change part of a knowledge document by find/replace, without restating it.
///
/// `write_knowledge` replaces a whole document, which cannot work once the
/// document approaches the model's output token limit: a 14.5KB file is
/// already around 4K output tokens on a small local model. Asking for a
/// restatement there does not just run slowly, it TRUNCATES, and the truncated
/// text then replaces the original. Observed live on a 120 section catalogue:
/// the model returned 6 sections and the other 114 were destroyed, with the
/// tool reporting a routine "1 replaced".
///
/// Sending the substitution instead of the document removes the cost and the
/// failure mode together, and makes the approval diff small enough to actually
/// read. Underneath it is still a replace, so the write log, the diff card,
/// and revert all behave identically.
final class EditKnowledgeTool: OsaurusTool, PermissionedTool, KnowledgeWritePreviewingTool,
    @unchecked Sendable
{
    let name = "edit_knowledge"

    let description =
        // Same reason as `write_knowledge`: the preference has to survive
        // first-sentence truncation or it may as well not exist.
        "Change part of a document in this agent's knowledge collections by find and replace, "
        + "and PREFER this over `write_knowledge` for any edit to an existing document, since "
        + "restating a long document is slow and risks truncating it. "
        + "Each `find` must match exactly once unless you set `all`. "
        + "The user reviews a diff before anything is saved."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    /// Bounds one call. An edit list longer than this is a rewrite wearing a
    /// disguise, and should go through `write_knowledge` where the whole
    /// document is reviewed.
    static let maxEditsPerCall = 50

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Collection name. Required only when more than one collection is granted."
                ),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Collection-relative markdown path, e.g. `reference/alerts.md`."
                ),
            ]),
            "edits": .object([
                "type": .string("array"),
                "description": .string(
                    "Substitutions applied in order. Send every edit for one document in a "
                        + "single call."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "find": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Exact text to look for, including whitespace. Must appear once "
                                    + "unless `all` is true."
                            ),
                        ]),
                        "replace": .object([
                            "type": .string("string"),
                            "description": .string("Text to put in its place. May be empty to delete."),
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Replace every occurrence instead of requiring a unique match."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("find"), .string("replace")]),
                ]),
            ]),
            "rationale": .object([
                "type": .string("string"),
                "description": .string(
                    "One line on why this document is changing. Shown to the user in the "
                        + "approval card."
                ),
            ]),
        ]),
        "required": .array([.string("path"), .string("edits")]),
    ])

    init() {}

    // MARK: - Approval preview

    func approvalPreview(argumentsJSON: String) async -> KnowledgeWritePreview? {
        guard let args = WriteKnowledgeTool.parsedArguments(argumentsJSON),
            let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        guard case .granted(let collections, _) = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        ),
            let collection = collections.first, collections.count == 1
        else { return nil }
        guard case .success(let edits) = Self.edits(from: args, tool: name),
            let resolved = try? KnowledgeWriteService.resolvedURL(
                collection: collection, relPath: path),
            let data = FileManager.default.contents(atPath: resolved.path),
            let current = String(data: data, encoding: .utf8)
        else { return nil }

        // Preview the RESULT of the edits, so the card shows the same diff the
        // write will produce rather than the substitutions in the abstract.
        guard case .success(let edited) = KnowledgeWriteService.applyEdits(edits, to: current)
        else { return nil }

        var preview = KnowledgeWritePreviewBuilder.build(
            collection: collection,
            documents: [(path, edited)],
            isDelete: false,
            rationale: (args["rationale"] as? String) ?? ""
        )

        // Show the SUBSTITUTIONS, not a whole-document diff.
        //
        // We know exactly what changed, so there is nothing to infer. Diffing
        // is also actively worse here: past 200,000 matrix cells (a ~450 line
        // document) the line-by-line comparison gives up and dumps leading
        // lines, which renders a one phrase substitution as the entire
        // document being deleted. Observed live on a 490 line catalogue.
        if var entry = preview.entries.first, entry.isValid {
            entry.diff = Self.substitutionDiff(edits, in: current, path: path)
            entry.diffTruncated = false
            // The +/- pair would now count the SUMMARY lines, not the
            // document. Exact line counts are shown instead.
            entry.countsDescribeDocument = false
            preview.entries = [entry]
        }
        return preview
    }

    /// Render the edits as a compact diff of what is being substituted, with
    /// the occurrence count so a sweeping `all` edit states its own reach.
    static func substitutionDiff(
        _ edits: [KnowledgeWriteService.KnowledgeEdit],
        in content: String,
        path: String
    ) -> String {
        var lines = ["--- \(path) (before)", "+++ \(path) (after)"]
        var running = content
        for edit in edits {
            let occurrences = running.components(separatedBy: edit.find).count - 1
            let applied = edit.all ? occurrences : min(occurrences, 1)
            let noun = applied == 1 ? "occurrence" : "occurrences"
            lines.append("@@ \(applied) \(noun) @@")
            for line in edit.find.components(separatedBy: "\n") { lines.append("-\(line)") }
            for line in edit.replace.components(separatedBy: "\n") { lines.append("+\(line)") }
            // Track the intermediate document so a later edit's count reflects
            // what an earlier one already changed.
            running = edit.all
                ? running.replacingOccurrences(of: edit.find, with: edit.replace)
                : running.replacingOccurrences(
                    of: edit.find, with: edit.replace, options: [], range: running.range(of: edit.find))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Execute

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args, "path", expected: "collection-relative markdown path", tool: name)
        guard case .value(let rawPath) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        let editsResult = Self.edits(from: args, tool: name)
        guard case .success(let edits) = editsResult else {
            return editsResult.failureEnvelope ?? ""
        }

        let scope = await KnowledgeToolScope.resolve(
            tool: name, collectionName: args["collection"] as? String)
        guard case .granted(let collections, _) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        guard collections.count == 1, let collection = collections.first else {
            let names = collections.map(\.name).joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "More than one collection is granted, so `collection` is required for an edit. "
                    + "Granted collections: \(names).",
                field: "collection",
                expected: "one of the agent's granted collection names",
                tool: name
            )
        }

        let fileURL: URL
        do {
            fileURL = try KnowledgeWriteService.resolvedURL(collection: collection, relPath: path)
        } catch {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: (error as? KnowledgeWriteError)?.errorDescription
                    ?? error.localizedDescription,
                field: "path",
                tool: name
            )
        }
        guard let data = FileManager.default.contents(atPath: fileURL.path),
            let current = String(data: data, encoding: .utf8)
        else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No document at \(path) in [\(collection.name)]. `edit_knowledge` changes an "
                    + "existing document; use `write_knowledge` to create one.",
                field: "path",
                tool: name,
                retryable: false
            )
        }

        switch KnowledgeWriteService.applyEdits(edits, to: current) {
        case .failure(let failure):
            // Retryable: the model can widen the `find` and try again without
            // the user re-approving anything, because nothing was written.
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: failure.message,
                field: "edits",
                tool: name,
                retryable: true
            )
        case .success(let edited):
            guard edited != current else {
                return ToolEnvelope.success(
                    tool: name,
                    text:
                        "No change: the edits produced the document that is already at \(path). "
                        + "Nothing was written."
                )
            }
            do {
                let outcome = try await KnowledgeWriteService.shared.write(
                    collection: collection,
                    relPath: path,
                    content: edited,
                    runId: (ChatExecutionContext.currentRunId ?? UUID()).uuidString,
                    createdBy: ChatExecutionContext.currentAgentId?.uuidString ?? "",
                    rationale: (args["rationale"] as? String) ?? ""
                )
                let applied = edits.count == 1 ? "1 edit" : "\(edits.count) edits"
                return ToolEnvelope.success(
                    tool: name,
                    text:
                        "Applied \(applied) to [\(collection.name)] \(outcome.relPath). "
                        + "This is live in the collection now. Confirm with `search_knowledge` "
                        + "before reporting it as done."
                )
            } catch {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: (error as? KnowledgeWriteError)?.errorDescription
                        ?? error.localizedDescription,
                    tool: name,
                    retryable: false
                )
            }
        }
    }

    // MARK: - Arguments

    enum EditsResult {
        case success([KnowledgeWriteService.KnowledgeEdit])
        case failure(String)

        var failureEnvelope: String? {
            if case .failure(let envelope) = self { return envelope }
            return nil
        }
    }

    static func edits(from args: [String: Any], tool: String) -> EditsResult {
        var parsed: [KnowledgeWriteService.KnowledgeEdit] = []

        if let raw = args["edits"] as? [[String: Any]] {
            for entry in raw {
                guard let find = entry["find"] as? String, !find.isEmpty else {
                    return .failure(
                        ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message: "Every entry in `edits` needs a non-empty `find`.",
                            field: "edits",
                            expected: "array of {find, replace}",
                            tool: tool
                        )
                    )
                }
                parsed.append(
                    .init(
                        find: find,
                        replace: (entry["replace"] as? String) ?? "",
                        all: (entry["all"] as? Bool) ?? false
                    )
                )
            }
        } else if let find = args["find"] as? String, !find.isEmpty {
            // A model handed an array parameter reliably sends one of each.
            parsed.append(
                .init(
                    find: find,
                    replace: (args["replace"] as? String) ?? "",
                    all: (args["all"] as? Bool) ?? false
                )
            )
        }

        guard !parsed.isEmpty else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No edits to apply. Pass `edits` as an array of {find, replace}.",
                    field: "edits",
                    expected: "non-empty array of {find, replace}",
                    tool: tool
                )
            )
        }
        guard parsed.count <= maxEditsPerCall else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "\(parsed.count) edits exceeds the limit of \(maxEditsPerCall). That many "
                        + "changes is a rewrite; use `write_knowledge` so the whole document is "
                        + "reviewed.",
                    field: "edits",
                    expected: "at most \(maxEditsPerCall) edits",
                    tool: tool
                )
            )
        }
        return .success(parsed)
    }
}
