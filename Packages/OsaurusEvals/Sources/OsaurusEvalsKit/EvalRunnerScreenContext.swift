//
//  EvalRunnerScreenContext.swift
//  OsaurusEvalsKit
//
//  Runner for the `screen_context` domain: replays a `ScreenContextFixture`
//  through the real `ScreenContextDistiller` via the read-only
//  `FixtureCUDriver`, then scores the rendered `[Screen Context]` block. This
//  is the "is the ambient snapshot useful" lane — it guards that the distiller
//  surfaces what the user is looking at (focused editor/input, selection,
//  on-screen content) and drops chrome noise (Xcode's package-version sidebar).
//
//  Two scoring tiers, both off the same `render()`:
//    - Deterministic matchers run with NO model, so the suite is CI-safe and
//      forms the regression floor (`screen_context` is intentionally excluded
//      from `resourceSampledDomains`).
//    - An optional LLM-judge rubric grades semantic quality — but only when a
//      strong/explicit judge resolves (a `*_API_KEY` or `JUDGE_MODEL`), so CI
//      (no judge) never pays the token cost and stays deterministic. The
//      rendered block is always echoed into `notes` so `--verbose` shows
//      exactly what the distiller produced (the tuning signal).
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Pure-data + optional-judge evaluator for `domain == "screen_context"`.
    static func runScreenContextCase(
        _ testCase: EvalCase,
        modelId: String,
        suiteDirectory: URL
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        func erroredReport(_ note: String) -> EvalCaseReport {
            .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: [note],
                modelId: modelId
            )
        }

        guard let exp = testCase.expect.screenContext else {
            return erroredReport("missing `expect.screenContext`")
        }

        let fixture: ScreenContextFixture
        switch loadScreenContextFixture(exp, suiteDirectory: suiteDirectory) {
        case .success(let loaded):
            fixture = loaded
        case .failure(let error):
            return erroredReport(error.message)
        }

        // Replay the fixture through the production distiller. The synthetic
        // self pid can never collide with a fixture app pid, so the working app
        // always resolves to the fixture's frontmost (or first) app.
        let driver = FixtureCUDriver(fixture: fixture)
        let started = Date()
        let snapshot = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: Int32.max,
            selfBundleId: nil,
            preferredPid: nil
        )
        let rendered = snapshot.render()
        let latency = Date().timeIntervalSince(started) * 1000

        var passed = true
        var notes: [String] = []
        func check(_ ok: Bool, pass: String, fail: String) {
            passed = passed && ok
            notes.append(ok ? pass : fail)
        }

        if rendered.isEmpty {
            notes.append("warning: distiller produced an empty block (nothing to inject)")
        }

        // 1. Substring presence / absence over the rendered block.
        for needle in exp.mustContain ?? [] {
            check(
                rendered.contains(needle),
                pass: "mustContain ok: '\(needle)'",
                fail: "mustContain missing: '\(needle)'"
            )
        }
        for needle in exp.mustNotContain ?? [] {
            check(
                !rendered.contains(needle),
                pass: "mustNotContain ok: '\(needle)'",
                fail: "mustNotContain present (should be dropped): '\(needle)'"
            )
        }

        // 2. Noise regexes — each must NOT match (e.g. a bare-version bullet).
        for pattern in exp.noiseRegexMustNotMatch ?? [] {
            switch Self.regexMatches(pattern, in: rendered) {
            case .some(false):
                notes.append("noiseRegex ok (no match): /\(pattern)/")
            case .some(true):
                passed = false
                notes.append("noiseRegex matched (noise leaked): /\(pattern)/")
            case .none:
                passed = false
                notes.append("noiseRegex invalid (case bug): /\(pattern)/")
            }
        }

        // 3. Focused-element field checks (read off the structured snapshot, not
        //    the rendered text, so they pin the exact signal).
        if let wantRole = exp.focusedRoleEquals {
            let actual = snapshot.focusedElement?.role
            check(
                actual == wantRole,
                pass: "focusedRole ok: '\(wantRole)'",
                fail: "focusedRole mismatch: expected '\(wantRole)', got '\(actual ?? "nil")'"
            )
        }
        if let needle = exp.selectedTextContains {
            let selected = snapshot.focusedElement?.selectedText ?? ""
            check(
                selected.contains(needle),
                pass: "selectedText contains '\(needle)'",
                fail: "selectedText '\(selected)' missing '\(needle)'"
            )
        }
        for needle in exp.viewingContains ?? [] {
            let viewing = snapshot.focusedElement?.viewing ?? ""
            check(
                viewing.contains(needle),
                pass: "viewing contains '\(needle)'",
                fail: "viewing missing '\(needle)' (got: '\(viewing)')"
            )
        }

        // 4. Activity gist ("Doing:" line).
        for needle in exp.gistContains ?? [] {
            let gist = snapshot.activityGist ?? ""
            check(
                gist.contains(needle),
                pass: "gist contains '\(needle)'",
                fail: "gist '\(gist)' missing '\(needle)'"
            )
        }

        // 5. Ordering — each sequence must appear as an in-order subsequence of
        //    the rendered block (pins editor-beats-chrome ranking).
        for sequence in exp.orderedContains ?? [] {
            let result = Self.orderedSubsequence(sequence, in: rendered)
            check(
                result.ok,
                pass: "order ok: \(sequence)",
                fail: "order broken: \(result.detail)"
            )
        }

        // 6. Optional LLM-judge rubric — graded ONLY when a real judge resolves
        //    (explicit JUDGE_MODEL or a strong `*_API_KEY`). The self-judge
        //    fallback is treated as "no judge available" so CI stays
        //    deterministic and free; a maintainer tuning locally exports a key.
        var judgeAudit: EvalJudgeAudit?
        var judgeElapsed: Double?
        if let rubric = exp.rubric, !rubric.isEmpty {
            let resolution = EvalJudgeModel.resolve(runModelId: modelId)
            if resolution.isSelfJudge {
                notes.append(
                    "rubric: skipped (\(rubric.count) condition(s); no strong judge — set "
                        + "JUDGE_MODEL or a *_API_KEY to grade)"
                )
            } else {
                if let note = resolution.note { notes.append(note) }
                // Self-heal the ephemeral judge provider in case a prior
                // provider-mutating suite evicted it (idempotent no-op
                // while the judge is still routable).
                await EvalRunner.ensureJudgeProviderRoutable(resolution.modelId)
                let judgeStarted = Date()
                let audit = await CapabilityClaimsEvaluator.judgeDetailed(
                    finalText: rendered,
                    conditions: rubric,
                    model: resolution.modelId
                )
                judgeElapsed = Date().timeIntervalSince(judgeStarted) * 1000
                let verdicts = audit.verdicts
                judgeAudit = EvalJudgeAudit.from(audit, rubric: rubric, selfJudge: false)
                for (index, verdict) in verdicts.enumerated() {
                    let condition = index < rubric.count ? rubric[index] : "(condition \(index))"
                    if verdict.pass {
                        notes.append("judge ok: \(condition)")
                    } else {
                        passed = false
                        notes.append("judge FAIL: \(condition) — \(verdict.reason)")
                    }
                }
                if verdicts.count != rubric.count {
                    passed = false
                    notes.append(
                        "judge produced \(verdicts.count) verdicts for \(rubric.count) conditions"
                    )
                }
            }
        }

        // Always echo the rendered block last so `--verbose` shows exactly what
        // the distiller produced — the signal the tuning loop reads.
        notes.append("rendered:\n\(rendered)")

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: latency,
            judgeLatencyMs: judgeElapsed,
            judge: judgeAudit
        )
    }

    // MARK: - Fixture loading

    /// Typed load failure carrying a human-readable message for the report.
    struct ScreenContextLoadError: Error {
        let message: String
    }

    /// Resolve the case's fixture: an inline `scene` wins; otherwise load the
    /// `fixture` path from the first existing candidate location.
    private static func loadScreenContextFixture(
        _ exp: EvalCase.ScreenContextExpectations,
        suiteDirectory: URL
    ) -> Result<ScreenContextFixture, ScreenContextLoadError> {
        if let scene = exp.scene {
            return .success(scene)
        }
        guard let relative = exp.fixture, !relative.isEmpty else {
            return .failure(
                ScreenContextLoadError(
                    message: "expect.screenContext needs `scene` (inline) or `fixture` (path)"
                )
            )
        }
        let candidates = fixtureCandidateURLs(relative, suiteDirectory: suiteDirectory)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let fixture = try JSONDecoder().decode(ScreenContextFixture.self, from: data)
                return .success(fixture)
            } catch {
                return .failure(
                    ScreenContextLoadError(
                        message: "failed to decode fixture '\(relative)' at \(url.path): \(error)"
                    )
                )
            }
        }
        return .failure(
            ScreenContextLoadError(
                message: "fixture '\(relative)' not found (looked in: "
                    + candidates.map(\.path).joined(separator: ", ") + ")"
            )
        )
    }

    /// Candidate on-disk locations for a fixture path, most specific first:
    ///   1. as given (absolute or CWD-relative),
    ///   2. `<package>/Fixtures/ScreenContext/<path>` derived from the suite dir
    ///      (`<package>/Suites/ScreenContext`), so resolution is CWD-independent,
    ///   3. the conventional repo-root-relative path (running from the checkout).
    private static func fixtureCandidateURLs(
        _ relative: String,
        suiteDirectory: URL
    ) -> [URL] {
        var urls: [URL] = [URL(fileURLWithPath: relative)]
        let fixturesDir =
            suiteDirectory
            .deletingLastPathComponent()  // Suites/
            .deletingLastPathComponent()  // <package>/
            .appendingPathComponent("Fixtures/ScreenContext", isDirectory: true)
        urls.append(fixturesDir.appendingPathComponent(relative))
        urls.append(
            URL(fileURLWithPath: "Packages/OsaurusEvals/Fixtures/ScreenContext/\(relative)")
        )
        return urls
    }

    // MARK: - Matchers

    /// Whether `pattern` matches anywhere in `text`. Returns nil when the
    /// pattern doesn't compile (surfaced as a case bug, not a silent pass).
    /// Inline flags like `(?m)` are honored by `NSRegularExpression`.
    private static func regexMatches(_ pattern: String, in text: String) -> Bool? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Whether `needles` appear in `text` as an ordered, non-overlapping
    /// subsequence (each found strictly after the previous one's match).
    private static func orderedSubsequence(
        _ needles: [String],
        in text: String
    ) -> (ok: Bool, detail: String) {
        var searchStart = text.startIndex
        var previous = "(start)"
        for needle in needles {
            guard let found = text.range(of: needle, range: searchStart ..< text.endIndex) else {
                return (false, "'\(needle)' not found after '\(previous)'")
            }
            searchStart = found.upperBound
            previous = needle
        }
        return (true, "")
    }
}
