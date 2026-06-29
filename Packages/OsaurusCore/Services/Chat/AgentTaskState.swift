//
//  AgentTaskState.swift
//  osaurus
//
//  The per-task state machine the harness holds so the model doesn't have to.
//
//  Diagnosis (see docs/AGENT_LOOP.md): a 1B-active model used as both planner
//  and executor in a free, stateless loop has to reconstruct from raw tool
//  text — every turn — where it is, what it just received, and what the next
//  valid move is. That reconstruction is the work it fails at. This type moves
//  that bookkeeping into the loop: it classifies each tool result, tracks what
//  the last result implies, dedupes back-to-back identical re-issues, and
//  emits a (non-load-bearing) next-step nudge. The structured result objects
//  (`ToolEnvelope.listing`, `kind: "file"`) are what actually carry the win —
//  this layer is a thin nudge on top, validated to not be load-bearing.
//
//  One instance per loop run. `ChatSession` keeps a session-scoped instance so
//  a listing survives across user messages; the HTTP `/agents/{id}/run` and
//  plugin loops are stateless across requests by design, so they use a
//  per-request / per-invocation instance (nothing to survive).
//

import Foundation

/// Classification of a tool result, derived from the canonical envelope.
/// The loop branches on this without the model interpreting anything.
public enum ToolResultClass: Equatable, Sendable {
    /// A directory listing with no entries.
    case emptyListing
    /// A directory listing with at least one entry.
    case populatedListing
    /// A directory listing that hit a cap (entries are incomplete).
    case partialListing
    /// File content (`kind: "file"`).
    case fileContent
    /// A referenced path does not exist (`kind: "not_found"`).
    case notFound
    /// Any other failure envelope.
    case error
    /// Native image job completed and returned saved image paths. `isEdit`
    /// distinguishes a fresh generation from an edit of an existing image, so
    /// the follow-up nudge only suggests editing AFTER a generation.
    /// `editAvailable` is whether a ready edit model is installed; when false
    /// the post-generation edit nudge is suppressed (it would steer toward an
    /// edit the runtime can't perform).
    case nativeImageGeneration(paths: [String], isEdit: Bool, editAvailable: Bool)
    /// Any success that isn't a listing or file read.
    case other
}

/// A single listed entry, parsed into a typed (Sendable) form.
public struct ListingEntry: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
}

/// A snapshot of the most recent directory listing, retained so a later
/// reference ("read the file") can be resolved against it. Phase-3 reference
/// resolution will read this; today it backs the post-listing nudge.
public struct ListingSnapshot: Equatable, Sendable {
    public let path: String
    public let entries: [ListingEntry]
    /// True when the listing was capped, so its entries are incomplete and it
    /// must not be treated as an exhaustive set for find-by-name.
    public let truncated: Bool
}

/// Identity of a tool call for dedupe: tool name + canonicalised arguments.
public struct CallSignature: Hashable, Sendable {
    public let name: String
    public let canonicalArgs: String
}

/// Per-task state threaded through a tool-call loop. Not thread-safe by
/// design: a single loop drives it sequentially. Each loop owns its own
/// instance.
public final class AgentTaskState {

    // MARK: Configuration

    /// When false, `nextStepBias()` returns nil. The structured result objects
    /// must get the model to descend on their own; this flag exists so the
    /// validation gate can prove the nudge is not load-bearing.
    public var biasEnabled: Bool

    /// Read-like tools whose results are eligible for replay-on-duplicate and
    /// whose `path` freshness is invalidated by a write to the same path.
    private static let readLikeTools: Set<String> = [
        "file_read", "file_search", "sandbox_read_file", "sandbox_search_files",
    ]

    /// Search tools' results depend on MANY paths, so any write — not just
    /// one to the searched path — invalidates their fresh entries.
    private static let searchLikeTools: Set<String> = [
        "file_search", "sandbox_search_files",
    ]

    /// Tools that mutate a path; recording one invalidates any fresh read
    /// signature for that path so a verify-read re-executes.
    private static let writeLikeTools: Set<String> = [
        "file_edit", "file_write", "sandbox_write_file",
    ]

    /// Tools that run arbitrary commands (`rm`/`mv`/redirects can mutate any
    /// path, including via scripts we cannot parse). Recording one wipes ALL
    /// fresh reads — blunt but correct; the only cost is a re-read. Applied
    /// regardless of exit code: a failed command may still have mutated
    /// before failing.
    private static let execLikeTools: Set<String> = ["shell_run", "sandbox_exec"]

    /// Tools whose `invalid_args` / `not_found` failures are DETERMINISTIC
    /// given an unchanged filesystem / capability catalog: re-issuing the
    /// identical call must return the identical error. Their held errors are
    /// replayed instead of re-executed (observed live: a model repeating the
    /// same failing `file_edit` 8× until the iteration cap). `capabilities_load`
    /// qualifies because capability ids are a closed vocabulary — a bad/unknown
    /// id fails identically on every retry. `shell_run` and `db_*` are
    /// deliberately excluded — identical re-runs there are legitimate retries
    /// that may succeed.
    private static let deterministicErrorTools: Set<String> = [
        "file_read", "file_search", "file_edit", "capabilities_load",
    ]

    /// Error kinds eligible for held-error replay. Both depend only on the
    /// arguments + current file state, never on transient conditions.
    private static let deterministicErrorKinds: Set<String> = [
        ToolEnvelope.Kind.invalidArgs.rawValue,
        ToolEnvelope.Kind.notFound.rawValue,
    ]

    /// The listing nudge is REACTIVE, not proactive: it fires only once the
    /// model has produced this many listings without an intervening read —
    /// i.e. it is observed to be wandering rather than descending. A capable
    /// model that lists once and immediately descends never reaches this, so
    /// it is never nudged; a stuck model is nudged exactly when it loops, and
    /// keeps being nudged while it stays stuck (no premature silence).
    private static let listingReactiveThreshold = 2

    /// Repeated-call detector threshold for NON-read tools (write/exec/...):
    /// on the Nth identical (tool + canonical args) execution the bias notice
    /// fires. Reads are covered by the dedupe replay instead — they never
    /// reach this counter. Never hard-blocks: the call still executes, the
    /// model just gets told it's looping.
    private static let repeatedCallThreshold = 3

    // MARK: State

    /// A read result still considered fresh: the canonical path it read and
    /// the EXACT envelope the model received (replayed verbatim on a dedupe
    /// short-circuit so the model never gets back less than it had).
    private struct FreshRead {
        let canonicalPath: String
        let envelope: String
    }

    /// A deterministic error envelope held for replay: the exact error the
    /// model received and the canonical path the failing call targeted (nil
    /// for path-less searches). Invalidated by the same rules as fresh
    /// reads — a write to the path or any exec clears it, because the
    /// filesystem may have changed and the identical call could now succeed.
    private struct HeldError {
        let canonicalPath: String?
        let envelope: String
    }

    /// The class of the most recently recorded result.
    public private(set) var lastResultClass: ToolResultClass?
    /// The most recent directory listing (survives across messages in
    /// `ChatSession`; per-request elsewhere).
    public private(set) var lastListing: ListingSnapshot?
    /// The exact envelope the model received for the most recent call.
    public private(set) var lastResultEnvelope: String?
    /// The most recent tool name, used when the same result kind has different
    /// follow-up semantics for generate vs edit.
    private var lastToolName: String?
    /// Reads still considered fresh, keyed by signature. A write/edit to a
    /// read's path invalidates its entry so a verify-read re-executes instead
    /// of replaying stale pre-edit content.
    private var freshReads: [CallSignature: FreshRead] = [:]
    /// Deterministic folder-tool errors held for replay, keyed by signature.
    private var heldErrors: [CallSignature: HeldError] = [:]
    /// How many times each held error has been replayed (drives escalation).
    private var heldErrorReplays: [CallSignature: Int] = [:]
    /// Notice produced by the most recent `heldResult` hit when it replayed
    /// a held ERROR (nil for fresh-read replays — the driver's standard
    /// dedupe notice covers those). The driver stages this verbatim.
    public private(set) var lastReplayNotice: String?
    /// Listings recorded since the last file read; gates the listing nudge.
    private var consecutiveListingsWithoutRead = 0
    /// Execution counts per signature for NON-read tools (reads go through
    /// the dedupe replay instead). Drives the repeated-call nudge.
    private var nonReadCallCounts: [CallSignature: Int] = [:]
    /// Set when the most recent recorded call was a non-read tool repeated
    /// to (or past) `repeatedCallThreshold`; cleared by any other call.
    private var repeatedCallName: String?

    public init(biasEnabled: Bool = true) {
        self.biasEnabled = biasEnabled
    }

    // MARK: Per-message lifecycle

    /// Reset the within-message dedupe tracking (fresh reads). `lastListing`
    /// deliberately persists so a listing from one user message can be
    /// referenced by the next. Called by `ChatSession` at the start of each
    /// send; one-shot loops simply never call it.
    public func beginMessage() {
        lastResultEnvelope = nil
        lastToolName = nil
        freshReads.removeAll(keepingCapacity: true)
        heldErrors.removeAll(keepingCapacity: true)
        heldErrorReplays.removeAll(keepingCapacity: true)
        lastReplayNotice = nil
        consecutiveListingsWithoutRead = 0
        nonReadCallCounts.removeAll(keepingCapacity: true)
        repeatedCallName = nil
    }

    // MARK: Dedupe

    /// True when `name` participates in dedupe replay (read-like tools).
    /// The loop driver uses this to recognise duplicate read siblings
    /// inside a single parallel batch — non-read duplicates always
    /// re-execute by design (they may legitimately differ).
    public static func isReplayEligible(name: String) -> Bool {
        readLikeTools.contains(name)
    }

    /// If this call re-issues something the loop already holds the exact
    /// answer for, return that EXACT envelope so the loop replays it instead
    /// of re-executing. Two sources, checked in order:
    ///   1. Fresh reads — a still-fresh read (same tool + canonical args,
    ///      not invalidated by an intervening write to its path).
    ///   2. Held deterministic errors — an `invalid_args`/`not_found` error
    ///      from a deterministic folder tool, with no intervening write/exec
    ///      that could change the outcome. Replaying it (with an escalating
    ///      notice via `lastReplayNotice`) converts an observed N-execution
    ///      failure spiral into one execution + cached replays.
    /// Returns nil for novel calls or invalidated entries. The replay is
    /// verbatim — never a collapsed/summarized form — so it is neutral.
    public func heldResult(name: String, argsJSON: String) -> String? {
        lastReplayNotice = nil
        let sig = signature(name: name, argsJSON: argsJSON)
        if Self.readLikeTools.contains(name), let fresh = freshReads[sig] {
            return fresh.envelope
        }
        if Self.deterministicErrorTools.contains(name), let held = heldErrors[sig] {
            let replays = (heldErrorReplays[sig] ?? 0) + 1
            heldErrorReplays[sig] = replays
            let failures = replays + 1  // original execution + replays
            lastReplayNotice =
                "This exact `\(name)` call has now failed \(failures) times with the same error (the result above is a replay — it was NOT re-executed, and re-issuing it cannot succeed). You MUST change the arguments, or report what is blocking you."
            return held.envelope
        }
        return nil
    }

    /// Convenience boolean mirror of `heldResult`.
    public func isDuplicate(name: String, argsJSON: String) -> Bool {
        heldResult(name: name, argsJSON: argsJSON) != nil
    }

    // MARK: Recording

    /// Record a tool call and its result, updating the state machine.
    public func record(name: String, argsJSON: String, result: String) {
        let sig = signature(name: name, argsJSON: argsJSON)
        let resultClass = Self.classify(result)

        lastResultEnvelope = result
        lastResultClass = resultClass
        lastToolName = name

        // An exec can mutate ANY path (rm/mv/redirects, scripts) — wipe all
        // fresh reads so no post-mutation verify-read replays stale content.
        // Held errors follow the same rule: the exec may have created the
        // missing path or fixed the file, so the identical call could now
        // succeed and must re-execute.
        if Self.execLikeTools.contains(name) {
            freshReads.removeAll(keepingCapacity: true)
            heldErrors.removeAll(keepingCapacity: true)
            heldErrorReplays.removeAll(keepingCapacity: true)
        }

        // A write/edit invalidates any fresh read of the same path so the
        // verify-read re-executes instead of replaying stale pre-edit content.
        // Read and write canonicalize the path through the SAME helper, so
        // `file_read "config.json"` and `file_edit "./config.json"` match.
        // Search results span many paths, so ANY write stales them.
        // Held errors use the same rules: a write to the failing call's path
        // may make the identical call succeed (e.g. file_write creates the
        // file a held `not_found` read complained about), and search errors
        // depend on many paths so any write clears them.
        if Self.writeLikeTools.contains(name), let target = pathArgument(argsJSON) {
            let targetCanonical = Self.canonicalPath(target)
            freshReads = freshReads.filter { entry in
                if Self.searchLikeTools.contains(entry.key.name) { return false }
                return entry.value.canonicalPath != targetCanonical
            }
            heldErrors = heldErrors.filter { entry in
                if Self.searchLikeTools.contains(entry.key.name) { return false }
                return entry.value.canonicalPath != targetCanonical
            }
        }

        // Capture (or clear) a held deterministic error for this signature.
        // Only `invalid_args`/`not_found` from the deterministic folder tools
        // qualify: given an unchanged filesystem, re-executing the identical
        // call must return the identical error, so replaying is honest.
        if Self.deterministicErrorTools.contains(name) {
            if ToolEnvelope.isError(result),
                let kind = Self.errorKind(result),
                Self.deterministicErrorKinds.contains(kind)
            {
                heldErrors[sig] = HeldError(
                    canonicalPath: pathArgument(argsJSON).map(Self.canonicalPath),
                    envelope: result
                )
            } else {
                // A success (or non-deterministic error) supersedes any held
                // error for this exact call.
                heldErrors[sig] = nil
                heldErrorReplays[sig] = nil
            }
        }

        // Repeated-call detector for non-read tools: reads are handled by
        // the dedupe replay, but an identical write/exec re-executes by
        // design (it may legitimately differ) — so count it, and once the
        // model has issued the same call `repeatedCallThreshold` times,
        // arm the bias nudge. Any different call disarms it.
        if Self.readLikeTools.contains(name) {
            repeatedCallName = nil
        } else {
            let count = (nonReadCallCounts[sig] ?? 0) + 1
            nonReadCallCounts[sig] = count
            repeatedCallName = count >= Self.repeatedCallThreshold ? name : nil
        }

        // Wandering counter: a listing is a step that hasn't reached a file
        // yet, so it increments. ONLY a successful file read counts as
        // progress and resets it. A `not_found` / `error` is a FAILED read —
        // not progress — so it neither increments nor resets, which lets
        // wandering accumulate across interleaved failed reads (e.g.
        // list -> bad read -> list still reaches the reactive threshold)
        // while the `not_found` fires its own reactive nudge in parallel.
        switch resultClass {
        case .emptyListing, .populatedListing, .partialListing:
            consecutiveListingsWithoutRead += 1
            lastListing = parseListing(result)
        case .fileContent:
            consecutiveListingsWithoutRead = 0
        case .notFound, .error, .nativeImageGeneration, .other:
            break
        }  // nativeImageGeneration carries associated values; matched without binding

        // Mark a successful read-like result as fresh (with its exact
        // envelope) so a re-issue replays it until a write invalidates it.
        // Search tools may omit `path` (it defaults to the root); key them
        // on "." — write invalidation clears search entries wholesale, so
        // the sentinel never has to match a written path.
        if Self.readLikeTools.contains(name), ToolEnvelope.isSuccess(result) {
            if let target = pathArgument(argsJSON) {
                freshReads[sig] = FreshRead(
                    canonicalPath: Self.canonicalPath(target),
                    envelope: result
                )
            } else if Self.searchLikeTools.contains(name) {
                freshReads[sig] = FreshRead(canonicalPath: ".", envelope: result)
            }
        }
    }

    // MARK: Next-step nudge (non-load-bearing)

    /// A short, system-attributed next-step nudge for the most recent result,
    /// or nil. The listing nudge is REACTIVE: it fires only after two listings
    /// without an intervening read (the model is observed wandering), so a
    /// capable model that descends immediately is never nudged — the
    /// structured `entries[]` carries the descent on its own. It keeps firing
    /// while the model stays stuck (no upper silence cap). `not_found` is
    /// reactive by nature (an observed failure) and always fires. Returns nil
    /// entirely when `biasEnabled` is false.
    public func nextStepBias() -> String? {
        guard biasEnabled, let last = lastResultClass else { return nil }

        // Repeated identical write/exec call: the strongest stuck signal we
        // have, so it outranks the result-class nudges. Reactive (3rd
        // identical call) and advisory only — the call still executed.
        if let name = repeatedCallName {
            return
                "You have now made the exact same `\(name)` call with identical arguments \(Self.repeatedCallThreshold)+ times. Repeating it will not change the outcome — change your approach, or report what is blocking you."
        }

        // Listing nudges are reactive: suppressed until the model is observed
        // wandering (this many listings without an intervening read), so a
        // model that descends after its first listing is never nudged.
        let isWandering = consecutiveListingsWithoutRead >= Self.listingReactiveThreshold

        switch last {
        case .populatedListing:
            guard isWandering else { return nil }
            return
                "Entries are in `result.entries`. To read one, call `file_read` with that entry's `path` value. Do not re-list this directory."
        case .emptyListing:
            guard isWandering else { return nil }
            return
                "This directory is empty (`entry_count` is 0). Do not pick or invent an entry; report it empty or list a different path."
        case .partialListing:
            guard isWandering else { return nil }
            return
                "This listing was truncated; the entries shown are incomplete. Use `file_search` to find a specific file by name instead of picking blindly from the partial set."
        case .notFound:
            // If the last listing was truncated, its entries are incomplete —
            // steering the model back into that partial set is how a present
            // file gets wrongly reported absent. Send it to file_search.
            if lastListing?.truncated == true {
                return
                    "Path not found, and the last directory listing was incomplete (truncated). Use `file_search` with `target:\"files\"` and a token from the name instead of picking from the partial listing."
            }
            return
                "Path not found. Pick a `path` from the most recent listing's entries, or list the parent directory."
        case .nativeImageGeneration(let paths, let isEdit, let editAvailable):
            // Only nudge toward an edit AFTER a fresh generation, never after an
            // edit (which would loop), and never when no ready edit model is
            // installed (the nudge would steer toward a guaranteed failure).
            guard editAvailable, lastToolName == "image", !isEdit, !paths.isEmpty
            else { return nil }
            let joinedPaths = paths.map { "`\($0)`" }.joined(separator: ", ")
            return
                "The previous `image` result saved image path(s): \(joinedPaths). "
                + "If the user asked for ANY follow-up that modifies, edits, changes, adds to, "
                + "recolors, or transforms THAT generated image, you MUST call `image` now "
                + "with `source_paths` set to those path value(s) — do NOT call `image` "
                + "without `source_paths` again (that produces a brand-new unrelated image, not an "
                + "edit of this one). Only if no such follow-up was requested should you give a brief "
                + "final confirmation. Do not narrate the edit as the final answer instead of calling the tool."
        case .fileContent, .error, .other:
            return nil
        }
    }

    // MARK: - Classification

    /// Classify a result envelope into a `ToolResultClass`. Pure function so
    /// it can be unit-tested independently of any loop.
    public static func classify(_ envelope: String) -> ToolResultClass {
        if ToolEnvelope.isError(envelope) {
            if let data = envelope.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                dict["kind"] as? String == ToolEnvelope.Kind.notFound.rawValue
            {
                return .notFound
            }
            return .error
        }
        guard let payload = ToolEnvelope.successPayload(envelope) as? [String: Any] else {
            return .other
        }
        switch payload["kind"] as? String {
        case "listing":
            let count = payload["entry_count"] as? Int ?? (payload["entries"] as? [Any])?.count ?? 0
            if count == 0 { return .emptyListing }
            if payload["truncated"] as? Bool == true { return .partialListing }
            return .populatedListing
        case "file":
            return .fileContent
        case "native_image_generation_job":
            let paths = nativeImagePaths(from: payload)
            if !paths.isEmpty {
                let isEdit = (payload["mode"] as? String) == "edit"
                // Absent `edit_available` (older payloads / external callers)
                // defaults to true so the existing gen→edit nudge still fires.
                let editAvailable = (payload["edit_available"] as? Bool) ?? true
                return .nativeImageGeneration(
                    paths: paths,
                    isEdit: isEdit,
                    editAvailable: editAvailable
                )
            }
            return .other
        default:
            return .other
        }
    }

    private static func nativeImagePaths(from payload: [String: Any]) -> [String] {
        guard let images = payload["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["path"] as? String,
                !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return path
        }
    }

    /// Pull the `kind` field from an error envelope, or nil.
    private static func errorKind(_ envelope: String) -> String? {
        guard let data = envelope.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["kind"] as? String
    }

    // MARK: - Path canonicalization (shared)

    /// Normalise a path so two spellings of the same path compare equal.
    /// Used by BOTH the read-signature key and the write-target invalidation
    /// check — if these diverged, invalidation would silently miss and a
    /// verify-read could be short-circuited with stale content.
    static func canonicalPath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("./") { p.removeFirst(2) }
        // `standardizingPath` resolves `.`/`..`/`~` and collapses `//`.
        p = (p as NSString).standardizingPath
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Helpers

    private func signature(name: String, argsJSON: String) -> CallSignature {
        CallSignature(name: name, canonicalArgs: Self.canonicalArgs(argsJSON))
    }

    /// Canonicalise an arguments JSON string to a stable, sorted-key form so
    /// `{"a":1,"b":2}` and `{"b":2,"a":1}` hash equal. Public so eval
    /// scoring can build duplicate keys with the SAME canonicalisation the
    /// loop's dedupe uses — a scorer with weaker key rules would flag
    /// duplicates the loop correctly distinguishes (or miss real ones).
    public static func canonicalArgs(_ argsJSON: String) -> String {
        guard let data = argsJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let canonical = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.sortedKeys]
            ),
            let str = String(data: canonical, encoding: .utf8)
        else {
            return argsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return str
    }

    /// Pull the path argument a tool acted on (`path`, then `file_path`).
    private func pathArgument(_ argsJSON: String) -> String? {
        guard let data = argsJSON.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let p = dict["path"] as? String, !p.isEmpty { return p }
        if let p = dict["file_path"] as? String, !p.isEmpty { return p }
        return nil
    }

    private func parseListing(_ envelope: String) -> ListingSnapshot? {
        guard let payload = ToolEnvelope.successPayload(envelope) as? [String: Any],
            payload["kind"] as? String == "listing"
        else { return nil }
        let path = payload["path"] as? String ?? "."
        let rawEntries = payload["entries"] as? [[String: Any]] ?? []
        let entries: [ListingEntry] = rawEntries.compactMap { entry in
            guard let entryPath = entry["path"] as? String else { return nil }
            let name = entry["name"] as? String ?? (entryPath as NSString).lastPathComponent
            return ListingEntry(
                name: name,
                path: entryPath,
                isDirectory: (entry["type"] as? String) == "directory"
            )
        }
        return ListingSnapshot(
            path: path,
            entries: entries,
            truncated: payload["truncated"] as? Bool == true
        )
    }
}
