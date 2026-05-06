//
//  OsaurusEvalsCLI.swift
//  osaurus-evals
//
//  Tiny CLI over `OsaurusEvalsKit`. Deliberately no
//  swift-argument-parser dependency — the surface is small enough that
//  manual parsing is clearer than wiring a fourth-party dep just for
//  three flags. Add a real arg parser if/when a subcommand surface
//  appears (`run`, `diff`, `score`, ...).
//
//  Usage:
//    osaurus-evals run --suite Suites/Preflight [--model foundation] [--filter browser] [--out report.json]
//
//  Exit codes:
//    0  every non-skipped case passed (or no cases ran)
//    1  at least one case failed or errored
//    2  invalid arguments / suite path
//

import Foundation
import OsaurusCore
import OsaurusEvalsKit

@main
struct OsaurusEvalsCLI {

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first, first == "run" else {
            printUsage()
            exit(args.isEmpty ? 0 : 2)
        }

        let opts: Options
        do {
            opts = try Options.parse(Array(args.dropFirst()))
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printUsage()
            exit(2)
        }

        let suite: EvalSuite
        do {
            suite = try EvalSuite.load(from: opts.suite)
        } catch {
            FileHandle.standardError.write(
                Data(("failed to load suite: \(error.localizedDescription)\n").utf8)
            )
            exit(2)
        }

        let report = await EvalRunner.run(
            suite: suite,
            model: opts.model,
            filter: opts.filter,
            thresholdOverride: opts.threshold
        )

        print(report.formatHumanReadable(verbose: opts.verbose))

        if opts.reportForensics {
            print("\n" + Self.formatForensicsBlock(report, suite: suite))
        }

        if let outPath = opts.out {
            do {
                let data = try report.toJSON(prettyPrinted: true)
                let url = URL(fileURLWithPath: outPath)
                try data.write(to: url)
                print("\nwrote \(report.cases.count) cases to \(url.path)")
            } catch {
                FileHandle.standardError.write(
                    Data(("failed to write report: \(error.localizedDescription)\n").utf8)
                )
                // Don't fail the run for an output write hiccup — the
                // human-readable report already printed and is the
                // primary deliverable.
            }
        }

        let counts = report.counts
        var exitCode: Int32 = (counts.failed + counts.errored == 0) ? 0 : 1

        // Optional opt-in stricter gate. Walks every case listed in
        // `recall_floors.json`, recomputes the matched-name count
        // against the case's fixture expectations, and trips a breach
        // when matched < `minMatches`. Skipped cases (missing local
        // plugin) are excluded — they're already a "didn't apply"
        // signal, not a regression. CI wiring is deferred to the
        // post-fix PR; today this exists so contributors can dry-run
        // the gate locally before it becomes authoritative.
        if opts.failOnFloor {
            let floorsURL =
                opts.floorsPath.map { URL(fileURLWithPath: $0) }
                ?? Self.defaultFloorsURL()
            do {
                let floors = try Self.loadFloors(from: floorsURL)
                let breaches = Self.computeFloorBreaches(
                    report: report,
                    suite: suite,
                    floors: floors
                )
                if !breaches.isEmpty {
                    print("\n[floor breaches]")
                    for line in breaches { print("  - \(line)") }
                    exitCode = 1
                } else {
                    print("\n[floors] all listed cases met minMatches")
                }
            } catch {
                FileHandle.standardError.write(
                    Data(("failed to load floors at \(floorsURL.path): \(error.localizedDescription)\n").utf8)
                )
                exitCode = 2
            }
        }

        exit(exitCode)
    }

    // MARK: - Floors

    /// Default path used when `--fail-on-floor` is set without
    /// `--floors`. Resolved relative to the current working directory
    /// so the CLI can be invoked from anywhere in the repo as long as
    /// the user passes an absolute or repo-relative path explicitly;
    /// otherwise we assume the conventional checkout layout.
    static func defaultFloorsURL() -> URL {
        URL(fileURLWithPath: "Packages/OsaurusEvals/Config/recall_floors.json")
    }

    /// Decode `recall_floors.json` into a domain → caseId → minMatches
    /// map. Hand-rolled JSON walk so the `_comment` top-level key (and
    /// any future doc/metadata keys) is silently skipped without a
    /// custom `Decodable`.
    static func loadFloors(from url: URL) throws -> [String: [String: Int]] {
        let data = try Data(contentsOf: url)
        let any = try JSONSerialization.jsonObject(with: data)
        guard let root = any as? [String: Any] else {
            throw CLIError.invalidValue("--floors", "root is not an object")
        }
        var result: [String: [String: Int]] = [:]
        for (domain, value) in root {
            if domain.hasPrefix("_") { continue }
            guard let cases = value as? [String: Any] else { continue }
            var inner: [String: Int] = [:]
            for (caseId, raw) in cases {
                guard let entry = raw as? [String: Any] else { continue }
                if let mm = entry["minMatches"] as? Int {
                    inner[caseId] = mm
                }
            }
            result[domain] = inner
        }
        return result
    }

    /// Walk every (domain, caseId, minMatches) tuple in `floors` and
    /// produce a one-line breach for each case whose matched-name
    /// count is below the floor. `skipped` outcomes never breach
    /// (different host, different installed plugins). Unknown case
    /// IDs are surfaced as breaches so a typo in the floor file
    /// can't silently disable the gate.
    static func computeFloorBreaches(
        report: EvalReport,
        suite: EvalSuite,
        floors: [String: [String: Int]]
    ) -> [String] {
        var breaches: [String] = []
        let casesById = Dictionary(
            uniqueKeysWithValues: suite.cases.map { ($0.id, $0) }
        )
        let rowsById = Dictionary(
            uniqueKeysWithValues: report.cases.map { ($0.id, $0) }
        )
        for (domain, floorByCaseId) in floors {
            for (caseId, minMatches) in floorByCaseId {
                guard let caseDef = casesById[caseId] else {
                    breaches.append("\(caseId): not found in suite")
                    continue
                }
                guard let row = rowsById[caseId] else {
                    breaches.append("\(caseId): not present in report")
                    continue
                }
                if row.outcome == .skipped { continue }

                let matched: Int
                switch domain {
                case "capability_search":
                    guard let cs = row.capabilitySearch else {
                        breaches.append("\(caseId): no capability_search snapshot")
                        continue
                    }
                    let expected = caseDef.expect.capabilitySearch?.expectedTools?.anyOf ?? []
                    let accepted = Set(cs.toolHits.filter(\.acceptedByThreshold).map(\.name))
                    matched = expected.filter { accepted.contains($0) }.count
                case "preflight":
                    guard let observed = row.observed else {
                        breaches.append("\(caseId): no preflight snapshot")
                        continue
                    }
                    let expected = caseDef.expect.tools?.mustInclude ?? []
                    let picked = Set(observed.pickedToolNames)
                    matched = expected.filter { picked.contains($0) }.count
                default:
                    continue
                }
                if matched < minMatches {
                    breaches.append(
                        "\(caseId): matched \(matched), required \(minMatches)"
                    )
                }
            }
        }
        return breaches.sorted()
    }

    // MARK: - Forensics

    /// Per-case `(rawHits, acceptedHits, topFusedScore)` breakdown for
    /// `capability_search` cases, with an H1/H2/H3/H4/H5 hypothesis
    /// label applied. Drives off `EvalCaseReport.capabilitySearch` (the
    /// hybrid diagnostic) and the case fixture's expected names from
    /// `suite` (re-looked-up the same way `--fail-on-floor` does it).
    ///
    /// Label rules (first match wins, after the `passed` / `skipped`
    /// short-circuits):
    ///   - rawCount = 0                                                    → H2 (index gap)
    ///   - rawCount > 0, top fusedScore < 0.10                             → H3 (embedder)
    ///   - any expected name in accepted has `bm25Score != nil, embed nil` → H4 (lexical-only)
    ///   - any expected name in accepted has `embedScore != nil, bm25 nil` → H5 (semantic-only)
    ///   - rawCount > 0, acceptedCount = 0                                 → H1 (threshold)
    ///   - rawCount > 0, acceptedCount > 0, case still failed              → H3 (recall: expected names absent from accepted)
    ///   - otherwise                                                       → ok
    /// Non-`capability_search` rows are skipped.
    static func formatForensicsBlock(_ report: EvalReport, suite: EvalSuite) -> String {
        let casesById = Dictionary(uniqueKeysWithValues: suite.cases.map { ($0.id, $0) })
        let rows = report.cases.compactMap { row -> String? in
            guard row.domain == "capability_search",
                let cs = row.capabilitySearch
            else { return nil }
            let raw = cs.toolHits.count + cs.methodHits.count + cs.skillHits.count
            let accepted =
                cs.toolHits.filter(\.acceptedByThreshold).count
                + cs.methodHits.filter(\.acceptedByThreshold).count
                + cs.skillHits.filter(\.acceptedByThreshold).count
            let topFused =
                (cs.toolHits + cs.methodHits + cs.skillHits)
                .map(\.fusedScore)
                .max()
            let topFusedString = topFused.map { String(format: "%.3f", $0) } ?? "n/a"

            // Expected names for the H4/H5 nullability check. Pulled
            // from the case fixture's `expectedTools.anyOf` (the
            // tools-lane assertion); methods/skills `expected*` could
            // be added similarly when those lanes go hybrid.
            let expectedToolNames = Set(
                casesById[row.id]?
                    .expect.capabilitySearch?
                    .expectedTools?.anyOf ?? []
            )
            let label = forensicsLabel(
                rawCount: raw,
                acceptedCount: accepted,
                topFusedScore: topFused,
                outcome: row.outcome,
                toolHits: cs.toolHits,
                expectedToolNames: expectedToolNames
            )
            // All-Swift formatting. We previously used `String(format:)`
            // with `%-50s` / `%-7s`, but `%s` expects a C string —
            // passing a Swift `String` via `CVarArg` crashes inside
            // `_platform_strlen`. Plain `padding(toLength:)` keeps the
            // column alignment without the CVarArg hazard.
            return Self.forensicsLine(
                id: row.id,
                rawCount: raw,
                acceptedCount: accepted,
                topFusedString: topFusedString,
                label: label
            )
        }
        if rows.isEmpty {
            return "[forensics] no capability_search cases in report"
        }
        return (["[forensics]"] + rows).joined(separator: "\n")
    }

    /// Pure Swift, CVarArg-free row formatter for the forensics block.
    /// Right-pads each column with spaces so the table stays readable
    /// across cases with different id / score lengths. `padding(...)`
    /// is no-op when the string is already at-or-over the target width
    /// — long ids extend the column rather than truncating, which is
    /// the right tradeoff for a copy-paste-into-PR-description block.
    static func forensicsLine(
        id: String,
        rawCount: Int,
        acceptedCount: Int,
        topFusedString: String,
        label: String
    ) -> String {
        let idCol = id.padding(toLength: max(50, id.count), withPad: " ", startingAt: 0)
        let rawCol = String(rawCount).padding(toLength: 3, withPad: " ", startingAt: 0)
        let acceptedCol = String(acceptedCount).padding(toLength: 3, withPad: " ", startingAt: 0)
        let topCol = topFusedString.padding(toLength: max(7, topFusedString.count), withPad: " ", startingAt: 0)
        return "case=\(idCol) rawHits=\(rawCol) acceptedHits=\(acceptedCol) topFused=\(topCol) → \(label)"
    }

    private static func forensicsLabel(
        rawCount: Int,
        acceptedCount: Int,
        topFusedScore: Float?,
        outcome: EvalCaseOutcome,
        toolHits: [CapabilitySearchEvaluation.Hit],
        expectedToolNames: Set<String>
    ) -> String {
        // For passing cases, all the failure-mode labels are
        // misleading. An abstain-style case PASSES with rawCount=10,
        // acceptedCount=0 — labeling that as "H1 (threshold)" reads
        // as a regression when it's the desired behaviour. Skip the
        // hypothesis annotation and just report `passed`.
        if outcome == .passed { return "passed" }
        if outcome == .skipped { return "skipped" }
        if rawCount == 0 { return "H2 (index gap)" }
        if let top = topFusedScore, top < 0.10 { return "H3 (embedder)" }

        // H4 / H5: only meaningful when the case has expected tool
        // names AND at least one expected name is in the accepted set.
        // We classify by which source carried the hit: if BM25 alone
        // produced it (embedScore nil), the embedder couldn't have
        // — that's H4 (lexical-only) and tells us BM25 alone could
        // satisfy this query. If embed alone produced it, BM25 missed
        // — that's H5 (semantic-only) and tells us BM25 alone is
        // insufficient. Both labels classify the *failure* (the case
        // didn't reach minMatches) by attributing each surfaced
        // expected hit to its source — a partial-credit signal even
        // when overall recall is below the floor.
        if !expectedToolNames.isEmpty {
            let acceptedExpected = toolHits.filter {
                $0.acceptedByThreshold && expectedToolNames.contains($0.name)
            }
            if !acceptedExpected.isEmpty {
                let lexicalOnly = acceptedExpected.contains { $0.bm25Score != nil && $0.embedScore == nil }
                let semanticOnly = acceptedExpected.contains { $0.bm25Score == nil && $0.embedScore != nil }
                if lexicalOnly && !semanticOnly { return "H4 (lexical-only)" }
                if semanticOnly && !lexicalOnly { return "H5 (semantic-only)" }
                if lexicalOnly && semanticOnly { return "H4+H5 (mixed-source)" }
            }
        }

        if acceptedCount == 0 { return "H1 (threshold)" }
        // raw>0 AND accepted>0 AND case still failed → the search
        // surfaced something but not the EXPECTED tools (e.g. the
        // shell-execution case where sandbox_exec is excluded from
        // the index entirely). The threshold can't help here, so
        // flag as the recall failure mode it actually is.
        return "H3 (recall: expected names absent from accepted)"
    }

    // MARK: - Args

    struct Options {
        let suite: URL
        let model: ModelSelection
        let filter: String?
        let out: String?
        let verbose: Bool
        /// Capability-search threshold sweep value. Forwarded to
        /// `EvalRunner.run(thresholdOverride:)`; no-op for other
        /// domains. `nil` keeps the production
        /// `CapabilitySearch.minimumRelevanceScore`.
        let threshold: Float?
        /// Print the per-case `(rawHits, acceptedHits, topRawScore)`
        /// H1/H2/H3 forensics block after the human-readable report.
        /// Designed for copy-paste into PR descriptions during the
        /// Phase 3 threshold sweep.
        let reportForensics: Bool
        /// Path to the recall-floors JSON config. `nil` falls back to
        /// the conventional repo location when `--fail-on-floor` is
        /// set.
        let floorsPath: String?
        /// Opt-in stricter gate. When set, the CLI also exits 1 on
        /// any case listed in the floors file whose matched count is
        /// below the configured `minMatches`. Off by default — the
        /// Phase 5 wiring is scaffolding, not an active CI gate.
        let failOnFloor: Bool

        static func parse(_ args: [String]) throws -> Options {
            var suite: URL?
            var modelRaw: String?
            var filter: String?
            var out: String?
            var verbose = false
            var threshold: Float?
            var reportForensics = false
            var floorsPath: String?
            var failOnFloor = false

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--suite":
                    suite = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--model":
                    modelRaw = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--filter":
                    filter = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--out":
                    out = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--verbose", "-v":
                    verbose = true
                    i += 1
                case "--threshold":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Float(raw) else { throw CLIError.invalidValue(arg, raw) }
                    threshold = value
                    i += 2
                case "--report-forensics":
                    reportForensics = true
                    i += 1
                case "--floors":
                    floorsPath = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--fail-on-floor":
                    failOnFloor = true
                    i += 1
                case "--help", "-h":
                    printUsage()
                    exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            guard let suite else { throw CLIError.missingFlag("--suite") }
            return Options(
                suite: suite,
                model: ModelSelection.parse(modelRaw),
                filter: filter,
                out: out,
                verbose: verbose,
                threshold: threshold,
                reportForensics: reportForensics,
                floorsPath: floorsPath,
                failOnFloor: failOnFloor
            )
        }
    }

    static func valueForArg(_ args: [String], after index: Int, flag: String) throws -> String {
        guard index + 1 < args.count else { throw CLIError.missingValue(flag) }
        return args[index + 1]
    }

    static func urlForArg(_ args: [String], after index: Int, flag: String) throws -> URL {
        let raw = try valueForArg(args, after: index, flag: flag)
        return URL(fileURLWithPath: raw)
    }

    static func printUsage() {
        let usage = """
            osaurus-evals — run behaviour evals against a chosen model

            USAGE:
                osaurus-evals run --suite <dir> [--model <id>] [--filter <substr>] [--out <path>]
                                              [--threshold <float>] [--report-forensics]

            FLAGS:
                --suite <dir>         Required. Directory of *.json eval cases
                                      (e.g. Suites/Preflight, Suites/CapabilitySearch).
                --model <id>          Model to route through CoreModelService for
                                      this run. Forms:
                                        auto                — keep current config
                                        foundation          — Apple Foundation Models
                                        openai/gpt-4o-mini  — provider/name pair
                                        qwen3-4b            — bare local id
                                      Default: auto.
                --filter <substr>     Only run cases whose id contains <substr>.
                --out <path>          Also write a JSON report to <path>.
                --verbose, -v         Print per-case diagnostics: the user query,
                                      the raw LLM response (truncated), and the
                                      pre-guardrail picks. Use when iterating on
                                      the preflight prompt.
                --threshold <float>   Override the **tools-lane** RRF cutoff
                                      (`minFusedScore`) for this run. The
                                      methods + skills lanes always use the
                                      production embed-cosine default
                                      (`CapabilitySearch.minimumRelevanceScore`)
                                      regardless of this flag — fused-score
                                      and cosine values live on different
                                      scales (RRF max ≈ 0.033 vs cosine 0–1),
                                      so a single knob can't drive both
                                      meaningfully. Use this to sweep RRF
                                      cutoffs (e.g. --threshold 0.020) without
                                      rebuilding. No-op for non-capability_search
                                      domains.
                --report-forensics    Print a per-case `(rawHits, acceptedHits,
                                      topFused)` block tagged with a
                                      H1/H2/H3/H4/H5 hypothesis label. H4 =
                                      lexical-only (BM25 surfaced an expected
                                      tool, embed missed). H5 = semantic-only
                                      (embed surfaced it, BM25 missed). Tells
                                      you which source could be dropped.
                                      Capability-search rows only. Designed
                                      for copy-paste into the PR description
                                      during a sweep.
                --floors <path>       Path to recall_floors.json. Defaults to
                                      `Packages/OsaurusEvals/Config/recall_floors.json`
                                      when --fail-on-floor is set without
                                      --floors. No effect on its own.
                --fail-on-floor       Opt-in stricter gate: also exit 1 on
                                      any case in the floors file whose matched
                                      count is below `minMatches`. Off by
                                      default; CI wiring is deferred to the
                                      post-fix PR.

            EXAMPLES:
                osaurus-evals run --suite Suites/Preflight --model foundation
                osaurus-evals run --suite Suites/Preflight --filter browser --out report.json
                osaurus-evals run --suite Suites/CapabilitySearch --threshold 0.25 --report-forensics
                osaurus-evals run --suite Suites/CapabilitySearch --fail-on-floor
            """
        print(usage)
    }
}

enum CLIError: Error, LocalizedError {
    case unknownArg(String)
    case missingFlag(String)
    case missingValue(String)
    case invalidValue(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownArg(let a): return "unknown argument: \(a)"
        case .missingFlag(let f): return "missing required flag: \(f)"
        case .missingValue(let f): return "flag \(f) requires a value"
        case .invalidValue(let f, let v): return "flag \(f) got invalid value: \(v)"
        }
    }
}
