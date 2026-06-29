//
//  AgentTaskStateTests.swift
//  osaurusTests
//
//  Unit + simulation tests for the harness task-state machine. Covers the
//  result classifier (listing/file/not-found branches), the dedupe +
//  write-invalidation logic (with shared path canonicalization), verbatim
//  per-signature replay, the data-driven reactive next-step nudge (fires only
//  after the model is observed wandering), the bias-disabled validation gate,
//  and an end-to-end "list -> read" transcript simulation with fixed
//  turn-count criteria.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentTaskStateTests {

    // MARK: - Helpers

    private func fileContentEnvelope(path: String, text: String = "hello") -> String {
        ToolEnvelope.success(
            tool: "file_read",
            result: ["kind": "file", "text": text, "path": path]
        )
    }

    private func listingEnvelope(
        path: String,
        entries: [(name: String, path: String, dir: Bool)],
        truncated: Bool = false
    ) -> String {
        ToolEnvelope.listing(
            tool: "file_read",
            path: path,
            entries: entries.map {
                ["name": $0.name, "path": $0.path, "type": $0.dir ? "directory" : "file"]
            },
            truncated: truncated
        )
    }

    // MARK: - Classification

    @Test func classify_populatedListing() {
        let env = listingEnvelope(
            path: ".",
            entries: [("a.txt", "a.txt", false), ("sub", "sub", true)]
        )
        #expect(AgentTaskState.classify(env) == .populatedListing)
    }

    @Test func classify_emptyListing() {
        let env = listingEnvelope(path: "empty", entries: [])
        #expect(AgentTaskState.classify(env) == .emptyListing)
    }

    @Test func classify_partialListing() {
        let env = listingEnvelope(
            path: "big",
            entries: [("a.txt", "big/a.txt", false)],
            truncated: true
        )
        #expect(AgentTaskState.classify(env) == .partialListing)
    }

    @Test func classify_fileContent() {
        #expect(AgentTaskState.classify(fileContentEnvelope(path: "a.txt")) == .fileContent)
    }

    @Test func classify_notFound() {
        let env = ToolEnvelope.failure(kind: .notFound, message: "File not found: x", tool: "file_read")
        #expect(AgentTaskState.classify(env) == .notFound)
    }

    @Test func classify_genericError() {
        let env = ToolEnvelope.failure(kind: .executionError, message: "boom", tool: "file_read")
        #expect(AgentTaskState.classify(env) == .error)
    }

    @Test func classify_otherSuccess() {
        // A plain text success (no `kind`) is neither listing nor file.
        let env = ToolEnvelope.success(tool: "file_search", text: "Found 2 matches")
        #expect(AgentTaskState.classify(env) == .other)
    }

    /// The `kind:"search"` shape must classify as benign `.other`, NOT be
    /// misread as a listing. Recording one must leave both the wandering
    /// counter and the retained `lastListing` snapshot untouched — a future
    /// edit that makes search results count as listings would corrupt Fix 1's
    /// truncated-listing steer, so pin the behaviour here.
    @Test func classify_searchResultIsBenignOther() {
        let searchEnv = ToolEnvelope.search(
            tool: "file_search",
            query: "q4",
            entries: [["name": "q4.xlsx", "path": "q4.xlsx", "type": "file"]],
            truncated: false
        )
        #expect(AgentTaskState.classify(searchEnv) == .other)

        let state = AgentTaskState()
        // Seed a truncated listing so we can prove recording a search doesn't
        // overwrite it (the not_found steer reads this snapshot).
        let truncatedListing = listingEnvelope(
            path: "big",
            entries: [("a.txt", "big/a.txt", false)],
            truncated: true
        )
        state.record(name: "file_read", argsJSON: #"{"path":"big"}"#, result: truncatedListing)
        let snapshotBefore = state.lastListing
        #expect(snapshotBefore?.truncated == true)

        state.record(name: "file_search", argsJSON: #"{"pattern":"q4","target":"files"}"#, result: searchEnv)

        // Counter unchanged (search is not a listing), snapshot unchanged.
        #expect(state.lastListing == snapshotBefore, "a search result must not overwrite lastListing")
        // The retained truncated listing still drives the not_found steer.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"big/missing.txt"}"#,
            result: ToolEnvelope.failure(kind: .notFound, message: "not found", tool: "file_read")
        )
        #expect(state.nextStepBias()?.contains("file_search") == true)
    }

    // MARK: - Path canonicalization (shared)

    @Test func canonicalPath_normalizesSpellings() {
        #expect(AgentTaskState.canonicalPath("config.json") == AgentTaskState.canonicalPath("./config.json"))
        #expect(AgentTaskState.canonicalPath("a/b/") == AgentTaskState.canonicalPath("a/b"))
        #expect(AgentTaskState.canonicalPath("a//b") == AgentTaskState.canonicalPath("a/b"))
    }

    // MARK: - Dedupe

    @Test func dedupe_repeatedReadIsHeld() {
        let state = AgentTaskState()
        let env = fileContentEnvelope(path: "config.json")
        state.record(name: "file_read", argsJSON: #"{"path":"config.json"}"#, result: env)
        // The identical re-issue replays the EXACT prior envelope.
        #expect(state.heldResult(name: "file_read", argsJSON: #"{"path":"config.json"}"#) == env)
    }

    @Test func dedupe_argOrderInsensitive() {
        let state = AgentTaskState()
        let env = fileContentEnvelope(path: "a.txt")
        state.record(name: "file_read", argsJSON: #"{"path":"a.txt","start_line":1}"#, result: env)
        // Same args, different key order — still a duplicate.
        #expect(state.isDuplicate(name: "file_read", argsJSON: #"{"start_line":1,"path":"a.txt"}"#))
    }

    @Test func dedupe_differentPathNotHeld() {
        let state = AgentTaskState()
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"a.txt"}"#,
            result: fileContentEnvelope(path: "a.txt")
        )
        #expect(state.heldResult(name: "file_read", argsJSON: #"{"path":"b.txt"}"#) == nil)
    }

    @Test func dedupe_writesAreNeverHeld() {
        let state = AgentTaskState()
        state.record(
            name: "file_write",
            argsJSON: #"{"path":"a.txt","content":"x"}"#,
            result: ToolEnvelope.success(tool: "file_write", text: "ok")
        )
        // A repeated write must always run.
        #expect(state.heldResult(name: "file_write", argsJSON: #"{"path":"a.txt","content":"x"}"#) == nil)
    }

    /// The read -> edit -> read-to-verify pattern: the write to the path
    /// invalidates the fresh read so the verify-read re-executes instead of
    /// being short-circuited with stale pre-edit content. Uses TWO spellings
    /// of the same path to prove the shared canonicalization matches.
    @Test func dedupe_writeInvalidatesReadAcrossSpellings() {
        let state = AgentTaskState()
        // 1) read "config.json" — now fresh and would be deduped.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"config.json"}"#,
            result: fileContentEnvelope(path: "config.json", text: "before")
        )
        #expect(state.isDuplicate(name: "file_read", argsJSON: #"{"path":"config.json"}"#))

        // 2) edit "./config.json" — a DIFFERENT spelling of the same path.
        state.record(
            name: "file_edit",
            argsJSON: #"{"path":"./config.json"}"#,
            result: ToolEnvelope.success(tool: "file_edit", text: "edited")
        )

        // 3) the verify-read of "config.json" must NOT be held — it must
        //    re-execute so the model sees post-edit content.
        #expect(
            state.heldResult(name: "file_read", argsJSON: #"{"path":"config.json"}"#) == nil,
            "a write to ./config.json must invalidate the read of config.json (shared canonicalization)"
        )
    }

    @Test func replay_isVerbatimNotCollapsed() {
        let state = AgentTaskState()
        // A long listing whose ContextBudget summary would be much shorter.
        let entries = (0 ..< 40).map { (name: "f\($0).txt", path: "f\($0).txt", dir: false) }
        let env = listingEnvelope(path: ".", entries: entries)
        state.record(name: "file_read", argsJSON: #"{"path":"."}"#, result: env)
        let held = state.heldResult(name: "file_read", argsJSON: #"{"path":"."}"#)
        #expect(held == env, "the replay must be the exact prior envelope, not a collapsed form")
    }

    /// `capabilities_load` is a path-less deterministic-error tool: a failing
    /// `invalid_args` load is held and replayed (with an escalation notice)
    /// instead of re-executing, so a model can't burn iterations re-issuing
    /// the same bad capability id.
    @Test func dedupe_capabilitiesLoadInvalidArgsIsHeld() {
        let state = AgentTaskState()
        let args = #"{"ids":["plugin/Scite.AI"]}"#
        let err = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown type 'plugin'",
            tool: "capabilities_load",
            retryable: false
        )
        state.record(name: "capabilities_load", argsJSON: args, result: err)
        #expect(state.heldResult(name: "capabilities_load", argsJSON: args) == err)
        #expect(state.lastReplayNotice?.contains("capabilities_load") == true)
        // A different id set is a different call — not held.
        #expect(state.heldResult(name: "capabilities_load", argsJSON: #"{"ids":["skill/other"]}"#) == nil)
    }

    // MARK: - Next-step nudge

    /// Reactive: a single listing does NOT nudge (a capable model that
    /// descends immediately is never told what it already inferred). A second
    /// listing without an intervening read DOES nudge.
    @Test func bias_populatedListingPointsAtEntries() {
        let state = AgentTaskState()
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"."}"#,
            result: listingEnvelope(path: ".", entries: [("a.txt", "a.txt", false)])
        )
        #expect(state.nextStepBias() == nil, "one listing is not wandering — no nudge")

        state.record(
            name: "file_read",
            argsJSON: #"{"path":"other"}"#,
            result: listingEnvelope(path: "other", entries: [("b.txt", "other/b.txt", false)])
        )
        let bias = try? #require(state.nextStepBias())
        #expect(bias?.contains("result.entries") == true)
    }

    @Test func bias_emptyListingDoesNotTellModelToPick() {
        let state = AgentTaskState()
        // Two empty listings without a read to reach the reactive threshold.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"empty"}"#,
            result: listingEnvelope(path: "empty", entries: [])
        )
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"empty2"}"#,
            result: listingEnvelope(path: "empty2", entries: [])
        )
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains("empty"))
        // Must not instruct the model to pick/copy an entry that isn't there.
        #expect(!bias.contains("result.entries"))
    }

    @Test func bias_partialListingPointsAtSearch() {
        let state = AgentTaskState()
        // Two truncated listings without a read to reach the reactive threshold.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"big"}"#,
            result: listingEnvelope(
                path: "big",
                entries: [("a.txt", "big/a.txt", false)],
                truncated: true
            )
        )
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"big2"}"#,
            result: listingEnvelope(
                path: "big2",
                entries: [("b.txt", "big2/b.txt", false)],
                truncated: true
            )
        )
        #expect(state.nextStepBias()?.contains("file_search") == true)
    }

    @Test func bias_fileContentHasNoNudge() {
        let state = AgentTaskState()
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"a.txt"}"#,
            result: fileContentEnvelope(path: "a.txt")
        )
        #expect(state.nextStepBias() == nil)
    }

    /// While the model stays stuck (keeps listing without reading), the nudge
    /// keeps firing — it does NOT go silent right when a stuck model needs it
    /// most. Each distinct listing past the threshold still nudges.
    @Test func bias_listingNudgeKeepsFiringWhileStuck() {
        let state = AgentTaskState()
        // First listing: below threshold, no nudge.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"d0"}"#,
            result: listingEnvelope(path: "d0", entries: [("a.txt", "d0/a.txt", false)])
        )
        #expect(state.nextStepBias() == nil)
        // Listings 2..5 without a read: nudge fires every time.
        for i in 1 ..< 5 {
            state.record(
                name: "file_read",
                argsJSON: "{\"path\":\"d\(i)\"}",
                result: listingEnvelope(path: "d\(i)", entries: [("a.txt", "d\(i)/a.txt", false)])
            )
            #expect(
                state.nextStepBias()?.contains("result.entries") == true,
                "the nudge must keep firing while the model stays stuck (iteration \(i))"
            )
        }
    }

    @Test func bias_resetsAfterAFileRead() {
        let state = AgentTaskState()
        let listing = listingEnvelope(path: ".", entries: [("a.txt", "a.txt", false)])
        // Two listings without a read -> wandering -> nudge.
        state.record(name: "file_read", argsJSON: #"{"path":"."}"#, result: listing)
        state.record(name: "file_read", argsJSON: #"{"path":"x"}"#, result: listing)
        #expect(state.nextStepBias()?.contains("result.entries") == true)
        // A successful file read is progress and resets the counter.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"a.txt"}"#,
            result: fileContentEnvelope(path: "a.txt")
        )
        // A single fresh listing after the reset is below threshold again.
        state.record(name: "file_read", argsJSON: #"{"path":"y"}"#, result: listing)
        #expect(state.nextStepBias() == nil, "counter reset by the read -> one listing is not wandering")
        // A second listing without a read fires again.
        state.record(name: "file_read", argsJSON: #"{"path":"z"}"#, result: listing)
        #expect(state.nextStepBias()?.contains("result.entries") == true)
    }

    /// Capable-model path (bias ON): list once, then descend into a file. The
    /// nudge never fires — no backseat-driving for a model that does the right
    /// thing on its own.
    @Test func bias_firstListingThenReadNeverNudges() {
        let state = AgentTaskState()
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"Desktop"}"#,
            result: listingEnvelope(path: "Desktop", entries: [("a.txt", "Desktop/a.txt", false)])
        )
        #expect(state.nextStepBias() == nil)
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"Desktop/a.txt"}"#,
            result: fileContentEnvelope(path: "Desktop/a.txt")
        )
        #expect(state.nextStepBias() == nil)
    }

    /// The wandering counter and the per-`not_found` nudge compose: a failed
    /// read is not progress, so it neither resets nor masks wandering. A
    /// listing -> failed read -> listing sequence still reaches the listing
    /// nudge, and the not-found in the middle fires its own nudge.
    @Test func bias_interleavedListingAndNotFoundStillReachesNudge() {
        let state = AgentTaskState()
        // list A — below threshold.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"A"}"#,
            result: listingEnvelope(path: "A", entries: [("a.txt", "A/a.txt", false)])
        )
        #expect(state.nextStepBias() == nil)
        // failed read — fires the not-found nudge, must NOT reset the counter.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"/nope"}"#,
            result: ToolEnvelope.failure(kind: .notFound, message: "File not found: /nope", tool: "file_read")
        )
        #expect(state.nextStepBias()?.contains("not found") == true)
        // list B — second listing without a successful read -> listing nudge.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"B"}"#,
            result: listingEnvelope(path: "B", entries: [("b.txt", "B/b.txt", false)])
        )
        #expect(
            state.nextStepBias()?.contains("result.entries") == true,
            "a not_found must not mask wandering — the second listing still reaches the nudge"
        )
    }

    /// A truncated listing followed by a failed read must NOT steer the model
    /// back into the partial set (that's how a present file gets reported
    /// absent). The not_found nudge points at `file_search` instead.
    @Test func bias_notFoundAfterTruncatedListingPointsAtSearch() {
        let state = AgentTaskState()
        // A single truncated listing (below the listing reactive threshold, so
        // no listing nudge fires on its own).
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"big"}"#,
            result: listingEnvelope(
                path: "big",
                entries: [("a.txt", "big/a.txt", false)],
                truncated: true
            )
        )
        // The model guesses a path and misses.
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"big/missing.txt"}"#,
            result: ToolEnvelope.failure(
                kind: .notFound,
                message: "File not found: big/missing.txt",
                tool: "file_read"
            )
        )
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains("file_search"), "truncated listing -> not_found must steer to file_search")
        #expect(!bias.contains("most recent listing's entries"))
    }

    /// The result-level steer fires on the FIRST truncated listing (no
    /// reactive gating): the warning is attached to the envelope itself.
    @Test func truncatedListingEnvelopeCarriesSearchWarning() {
        func warnings(_ envelope: String) -> [String] {
            guard let data = envelope.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return dict["warnings"] as? [String] ?? []
        }
        let truncated = listingEnvelope(
            path: "big",
            entries: [("a.txt", "big/a.txt", false)],
            truncated: true
        )
        #expect(warnings(truncated).contains { $0.contains("file_search") && $0.contains("truncated") })
        // A non-truncated listing carries no auto-warning.
        let ok = listingEnvelope(path: "small", entries: [("a.txt", "small/a.txt", false)])
        #expect(warnings(ok).isEmpty)
    }

    // MARK: - Bias-disabled validation gate

    /// With the nudge disabled the state machine emits NO prose guidance —
    /// the structured `entries[]` must carry the descent on its own. This is
    /// the lever the transcript simulation pulls to prove the note is not
    /// load-bearing.
    @Test func gate_biasDisabledEmitsNoNudge() {
        let state = AgentTaskState(biasEnabled: false)
        state.record(
            name: "file_read",
            argsJSON: #"{"path":"."}"#,
            result: listingEnvelope(path: ".", entries: [("a.txt", "a.txt", false)])
        )
        #expect(state.nextStepBias() == nil)
    }

    // MARK: - Transcript simulation ("what's on my desktop" -> "read the file")

    /// Simulates the failing transcript at the harness level: a model driven
    /// purely by the structured results (bias OFF) descends from a listing
    /// into a file read within the fixed turn budget, with no duplicate
    /// executions and never reporting a listing as file content.
    ///
    /// Pass criterion (fixed in advance): the read happens within <= 2 tool
    /// iterations of the second message and <= 4 total; zero replays; the
    /// content the model "answers" from is classified as file content, not a
    /// listing.
    @Test func transcript_listThenRead_descendsWithoutBias() {
        let state = AgentTaskState(biasEnabled: false)
        var replays = 0

        // The "filesystem": Desktop has one file. A directory path lists; a
        // file path returns content.
        func execute(_ args: String) -> String {
            if args.contains("\"Desktop\"") {
                return listingEnvelope(
                    path: "Desktop",
                    entries: [("notes.txt", "Desktop/notes.txt", false)]
                )
            }
            return fileContentEnvelope(path: "Desktop/notes.txt", text: "yahoo news")
        }

        // A `file_read` turn driven only by copying fields (never prose): it
        // de-dupes via the harness, executes otherwise, and records.
        func read(_ args: String) -> String {
            if let held = state.heldResult(name: "file_read", argsJSON: args) {
                replays += 1
                return held
            }
            let result = execute(args)
            state.record(name: "file_read", argsJSON: args, result: result)
            return result
        }

        // --- Message 1: "what's on my desktop" -> one list call, then answer.
        state.beginMessage()
        let m1 = read(#"{"path":"Desktop"}"#)
        let msg1Iterations = 1
        #expect(AgentTaskState.classify(m1) == .populatedListing)

        // The harness retained the listing across the message boundary, so
        // message 2 can resolve "the file" against it (structure, not prose).
        let retained = try? #require(state.lastListing)
        #expect(retained?.entries.first?.path == "Desktop/notes.txt")

        // --- Message 2: "read the file" -> copy the one entry's path back.
        state.beginMessage()
        let target = state.lastListing?.entries.first?.path ?? "Desktop/notes.txt"
        let escaped = target.replacingOccurrences(of: "\"", with: "\\\"")
        let m2 = read("{\"path\":\"\(escaped)\"}")
        let msg2Iterations = 1

        // Fixed pass criteria (decided in advance).
        #expect(AgentTaskState.classify(m2) == .fileContent)
        #expect(AgentTaskState.classify(m2) != .populatedListing, "no listing-as-content")
        #expect(msg2Iterations <= 2, "read within 2 iterations of message 2")
        #expect(msg1Iterations + msg2Iterations <= 4, "<= 4 total tool iterations")
        #expect(replays == 0, "no duplicate executions")
    }

    // MARK: - Repeated write/exec call detector

    private func execFailureEnvelope(_ message: String = "command failed") -> String {
        ToolEnvelope.failure(kind: .executionError, message: message, tool: "sandbox_exec")
    }

    /// The 3rd identical non-read call arms the repeated-call nudge; the
    /// first two stay silent (a legitimate retry shouldn't be nagged).
    @Test func repeatedCall_thirdIdenticalExecArmsNudge() {
        let state = AgentTaskState()
        let args = #"{"command":"swift build"}"#

        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        #expect(state.nextStepBias() == nil, "first call: no nudge")

        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        #expect(state.nextStepBias() == nil, "second call: no nudge")

        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains("sandbox_exec"), "third call: nudge names the tool")
        #expect(bias.contains("change your approach"), "nudge asks for a different approach")
    }

    /// Argument canonicalization applies: key order must not defeat the
    /// detector.
    @Test func repeatedCall_keyOrderInsensitive() {
        let state = AgentTaskState()
        state.record(
            name: "file_write",
            argsJSON: #"{"path":"a.txt","content":"x"}"#,
            result: execFailureEnvelope()
        )
        state.record(
            name: "file_write",
            argsJSON: #"{"content":"x","path":"a.txt"}"#,
            result: execFailureEnvelope()
        )
        state.record(
            name: "file_write",
            argsJSON: #"{"path":"a.txt","content":"x"}"#,
            result: execFailureEnvelope()
        )
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains("file_write"))
    }

    /// A different call between repeats disarms the pending nudge — the
    /// notice describes the MOST RECENT call only.
    @Test func repeatedCall_differentCallDisarms() {
        let state = AgentTaskState()
        let args = #"{"command":"make test"}"#
        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        // Now a different command runs — the nudge must not fire for it.
        state.record(
            name: "sandbox_exec",
            argsJSON: #"{"command":"ls"}"#,
            result: ToolEnvelope.success(tool: "sandbox_exec", text: "ok")
        )
        #expect(state.nextStepBias() == nil)
    }

    /// Read tools never reach the counter — they are covered by the dedupe
    /// replay (`heldResult`) instead.
    @Test func repeatedCall_readToolsExcluded() {
        let state = AgentTaskState()
        // Failed reads re-execute (no fresh-read entry), so the same read can
        // genuinely repeat — and must not trip the write/exec detector.
        let notFound = ToolEnvelope.failure(kind: .notFound, message: "missing", tool: "file_read")
        let args = #"{"path":"ghost.txt"}"#
        state.record(name: "file_read", argsJSON: args, result: notFound)
        state.record(name: "file_read", argsJSON: args, result: notFound)
        state.record(name: "file_read", argsJSON: args, result: notFound)
        let bias = state.nextStepBias() ?? ""
        #expect(!bias.contains("identical arguments"), "read repeats use the not_found nudge, not the repeat detector")
    }

    /// `beginMessage` resets the counters: repeats across user messages are
    /// not loops.
    @Test func repeatedCall_beginMessageResets() {
        let state = AgentTaskState()
        let args = #"{"command":"git status"}"#
        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        state.beginMessage()
        state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        #expect(state.nextStepBias() == nil, "count restarts after beginMessage")
    }

    /// The detector keeps firing while the model stays stuck (4th, 5th, …
    /// identical calls) — no premature silence.
    @Test func repeatedCall_keepsFiringWhileStuck() {
        let state = AgentTaskState()
        let args = #"{"command":"swift build"}"#
        for _ in 0 ..< 5 {
            state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        }
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains("sandbox_exec"))
    }

    /// Advisory only: nothing in the state machine blocks the call — the
    /// envelope recorded is whatever the execution produced.
    @Test func repeatedCall_neverHardBlocks() {
        let state = AgentTaskState()
        let args = #"{"command":"swift build"}"#
        for _ in 0 ..< 4 {
            state.record(name: "sandbox_exec", argsJSON: args, result: execFailureEnvelope())
        }
        // The dedupe path still declines to short-circuit non-read tools.
        #expect(state.heldResult(name: "sandbox_exec", argsJSON: args) == nil)
    }

    // MARK: - Native image generation → follow-up edit bias (#88)

    @Test func nativeImageResultBiasesFollowUpEditToSavedPath() throws {
        let state = AgentTaskState()
        let envelope = ToolEnvelope.success(
            tool: "image",
            result: [
                "kind": "native_image_generation_job",
                "mode": "generate",
                "status": "completed",
                "images": [
                    [
                        "path": "/tmp/osaurus-images/generated-cube.png",
                        "url": "file:///tmp/osaurus-images/generated-cube.png",
                        "seed": 123,
                    ]
                ],
            ] as [String: Any]
        )

        state.record(name: "image", argsJSON: #"{"prompt":"make a red cube"}"#, result: envelope)

        let bias = try #require(state.nextStepBias())
        #expect(bias.contains("`image`"))
        #expect(bias.contains("/tmp/osaurus-images/generated-cube.png"))
        #expect(bias.contains("source_paths"))
    }

    @Test func nativeImageEditResultDoesNotBiasAnotherEdit() {
        let state = AgentTaskState()
        let envelope = ToolEnvelope.success(
            tool: "image",
            result: [
                "kind": "native_image_generation_job",
                "mode": "edit",
                "status": "completed",
                "images": [
                    [
                        "path": "/tmp/osaurus-images/edited-cube.png",
                        "url": "file:///tmp/osaurus-images/edited-cube.png",
                        "seed": 456,
                    ]
                ],
            ] as [String: Any]
        )

        state.record(
            name: "image",
            argsJSON: #"{"source_paths":["/tmp/osaurus-images/generated-cube.png"],"prompt":"make it green"}"#,
            result: envelope
        )

        #expect(state.nextStepBias() == nil)
    }

    @Test func nativeImageResultWithoutEditModelDoesNotBiasEdit() {
        // A fresh generation, but the payload reports no ready edit model
        // (`edit_available: false`). The post-generation edit nudge must stay
        // silent — steering toward `source_paths` would point the model at an
        // edit the runtime can't perform.
        let state = AgentTaskState()
        let envelope = ToolEnvelope.success(
            tool: "image",
            result: [
                "kind": "native_image_generation_job",
                "mode": "generate",
                "status": "completed",
                "edit_available": false,
                "images": [
                    [
                        "path": "/tmp/osaurus-images/generated-cube.png",
                        "url": "file:///tmp/osaurus-images/generated-cube.png",
                        "seed": 123,
                    ]
                ],
            ] as [String: Any]
        )

        state.record(name: "image", argsJSON: #"{"prompt":"make a red cube"}"#, result: envelope)

        #expect(state.nextStepBias() == nil)
    }
}
