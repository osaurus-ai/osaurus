//
//  KnowledgeWritePreview.swift
//  OsaurusCore — Knowledge
//
//  Turns a pending `write_knowledge` / `delete_knowledge` call into a
//  reviewable manifest, BEFORE it runs.
//
//  This is the load-bearing half of moving knowledge consent to the
//  permission modal. The modal renders `prettyArguments` — a pretty-printed
//  JSON dump — and approving a 29KB document replacement out of a JSON blob
//  is not informed consent. Without a real diff, call-time approval would be
//  strictly worse than the deferred review it replaces, not better.
//
//  Deliberately a pure model with no SwiftUI in it: the manifest is built and
//  tested against synthetic arguments long before any tool emits them, and the
//  view is a dumb renderer over the result.
//

import Foundation

/// One document a pending call would change.
public struct KnowledgeWritePreviewEntry: Sendable, Equatable, Identifiable {
    public var id: String { relPath }
    public var relPath: String
    /// What the call would do, resolved against what is on disk NOW — the
    /// agent does not get to declare this.
    public var operation: KnowledgeWriteOperation
    /// Unified diff against the current file, for a create or replace.
    /// Already capped by `WorkspaceWriteSafety` (80 lines / 12K characters),
    /// the same cap the chat diff-card uses, so both surfaces agree.
    public var diff: String
    /// True when the rendering was capped. The modal says so rather than
    /// implying the reader saw the whole document.
    public var diffTruncated: Bool
    /// For a delete only: the content that would be lost, capped. A delete has
    /// nothing to diff against, so it shows what is there now.
    ///
    /// Deliberately the ONLY full-text field on an entry. Carrying prior and
    /// new content per entry would put ~124MB behind a 62-document batch of
    /// 2MB documents, and neither is rendered for a create or replace because
    /// the diff already is.
    public var deletedContent: String
    /// Non-blocking cautions shown beside the entry: the write can proceed,
    /// but something about it deserves a second look before approving.
    /// An array because a single replacement can trip more than one (gutting
    /// a document AND dropping its frontmatter), and hiding either behind the
    /// other is how a destructive write gets waved through.
    public var warnings: [String] = []
    /// Lines in the document as it stands, and as the replacement would leave
    /// it. Exact, unlike the +/- counts, which come from a diff capped at 80
    /// lines: a replacement that deletes 480 lines shows only the first 80 of
    /// them, so the counts alone materially understate the change.
    public var priorLineCount: Int = 0
    public var newLineCount: Int = 0
    /// Whether `addedLines`/`removedLines` describe the DOCUMENT's change.
    ///
    /// False when the rendered diff is a substitution summary: those counts
    /// then describe the summary itself, which says nothing about the
    /// document. Live-observed as `+40 −38` on a 120 occurrence edit, numbers
    /// left over from a whole-document diff that had already been discarded.
    /// The exact line counts are shown instead.
    public var countsDescribeDocument: Bool = true
    public var addedLines: Int
    public var removedLines: Int
    /// Populated when the entry cannot be applied at all (path escapes the
    /// collection, non-markdown target). Shown inline so a batch that is
    /// partly invalid is visible before approving, not after.
    public var problem: String?

    public var isValid: Bool { problem == nil }
}

/// Everything the approval modal needs to render a knowledge write.
public struct KnowledgeWritePreview: Sendable, Equatable {
    public var collectionName: String
    public var entries: [KnowledgeWritePreviewEntry]
    /// Short reason supplied by the calling agent, shown verbatim.
    public var rationale: String
    /// Set when the arguments could not be understood at all.
    public var parseError: String?

    public var createCount: Int { entries.filter { $0.operation == .create }.count }
    public var replaceCount: Int { entries.filter { $0.operation == .replace }.count }
    public var deleteCount: Int { entries.filter { $0.operation == .delete }.count }
    public var invalidCount: Int { entries.filter { !$0.isValid }.count }

    /// One-line summary for the modal heading.
    ///
    /// Reads as a sentence rather than a stat block, because this is the line
    /// a user actually decides on. Avoids em dashes per the project's UI
    /// string convention.
    public var summary: String {
        guard parseError == nil else { return "This call could not be read." }
        guard !entries.isEmpty else { return "This call would change nothing." }

        var parts: [String] = []
        if createCount > 0 { parts.append("\(createCount) new") }
        if replaceCount > 0 { parts.append("\(replaceCount) replaced") }
        if deleteCount > 0 { parts.append("\(deleteCount) deleted") }
        let noun = entries.count == 1 ? "document" : "documents"
        var line = "\(entries.count) \(noun) in \"\(collectionName)\": \(parts.joined(separator: ", "))."
        if invalidCount > 0 {
            let problems = invalidCount == 1 ? "1 cannot be applied" : "\(invalidCount) cannot be applied"
            line += " \(problems)."
        }
        return line
    }
}

public enum KnowledgeWritePreviewBuilder {

    /// Cap on the delete preview. Diffs are already capped upstream by
    /// `WorkspaceWriteSafety`; a delete has no diff, so its content needs its
    /// own bound or a 2MB document lands whole in the modal.
    static let maxDeletePreviewCharacters = 20_000

    /// Build a manifest for a pending call.
    ///
    /// Reads the collection folder to decide create vs replace, so the
    /// operation shown is the one that would actually happen rather than the
    /// one the model claimed.
    public static func build(
        collection: KnowledgeCollection,
        documents: [(relPath: String, content: String)],
        isDelete: Bool,
        rationale: String
    ) -> KnowledgeWritePreview {
        var entries: [KnowledgeWritePreviewEntry] = []

        for document in documents {
            // Confinement is checked here too, so an invalid path is visible
            // in the manifest rather than failing halfway through the batch
            // after the user already approved it.
            let fileURL: URL
            do {
                fileURL = try KnowledgeWriteService.resolvedURL(
                    collection: collection,
                    relPath: document.relPath
                )
            } catch {
                entries.append(
                    KnowledgeWritePreviewEntry(
                        relPath: document.relPath,
                        operation: isDelete ? .delete : .create,
                        diff: "",
                        diffTruncated: false,
                        deletedContent: "",
                        addedLines: 0,
                        removedLines: 0,
                        problem: (error as? KnowledgeWriteError)?.errorDescription
                            ?? error.localizedDescription
                    )
                )
                continue
            }

            let priorData = FileManager.default.contents(atPath: fileURL.path)
            let priorContent = priorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let existed = priorData != nil

            if isDelete {
                entries.append(
                    KnowledgeWritePreviewEntry(
                        relPath: document.relPath,
                        operation: .delete,
                        diff: "",
                        diffTruncated: false,
                        deletedContent: capDeletePreview(priorContent),
                        addedLines: 0,
                        removedLines: lineCount(priorContent),
                        // Deleting something that is not there is worth
                        // surfacing before approval, not as a mid-batch error.
                        problem: existed ? nil : "No document at this path."
                    )
                )
                continue
            }

            // Normalize exactly as the tool will, so the diff shown is the
            // content that lands.
            let content = KnowledgeWriteService.strippingReadPreamble(document.content)
            let diff = WorkspaceWriteSafety.unifiedDiffText(
                old: priorContent,
                new: content,
                path: document.relPath,
                existed: existed
            )
            entries.append(
                KnowledgeWritePreviewEntry(
                    relPath: document.relPath,
                    operation: existed ? .replace : .create,
                    diff: honestDiff(
                        diff.text,
                        priorLines: lineCount(priorContent),
                        newLines: lineCount(content)
                    ),
                    diffTruncated: diff.truncated,
                    deletedContent: "",
                    // Losing facets the document already HAS outranks a
                    // malformed block in new content: one destroys existing
                    // metadata, the other merely fails to add any.
                    warnings: Self.warnings(prior: priorContent, replacement: content),
                    priorLineCount: lineCount(priorContent),
                    newLineCount: lineCount(content),
                    addedLines: countPrefixed(diff.text, "+"),
                    removedLines: countPrefixed(diff.text, "-"),
                    problem: nil
                )
            )
        }

        return KnowledgeWritePreview(
            collectionName: collection.name,
            entries: entries,
            rationale: rationale,
            parseError: nil
        )
    }

    /// Build a manifest straight from a tool call's arguments.
    ///
    /// Tolerates both the batch shape (`documents: [{path, content}]`) and a
    /// single `{path, content}`, because a model handed an array parameter
    /// reliably sends one of each. Returns a preview carrying `parseError`
    /// rather than throwing: the modal must render SOMETHING, and "this call
    /// could not be read" is itself a reason to deny.
    public static func build(
        collection: KnowledgeCollection,
        argumentsJSON: String,
        isDelete: Bool,
        schema: JSONValue? = nil
    ) -> KnowledgeWritePreview {
        guard let data = argumentsJSON.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else {
            return KnowledgeWritePreview(
                collectionName: collection.name,
                entries: [],
                rationale: "",
                parseError: "Arguments are not a JSON object."
            )
        }

        // Preview exactly what the tool will RECEIVE, not what the model
        // literally sent.
        //
        // The permission gate runs before `ToolRegistry`'s schema coercion, so
        // without this the two see different arguments. A model that sends
        // `documents` as a stringified array — a routine small-model slip —
        // produces a card reading "This call could not be read", while
        // coercion later turns that same string into a real array and the
        // documents are written. The user would have approved a manifest of
        // nothing and got a batch of files. Coercing here with the tool's own
        // schema makes the card and the execution agree.
        let coerced: Any = {
            guard let schema else { return parsed }
            return SchemaValidator.coerceArguments(parsed, against: schema)
        }()

        guard let root = coerced as? [String: Any] else {
            return KnowledgeWritePreview(
                collectionName: collection.name,
                entries: [],
                rationale: "",
                parseError: "Arguments are not a JSON object."
            )
        }

        let rationale = (root["rationale"] as? String) ?? ""
        var documents: [(relPath: String, content: String)] = []

        if isDelete {
            if let paths = root["paths"] as? [String] {
                documents = paths.map { ($0, "") }
            } else if let path = root["path"] as? String {
                documents = [(path, "")]
            }
        } else if let raw = root["documents"] as? [[String: Any]] {
            documents = raw.compactMap { entry in
                guard let path = entry["path"] as? String else { return nil }
                return (path, (entry["content"] as? String) ?? "")
            }
        } else if let path = root["path"] as? String {
            documents = [(path, (root["content"] as? String) ?? "")]
        }

        guard !documents.isEmpty else {
            return KnowledgeWritePreview(
                collectionName: collection.name,
                entries: [],
                rationale: rationale,
                parseError: "No documents named in this call."
            )
        }

        return build(
            collection: collection,
            documents: documents,
            isDelete: isDelete,
            rationale: rationale
        )
    }

    // MARK: - Helpers

    /// A replacement that keeps this fraction of the document or less is
    /// treated as a rewrite that guts it. Live-observed: a model asked to
    /// change one sentence in every section of a 120-section catalogue
    /// returned two sections, and the write was accepted as a routine
    /// "1 replaced" because the diff was capped long before the damage
    /// showed.
    static let gutsDocumentBelowRatio = 0.5
    /// Below this the document is too small for a ratio to mean anything.
    static let gutsDocumentMinimumPriorLines = 20

    /// Non-blocking cautions for an entry, most consequential first.
    ///
    /// All that apply, not just the first: a replacement can gut a document
    /// AND drop its frontmatter, and showing only one lets the other through.
    private static func warnings(prior: String, replacement: String) -> [String] {
        var out: [String] = []

        let priorLines = lineCount(prior)
        let newLines = lineCount(replacement)
        if priorLines >= gutsDocumentMinimumPriorLines,
            Double(newLines) <= Double(priorLines) * gutsDocumentBelowRatio
        {
            let removed = Int((1 - Double(newLines) / Double(priorLines)) * 100)
            out.append(
                "This replaces a \(priorLines) line document with \(newLines) lines, removing "
                    + "about \(removed)% of it. The diff below is shortened, so it does not show "
                    + "everything being deleted."
            )
        }

        if let dropped = KnowledgeWriteService.droppedFrontmatterFacets(
            prior: prior, replacement: replacement)
        {
            out.append(
                "This replacement has no frontmatter, so the document loses its "
                    + "\(dropped.joined(separator: ", ")). It will stop matching type and tag filters."
            )
        }
        if let keys = KnowledgeWriteService.unfencedFrontmatterKeys(replacement) {
            out.append(
                "Frontmatter (\(keys.joined(separator: ", "))) is missing its --- fences, so it "
                    + "will be indexed as body text and the document will have no type or tags."
            )
        }
        return out
    }

    /// Marker `WorkspaceWriteSafety` emits when the documents are too large to
    /// diff line by line and it falls back to dumping leading lines.
    static let boundedPrefixMarker = "large diff preview uses bounded prefixes"

    /// Replace an uncomputable diff with an honest statement of that fact.
    ///
    /// The fallback lists the first 40 OLD lines prefixed `-` and the first 40
    /// NEW lines prefixed `+`. On a 490 line document — past the 200,000 cell
    /// matrix bound — a one phrase substitution therefore renders as the entire
    /// document being deleted. Observed live on exactly that document, on the
    /// one surface whose whole job is telling the truth about a change. Better
    /// to say the diff could not be computed than to show a false one.
    static func honestDiff(_ diff: String, priorLines: Int, newLines: Int) -> String {
        guard diff.contains(boundedPrefixMarker) else { return diff }
        return
            "This document is too large to compare line by line, so no diff is shown.\n"
            + "\(priorLines) lines before, \(newLines) lines after.\n"
            + "Expand the document in the collection to review it in full before approving."
    }

    private static func capDeletePreview(_ text: String) -> String {
        guard text.count > maxDeletePreviewCharacters else { return text }
        return String(text.prefix(maxDeletePreviewCharacters))
    }

    private static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    }

    /// Count diff body lines starting with `marker`, skipping the `---` /
    /// `+++` file headers so a one-line new file reads `+1 -0`.
    private static func countPrefixed(_ diff: String, _ marker: Character) -> Int {
        diff.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) {
            count, line in
            guard let first = line.first, first == marker else { return }
            if line.hasPrefix("+++") || line.hasPrefix("---") { return }
            count += 1
        }
    }
}
