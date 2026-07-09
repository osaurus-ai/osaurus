//
//  OsaurusEvalsCLI.swift
//  osaurus-evals
//
//  CLI over `OsaurusEvalsKit`. Deliberately no swift-argument-parser
//  dependency: the subcommands (`run`, `diff`, `matrix`, `compat`,
//  `scorecard`, `capture-screen`, `agent-loop-lab`) share one
//  hand-rolled flag walk, which keeps the eval binary dependency-free
//  and its parsing greppable next to the flags it documents.
//
//  Usage:
//    osaurus-evals run --suite Suites/CapabilitySearch [--model foundation] [--filter browser] [--out report.json]
//
//  Exit codes:
//    0  every non-skipped case passed (or no cases ran)
//    1  at least one case failed or errored
//    2  invalid arguments / suite path
//  124  startup bootstrap timed out
//

import Darwin
import Foundation
import OsaurusCore
import OsaurusEvalsKit

@main
struct OsaurusEvalsCLI {

    static func main() async {
        // Hermetic harness: the eval binary must never touch the user's login
        // Keychain. It is code-signed differently than the host app, so
        // DECRYPTING the app-created Master Key item routes through the legacy
        // file-based login Keychain and raises a "osaurus-evals wants to use
        // your confidential information" ACL authorization prompt that hangs a
        // headless run indefinitely (observed driving DefaultAgent: agent-create
        // → AgentManager.assignAddress → MasterKey.getPrivateKey, blocked in
        // SecItemCopyMatching → securityd with 0% CPU). `LAContext`/UI-skip flags
        // are ignored on legacy items, so the only correct fix is to run
        // Keychain-free: every wrapper (incl. MasterKey) then no-ops. This
        // mirrors the existing isolated config/search storage for default-agent
        // cases. Forced before any OsaurusCore access; the harness never needs
        // real Keychain (remote providers are ephemeral and env-keyed).
        setenv("OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS", "1", 1)

        // The sandbox secrets pipeline (sandbox_secret_set → exec env
        // injection → SecretScrubber redaction) is a scored surface
        // (SandboxFrontier secrets-roundtrip), but the Keychain-free gate
        // above turns every AgentSecretsKeychain call into a no-op — the
        // model stores a secret, gets `stored:true`… and `$KEY` is empty in
        // the VM. A process-lifetime in-memory store keeps the pipeline
        // real (same code path, same scrubbing) without touching the
        // login Keychain; per-case cleanup purges it.
        setenv("OSAURUS_AGENT_SECRETS_IN_MEMORY", "1", 1)

        // Eval isolation: to drive a remote model the harness connects an
        // in-memory provider (`EvalRemoteProviderBootstrap`), which lands in
        // `configuration.providers`. Without this, a `default_agent` honesty
        // case ("which providers are connected?") would read the harness's own
        // run/judge provider and score a truthful model as fabricating. This
        // flag tells the configure READ tools (`osaurus_status`/`osaurus_list`/
        // `osaurus_describe`) to hide ephemeral providers so the scenario sees
        // the genuine user state. Safe: the eval binary runs no Bonjour
        // discovery, so in-process the only ephemeral providers are the
        // harness's; routing is untouched, so the model still runs.
        setenv("OSAURUS_EVALS_HIDE_EPHEMERAL_PROVIDERS", "1", 1)

        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(0)
        }

        switch command {
        case "run":
            await runCommand(Array(args.dropFirst()))
        case "capture-screen":
            // Local-only AX capture (NativeMacDriver) → ScreenContextFixture
            // JSON. No model/MLX load, so a plain exit (no Metal teardown) is
            // correct and fast.
            let captureExit = await runCaptureScreen(Array(args.dropFirst()))
            fflush(stdout)
            fflush(stderr)
            exit(captureExit)
        case "agent-loop-lab":
            let labExitCode = await runAgentLoopLab(Array(args.dropFirst()))
            await shutdownAndExit(labExitCode)
        case "diff":
            // Pure file comparison — no MLX/model load, so a plain exit
            // (no Metal teardown) is correct and fast.
            exit(runDiff(Array(args.dropFirst())))
        case "matrix":
            exit(runMatrix(Array(args.dropFirst())))
        case "compat":
            // Pure file aggregation over reports/community/* — no model load.
            exit(runCompat(Array(args.dropFirst())))
        case "scorecard":
            // Pure file aggregation over ComputerUse/ComputerUseLoop reports.
            // No model load, no runtime settings changes.
            exit(runComputerUseScorecard(Array(args.dropFirst())))
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            printUsage()
            exit(2)
        }
    }

    /// Tear MLX/Metal down cooperatively (deadline-bounded) and then
    /// hard-exit, skipping the libc/C++ static destructors that otherwise
    /// hang the process at ~99% CPU after an MLX-heavy run (the Metal
    /// global compute-pipeline cache teardown). Mirrors the host app's
    /// quit path (`AppDelegate.applicationShouldTerminate` phase 3 +
    /// `applicationWillTerminate`'s `_exit`). The JSON report is already
    /// flushed to disk by the caller via `Data.write`; we additionally
    /// flush stdio so a redirected human-readable report isn't lost when
    /// `_exit` skips the libc buffer flush.
    static func shutdownAndExit(_ code: Int32) async -> Never {
        _ = await runWithDeadline(seconds: 8) {
            await ModelRuntime.shutdownForOutOfProcessExit()
        }
        // `_exit` below skips atexit hooks, so the isolated config root
        // (up to ~10 GB of throwaway kv_v2 with the KV regime override)
        // must be removed explicitly — leaked roots piled up to ~100 GB
        // across a marathon and induced disk-pressure decode collapse.
        EvalBootstrap.cleanupIsolatedRootForExit()
        fflush(stdout)
        fflush(stderr)
        Darwin._exit(code)
    }

    @MainActor
    static func runCommand(_ args: [String]) async {
        // Headless harness: provider tools (`osaurus_provider` add / connect /
        // set_credentials) open a modal credential NSPanel and suspend until
        // the user pastes a key. In a headless eval there is no user, so the
        // panel pops on the developer's screen and the case hangs until a
        // watchdog cancels it. Resolve every credential prompt as `.cancelled`
        // for the whole eval process: the model's tool ARGS are already
        // recorded (so `argsMustContain` still scores selection), and a
        // rotation case seeds a real provider so `set_credentials` still
        // reaches — and identifies — the secure-sheet mechanism, just without
        // mounting UI. Production leaves this hook nil.
        ProviderCredentialPromptService.bypassUI = { _ in .cancelled }

        let opts: Options
        do {
            opts = try Options.parse(args)
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printUsage()
            exit(2)
        }

        let suites: [EvalSuite]
        do {
            suites = try opts.suites.map { try EvalSuite.load(from: $0) }
        } catch {
            FileHandle.standardError.write(
                Data(("failed to load suite: \(error.localizedDescription)\n").utf8)
            )
            exit(2)
        }

        // ONE bootstrap for the whole (possibly multi-suite) process: the
        // union of every suite's needs. Multi-suite runs exist so the local
        // model loads + warms once and stays resident across suites.
        let bootstrapPlan = EvalBootstrapPlan.merged(
            suites.map {
                EvalBootstrapPlan.make(
                    suite: $0,
                    filter: opts.filter,
                    preference: opts.pluginBootstrapPreference
                )
            }
        )
        _ = EvalBootstrap.configureIsolatedSearchStorageIfNeeded(for: bootstrapPlan)
        // Default-agent cases EXECUTE real configure write tools; isolate the
        // config root (after the search-isolation call so a mixed suite keeps
        // its plugin `Tools` symlink) so writes never touch the real
        // `~/.osaurus`. No-op for suites without `default_agent` cases.
        // OSAURUS_EVALS_ISOLATE_CONFIG=1 forces isolation regardless: the
        // optimization loop's parallel remote lane sets it so concurrent
        // processes can never race each other (or a live app) on the real
        // config root. Only safe for explicit-model runs (an isolated root
        // has no chat config for `auto` to resolve against) — which remote
        // `provider/model` ids always are.
        let forceConfigIsolation =
            ProcessInfo.processInfo.environment["OSAURUS_EVALS_ISOLATE_CONFIG"] == "1"
        _ = EvalBootstrap.configureIsolatedConfigStorageIfNeeded(
            isolate: forceConfigIsolation
                || suites.contains { $0.selectedCasesIncludeDefaultAgent(filter: opts.filter) }
        )
        let startupWatchdog =
            bootstrapPlan.requiresWork
            ? makeStartupWatchdog(options: opts, suite: suites[0])
            : nil
        await EvalBootstrap.run(bootstrapPlan)
        startupWatchdog?.cancel()

        // Remote-model support: the CLI process never auto-connects the
        // user's configured providers, so `--model xai/grok-4.3` (or a
        // remote JUDGE_MODEL) needs an ephemeral in-process provider
        // whose API key comes from the environment (e.g. XAI_API_KEY).
        // Torn down after the run; never persisted to disk or Keychain.
        let ephemeralProviderIds = await EvalRemoteProviderBootstrap.connectIfNeeded(
            modelIds: EvalRemoteProviderBootstrap.candidateModelIds(runModel: opts.model)
        )

        var exitCode: Int32 = 0
        for (index, suite) in suites.enumerated() {
            let suiteName = suite.directory.lastPathComponent
            if suites.count > 1 {
                FileHandle.standardError.write(
                    Data("[evals] suite \(index + 1)/\(suites.count): \(suiteName)\n".utf8)
                )
            }
            let outPath = resolvedOutPath(for: suite, options: opts)

            // Resume: carry completed rows from the interrupted run's
            // sidecar/report; only errored + watchdog-blocked rows re-run.
            var resumeRows: [EvalCaseReport] = []
            if opts.resume, let outPath {
                let prior = EvalResume.loadPriorRows(outPath: outPath)
                resumeRows = EvalResume.completedRows(prior)
                if !resumeRows.isEmpty {
                    FileHandle.standardError.write(
                        Data(
                            ("[evals] resume: carrying \(resumeRows.count) completed row(s) "
                                + "from \(outPath); re-running the rest\n").utf8
                        )
                    )
                }
            }

            // Incremental sidecar: every completed row lands on disk as it
            // finishes, so a crash mid-suite is resumable with --resume.
            let partialSink = EvalPartialRowSink(outPath: outPath)

            // Full-transcript forensics for failed/errored LLM rows
            // (--transcripts): one JSON per failing case in a sidecar dir
            // next to the report. Needs an output anchor; a stdout-only
            // run gets a warning instead of an invented path.
            if opts.transcripts {
                if let outPath {
                    EvalTranscriptStore.configure(
                        directory: EvalTranscriptStore.sidecarDirectory(forOut: outPath)
                    )
                } else {
                    EvalTranscriptStore.configure(directory: nil)
                    FileHandle.standardError.write(
                        Data(
                            "[evals] --transcripts needs --out/--out-dir to anchor the sidecar dir; skipping\n"
                                .utf8
                        )
                    )
                }
            }

            let baseReport = await EvalRunner.run(
                suite: suite,
                model: opts.model,
                filter: opts.filter,
                thresholdOverride: opts.threshold,
                embedCosineFloorOverride: opts.embedCosineFloor,
                bootstrapMode: .alreadyLoaded,
                // Passed so the per-case watchdog can write a complete report
                // and force-exit if a case wedges the concurrency runtime (the
                // normal return path below never executes in that case).
                outPath: outPath,
                repeatCount: opts.repeatCount,
                resumeRows: resumeRows,
                onCaseCompleted: { partialSink?.append($0) }
            )

            // Stamp run provenance (hardware, OS, build, judge, catalog hash)
            // so every emitted report is self-describing — the trustworthy
            // substrate for crowdsourced model-compatibility contributions.
            // `caseIDs` are the cases that actually ran (post-filter),
            // matching the report rows.
            let report = baseReport.withEnvironment(
                RunEnvironment.current(
                    caseIDs: baseReport.cases.map(\.id),
                    runModel: baseReport.modelId
                )
            )

            print(report.formatHumanReadable(verbose: opts.verbose))

            if opts.reportForensics {
                print("\n" + Self.formatForensicsBlock(report, suite: suite))
            }

            if let outPath {
                do {
                    let data = try report.toJSON(prettyPrinted: true)
                    let url = URL(fileURLWithPath: outPath)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: url)
                    print("\nwrote \(report.cases.count) cases to \(url.path)")
                    partialSink?.finalizeSuccess()
                } catch {
                    FileHandle.standardError.write(
                        Data(("failed to write report: \(error.localizedDescription)\n").utf8)
                    )
                    // Don't fail the run for an output write hiccup — the
                    // human-readable report already printed and is the
                    // primary deliverable. Keep the sidecar for --resume.
                    partialSink?.close()
                }
            }

            if opts.transcripts, let directory = EvalTranscriptStore.directory,
                EvalTranscriptStore.writtenCount > 0
            {
                print(
                    "wrote \(EvalTranscriptStore.writtenCount) failed-case transcript(s) "
                        + "to \(directory.path)"
                )
            }

            let counts = report.counts
            if counts.failed + counts.errored > 0 { exitCode = max(exitCode, 1) }

            // Optional opt-in stricter gate. Walks every case listed in
            // `recall_floors.json`, recomputes the matched-name count
            // against the case's fixture expectations, and trips a breach
            // when matched < `minMatches`. Skipped cases (missing local
            // plugin) are excluded — they're already a "didn't apply"
            // signal, not a regression.
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
                        exitCode = max(exitCode, 1)
                    } else {
                        print("\n[floors] all listed cases met minMatches")
                    }
                } catch {
                    FileHandle.standardError.write(
                        Data(
                            ("failed to load floors at \(floorsURL.path): "
                                + "\(error.localizedDescription)\n").utf8
                        )
                    )
                    exitCode = 2
                }
            }
        }

        EvalRemoteProviderBootstrap.teardown(ephemeralProviderIds)

        await shutdownAndExit(exitCode)
    }

    /// Resolve where a suite's JSON report goes: `--out` (single suite) or
    /// `--out-dir/<prefix><SuiteDirName>.json` (any number of suites).
    /// nil when neither flag was given (stdout-only run).
    static func resolvedOutPath(for suite: EvalSuite, options: Options) -> String? {
        if let dir = options.outDir {
            let name = "\(options.outPrefix)\(suite.directory.lastPathComponent).json"
            return URL(fileURLWithPath: dir).appendingPathComponent(name).path
        }
        return options.out
    }

    // MARK: - Floors

    @MainActor
    private static func makeStartupWatchdog(
        options opts: Options,
        suite: EvalSuite
    ) -> EvalStartupWatchdog? {
        guard let timeoutSeconds = opts.startupTimeoutSeconds else { return nil }

        let modelLabel = ModelOverride.describe(opts.model)
        let reportData = try? EvalTimeoutReport.makeReport(
            suite: suite,
            modelId: modelLabel,
            filter: opts.filter,
            timeoutSeconds: timeoutSeconds,
            phase: "startup bootstrap"
        ).toJSON(prettyPrinted: true)

        return EvalStartupWatchdog(
            timeoutSeconds: timeoutSeconds,
            payload: EvalStartupWatchdog.Payload(
                phase: "startup bootstrap",
                timeoutLabel: EvalTimeoutReport.formatSeconds(timeoutSeconds),
                reportData: reportData,
                // Bootstrap is process-wide; on timeout the errored report
                // lands at the FIRST suite's resolved output path so the
                // matrix driver still gets a real cell.
                outPath: resolvedOutPath(for: suite, options: opts)
            )
        )
    }

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
                    let exp = caseDef.expect.capabilitySearch
                    // Sum matched-name counts across all three lanes so the
                    // gate guards methods/skills cases too — not just tools.
                    // Each case populates one lane's `expected*`, so the sum
                    // naturally resolves to that lane (mirrors the runner's
                    // per-lane `scoreAnyOf`). Accepted sets use unique names
                    // exactly like `runCapabilitySearchCase`'s `acceptedTotal`.
                    let acceptedTools = Set(cs.toolHits.filter(\.acceptedByThreshold).map(\.name))
                    let acceptedMethods = Set(cs.methodHits.filter(\.acceptedByThreshold).map(\.name))
                    let acceptedSkills = Set(cs.skillHits.filter(\.acceptedByThreshold).map(\.name))
                    let toolExpected = exp?.expectedTools?.anyOf ?? []
                    let methodExpected = exp?.expectedMethods?.anyOf ?? []
                    let skillExpected = exp?.expectedSkills?.anyOf ?? []
                    matched =
                        toolExpected.filter { acceptedTools.contains($0) }.count
                        + methodExpected.filter { acceptedMethods.contains($0) }.count
                        + skillExpected.filter { acceptedSkills.contains($0) }.count

                    // `maxAccepted` cap (abstain-style cases): the gate must
                    // also fail when a floored case accepts MORE than its
                    // declared ceiling, not only when recall is too low.
                    // Source of truth is the case fixture (the floor file
                    // only carries `minMatches`); mirrors the runner's
                    // `acceptedTotal` (unique names across all three lanes).
                    if let cap = exp?.maxAccepted {
                        let acceptedTotal =
                            acceptedTools.count + acceptedMethods.count + acceptedSkills.count
                        if acceptedTotal > cap {
                            breaches.append(
                                "\(caseId): accepted \(acceptedTotal), max allowed \(cap)"
                            )
                        }
                    }
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
        /// One or more suite directories (`--suite` is repeatable). Running
        /// several suites in ONE process keeps the local model resident and
        /// warm across suites — a 9-suite LLM pass reloads the model once,
        /// not 9 times (the single biggest wall-clock lever on a Mac).
        let suites: [URL]
        let model: ModelSelection
        let filter: String?
        let out: String?
        /// Per-suite output directory for multi-suite runs: each suite
        /// writes `<outDir>/<outPrefix><SuiteDirName>.json`.
        let outDir: String?
        /// Filename prefix for `--out-dir` files (e.g. `llm-qwen3-4b-`).
        let outPrefix: String
        /// Run every case N times in-process and report the merged
        /// majority outcome + passRate (`trials`/`trialsPassed`).
        let repeatCount: Int
        /// Resume an interrupted run: carry completed rows from the
        /// target output's `.partial.jsonl` sidecar (or the previous
        /// report JSON) and only run what's missing.
        let resume: Bool
        /// Persist the FULL transcript (system prompt, every tool call +
        /// result preview, final text, loop notices) for each failed or
        /// errored LLM case into `<report>.transcripts/<caseId>.json`.
        /// Off by default: transcripts carry the whole composed prompt.
        let transcripts: Bool
        let verbose: Bool
        /// Capability-search **tools-lane** RRF cutoff sweep value.
        /// Forwarded to `EvalRunner.run(thresholdOverride:)`; no-op
        /// for other domains. `nil` keeps the production
        /// `CapabilitySearch.minimumFusedScore`. Methods + skills
        /// lanes always use their own embed-cosine constants (see
        /// `CapabilitySearchEvaluator.evaluate` doc) — sweeping one
        /// scale into the other silently disables the cosine gate.
        let threshold: Float?
        /// Capability-search **tools-lane** embed-cosine quality-gate
        /// sweep value, applied inside RRF fusion
        /// (`ToolSearchService.searchHybrid(minEmbedCosine:)`). `nil` keeps
        /// the production `CapabilitySearch.minimumEmbedCosineForTools`;
        /// `0` disables the gate to record raw pre-gate cosines. Orthogonal
        /// to `--threshold` (the final fused-score cutoff) — this gates each
        /// embed candidate's contribution by its cosine BEFORE fusion.
        let embedCosineFloor: Float?
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
        /// Wall-clock guard for the Core/plugin/index bootstrap that
        /// happens before the first case can run. `nil` disables it.
        let startupTimeoutSeconds: Double?
        /// Controls native installed-plugin bootstrap. Automatic mode
        /// loads plugins only when a suite requires them; capability-search
        /// suites initialize indices without dlopen-ing local plugins.
        let pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference

        static func parse(_ args: [String]) throws -> Options {
            var suites: [URL] = []
            var modelRaw: String?
            var filter: String?
            var out: String?
            var outDir: String?
            var outPrefix = ""
            var repeatCount = 1
            var resume = false
            var transcripts = false
            var verbose = false
            var threshold: Float?
            var embedCosineFloor: Float?
            var reportForensics = false
            var floorsPath: String?
            var failOnFloor = false
            var startupTimeoutSeconds = EvalTimeoutReport.configuredStartupTimeoutSeconds()
            var pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference = .automatic

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--suite":
                    suites.append(try urlForArg(args, after: i, flag: arg))
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
                case "--out-dir":
                    outDir = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--out-prefix":
                    outPrefix = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--repeat":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 1 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    repeatCount = value
                    i += 2
                case "--resume":
                    resume = true
                    i += 1
                case "--transcripts":
                    transcripts = true
                    i += 1
                case "--verbose", "-v":
                    verbose = true
                    i += 1
                case "--threshold":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Float(raw) else { throw CLIError.invalidValue(arg, raw) }
                    threshold = value
                    i += 2
                case "--embed-cosine-floor":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Float(raw) else { throw CLIError.invalidValue(arg, raw) }
                    embedCosineFloor = value
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
                case "--startup-timeout":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = EvalTimeoutReport.parseTimeoutSeconds(raw) else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    startupTimeoutSeconds = value > 0 ? value : nil
                    i += 2
                case "--bootstrap-plugins":
                    pluginBootstrapPreference = .force
                    i += 1
                case "--no-plugin-bootstrap":
                    pluginBootstrapPreference = .disabled
                    i += 1
                case "--help", "-h":
                    printUsage()
                    exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            guard !suites.isEmpty else { throw CLIError.missingFlag("--suite") }
            if suites.count > 1 && out != nil {
                throw CLIError.invalidValue(
                    "--out",
                    "single file with multiple --suite dirs; use --out-dir instead"
                )
            }
            return Options(
                suites: suites,
                model: ModelSelection.parse(modelRaw),
                filter: filter,
                out: out,
                outDir: outDir,
                outPrefix: outPrefix,
                repeatCount: repeatCount,
                resume: resume,
                transcripts: transcripts,
                verbose: verbose,
                threshold: threshold,
                embedCosineFloor: embedCosineFloor,
                reportForensics: reportForensics,
                floorsPath: floorsPath,
                failOnFloor: failOnFloor,
                startupTimeoutSeconds: startupTimeoutSeconds,
                pluginBootstrapPreference: pluginBootstrapPreference
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
                osaurus-evals run --suite <dir> [--suite <dir> ...] [--model <id>] [--filter <substr>]
                                              [--out <path> | --out-dir <dir> [--out-prefix <p>]]
                                              [--repeat <n>] [--resume] [--transcripts]
                                              [--threshold <float>] [--report-forensics]
                                              [--startup-timeout <seconds>]
                osaurus-evals capture-screen [--app <name>] [--out <path>]
                osaurus-evals agent-loop-lab --baseline <path> [--suite <dir> ...] [--model <id>]
                osaurus-evals diff <baseline> <current> [--out <p>] [--markdown <p>]
                                              [--fail-on-regression]
                osaurus-evals matrix <reports-dir> [--out <p>] [--markdown <p>]
                osaurus-evals compat <community-dir> [--out <p>] [--markdown <p>] [--validate]
                osaurus-evals scorecard <report.json|reports-dir> [...] [--out-dir <dir>]
                                        [--out <json>] [--markdown <md>]

            FLAGS:
                --suite <dir>         Required; repeatable. Directory of *.json eval
                                      cases (e.g. Suites/CapabilitySearch). Passing
                                      several dirs runs them all in ONE process so
                                      the local model loads + warms once and stays
                                      resident across suites.
                --model <id>          Model to route through CoreModelService for
                                      this run. Forms:
                                        auto                — keep current config
                                        foundation          — Apple Foundation Models
                                        openai/gpt-4o-mini  — provider/name pair
                                        qwen3-4b            — bare local id
                                      Default: auto.
                --filter <substr>     Only run cases whose id contains <substr>.
                --out <path>          Also write a JSON report to <path>. Single
                                      --suite only; use --out-dir for multi-suite.
                --out-dir <dir>       Write one report per suite to
                                      <dir>/<prefix><SuiteDirName>.json.
                --out-prefix <p>      Filename prefix for --out-dir files
                                      (e.g. llm-qwen3-4b-). Default: none.
                --repeat <n>          Run every case n times in this process
                                      (model stays warm) and report the merged
                                      majority outcome plus a trials/passRate
                                      pair. Trials that disagree mark the row
                                      FLAKY; diff treats flips on flaky rows as
                                      non-blocking. Default: 1.
                --resume              Carry completed rows from an interrupted
                                      run (the --out path's .partial.jsonl
                                      sidecar, or a previous report JSON) and
                                      only run what's missing. errored /
                                      watchdog-blocked rows always re-run.
                --transcripts         Persist the FULL transcript (system
                                      prompt, tool calls + result previews,
                                      final text, loop notices) for every
                                      failed/errored LLM case to
                                      <report>.transcripts/<caseId>.json.
                                      Needs --out/--out-dir. Off by default —
                                      transcripts carry the whole composed
                                      prompt, which shared reports shouldn't.
                --verbose, -v         Print per-case diagnostics: the user query
                                      for each case.
                --threshold <float>   Override the **tools-lane** RRF cutoff
                                      (`minFusedScore`) for this run. The
                                      methods + skills lanes always use their
                                      own production embed-cosine constants
                                      (`minimumRelevanceScoreMethods` /
                                      `…Skills`) regardless of this flag —
                                      fused-score and cosine values live on
                                      different scales (RRF max ≈ 0.033 vs
                                      cosine 0–1), so a single knob can't
                                      drive both meaningfully. Use this to
                                      sweep RRF cutoffs (e.g. --threshold
                                      0.020) without rebuilding. No-op for
                                      non-capability_search domains.
                --embed-cosine-floor <float>
                                      Override the **tools-lane** embed-cosine
                                      quality gate applied inside RRF fusion
                                      (`minEmbedCosine`). Embed candidates
                                      below this cosine contribute zero to
                                      fusion, so abstain noise can't rank-fuse
                                      past the cutoff. `nil` keeps the
                                      production constant
                                      (`minimumEmbedCosineForTools`); pass 0 to
                                      disable the gate and record raw pre-gate
                                      cosines during a calibration sweep.
                                      No-op for non-capability_search domains.
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
                --startup-timeout <s> Wall-clock guard for startup bootstrap
                                      (installed plugins + search indices)
                                      before the first case runs. On timeout,
                                      writes an errored JSON report when
                                      --out is set and exits 124. Use 0 to
                                      disable. Defaults: 120s locally, 30s
                                      when CI=true. Env override:
                                      OSAURUS_EVALS_STARTUP_TIMEOUT_SECONDS.
                --bootstrap-plugins  Force installed native plugin loading
                                      before the suite. Automatic mode loads
                                      plugins only when a suite requires them.
                --no-plugin-bootstrap
                                      Disable installed native plugin loading.
                                      Capability-search suites initialize only
                                      selected search-index lanes in isolated
                                      eval storage and skip plugin-required
                                      cases when no plugin is loaded.
                scorecard             Reads existing EvalReport JSON artifacts
                                      and writes privacy-safe Computer Use
                                      scorecard JSON + Markdown. Defaults to
                                      build/evals/computer-use-scorecard/.

            EXAMPLES:
                osaurus-evals run --suite Suites/CapabilitySearch --model foundation
                osaurus-evals run --suite Suites/CapabilitySearch --filter browser --out report.json
                osaurus-evals run --suite Suites/CapabilitySearch --threshold 0.25 --report-forensics
                osaurus-evals run --suite Suites/CapabilitySearch --fail-on-floor
                osaurus-evals agent-loop-lab --baseline reports/main-agentloop
                osaurus-evals scorecard build/evals/computer-use.json build/evals/computer-use-loop.json
            """
        print(usage)
    }
}

final class EvalStartupWatchdog: @unchecked Sendable {
    struct Payload: Sendable {
        let phase: String
        let timeoutLabel: String
        let reportData: Data?
        let outPath: String?
    }

    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let payload: Payload
    private var active = true

    init(timeoutSeconds: Double, payload: Payload) {
        self.payload = payload
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let milliseconds = max(1, Int((timeoutSeconds * 1_000).rounded(.up)))
        timer.schedule(deadline: .now() + .milliseconds(milliseconds))
        timer.setEventHandler { [weak self] in
            self?.fire()
        }
        timer.resume()
    }

    func cancel() {
        guard markInactive() else { return }
        timer.cancel()
    }

    private func fire() {
        guard markInactive() else { return }

        writeStderr(
            "eval timeout: \(payload.phase) exceeded \(payload.timeoutLabel); exiting 124\n"
        )

        if let reportData = payload.reportData, let outPath = payload.outPath {
            do {
                let url = URL(fileURLWithPath: outPath)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try reportData.write(to: url)
                writeStderr("wrote timeout report to \(url.path)\n")
            } catch {
                writeStderr("failed to write timeout report: \(error.localizedDescription)\n")
            }
        }

        Darwin._exit(124)
    }

    private func markInactive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        active = false
        return true
    }

    private func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
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
