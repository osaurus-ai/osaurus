//
//  Bench.swift
//  osaurus
//
//  `osaurus bench` — standardized inference benchmark against the local
//  server, so performance changes can be stated as before/after numbers on
//  the same machine instead of impressions. Measures, per prompt size:
//
//    - uncached TTFT (unique-prefix prompt: no prefix-cache hit possible)
//    - cached TTFT   (identical prompt re-sent: paged prefix-cache hit path)
//    - prefill tok/s (prompt_tokens / uncached TTFT — includes template and
//                     tokenization overhead by design; that is what a user
//                     actually waits for)
//    - decode tok/s  (completion tokens per second between the first and
//                     last streamed delta, i.e. excluding prefill)
//
//  Token counts come from the server (`stream_options.include_usage`), not
//  client-side estimates. Sampling is greedy (temperature 0) so runs are
//  comparable. Results are emitted as JSON tagged with the server's
//  /health `hardware` block; medians over `--runs` repetitions are
//  reported alongside the raw samples.
//

import Foundation

public struct BenchCommand: Command {
    public static let name = "bench"

    private static let defaultPromptTokens = [1_024, 8_192]
    private static let defaultMaxTokens = 128
    private static let defaultRuns = 3

    private static let defaultTuneCandidates = [512, 1_024, 2_048, 4_096]

    /// `--kv-matrix` defaults cover a common long prompt and a larger context
    /// where codec overhead and memory pressure can become visible.
    private static let defaultKVMatrixPromptTokens = [8_192, 32_768]
    private static let defaultKVMatrixRuns = 2

    struct Options {
        var model: String?
        var promptTokens: [Int] = BenchCommand.defaultPromptTokens
        var maxTokens: Int = BenchCommand.defaultMaxTokens
        var runs: Int = BenchCommand.defaultRuns
        var jsonPath: String?
        var port: Int
        var tunePrefill: Bool = false
        var tuneCandidates: [Int] = BenchCommand.defaultTuneCandidates
        var kvMatrix: Bool = false
        /// Set when the user passed the flag explicitly, so `--kv-matrix`
        /// can apply its own defaults without overriding a user's choice.
        var promptTokensExplicit: Bool = false
        var runsExplicit: Bool = false
    }

    public static func execute(args: [String]) async {
        guard var options = parseOptions(args) else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        let base = URL(string: "http://127.0.0.1:\(options.port)")!

        guard let health = await fetchJSON(base.appendingPathComponent("health")) else {
            fputs("Server is not running on port \(options.port). Start it with `osaurus serve`.\n", stderr)
            exit(EXIT_FAILURE)
        }

        if options.model == nil {
            options.model = await defaultModel(base: base)
        }
        guard let model = options.model else {
            fputs("No model specified and none installed. Use --model <id>.\n", stderr)
            exit(EXIT_FAILURE)
        }

        if options.tunePrefill {
            await tunePrefill(options: options, model: model, base: base, health: health)
            // tunePrefill exits the process itself.
        }

        if options.kvMatrix {
            if !options.promptTokensExplicit { options.promptTokens = defaultKVMatrixPromptTokens }
            if !options.runsExplicit { options.runs = defaultKVMatrixRuns }
            await kvMatrix(options: options, model: model, base: base, health: health)
            // kvMatrix exits the process itself.
        }

        fputs("Benchmarking \(model) (\(options.runs) runs × prompt sizes \(options.promptTokens))…\n", stderr)

        var scenarios: [[String: Any]] = []
        for target in options.promptTokens {
            var uncached: [Sample] = []
            var cached: [Sample] = []
            for run in 0..<options.runs {
                // A unique prefix guarantees the first request cannot reuse a
                // cached prefix from an earlier run; re-sending the identical
                // prompt immediately afterwards measures the cache-hit path.
                let prompt = makePrompt(targetTokens: target, nonce: "run\(run)-\(UUID().uuidString)")
                do {
                    let first = try await measureOnce(
                        base: base, model: model, prompt: prompt, maxTokens: options.maxTokens)
                    let second = try await measureOnce(
                        base: base, model: model, prompt: prompt, maxTokens: options.maxTokens)
                    uncached.append(first)
                    cached.append(second)
                    fputs(
                        String(
                            format:
                                "  prompt≈%d run %d: uncached TTFT %.0f ms → cached %.0f ms, decode %.1f tok/s\n",
                            target, run + 1, first.ttftMs, second.ttftMs, first.decodeTps),
                        stderr)
                } catch {
                    fputs("  prompt≈\(target) run \(run + 1) failed: \(error.localizedDescription)\n", stderr)
                }
            }
            guard !uncached.isEmpty else { continue }
            scenarios.append([
                "target_prompt_tokens": target,
                "actual_prompt_tokens": uncached.map { $0.promptTokens },
                "uncached": summarize(uncached),
                "cached": summarize(cached),
            ])
        }

        guard !scenarios.isEmpty else {
            fputs("All benchmark runs failed.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let report: [String: Any] = [
            "schema": "osaurus-bench/1",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "model": model,
            "max_tokens": options.maxTokens,
            "runs": options.runs,
            "hardware": (health["hardware"] as? [String: Any]) ?? NSNull(),
            "scenarios": scenarios,
            "methodology": [
                "sampling": "temperature 0 (greedy)",
                "token_counts": "server usage via stream_options.include_usage",
                "ttft": "request start → first non-empty content delta",
                "decode_tps": "(completion_tokens - 1) / (last delta - first delta)",
                "prefill_tps": "prompt_tokens / uncached TTFT (includes template + tokenize)",
            ],
        ]

        emitReportAndExit(report, jsonPath: options.jsonPath)
    }

    /// Serializes a report and emits it (file with `--json`, stdout
    /// otherwise). Shared by the main bench path and `--kv-matrix`.
    static func emitReportAndExit(_ report: [String: Any], jsonPath: String?) -> Never {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        } catch {
            fputs("Failed to encode report: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
        if let path = jsonPath {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: url)
                fputs("Wrote \(path)\n", stderr)
            } catch {
                fputs("Failed to write \(path): \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } else {
            print(String(bytes: data, encoding: .utf8) ?? "{}")
        }
        exit(EXIT_SUCCESS)
    }

    // MARK: - Prefill tuning (`--tune-prefill`)

    /// Measures the model's uncached TTFT at each candidate prefill step size
    /// and persists the winner to `~/.osaurus/config/prefill-tuning.json`,
    /// which the server re-reads per request (mtime-checked) — no restart
    /// needed, which is also what makes this sweep possible over HTTP.
    ///
    /// The optimal step is model-architecture-dependent: measured on one
    /// M5 Max, a small dense model was fastest at 512 while a 35B MoE was
    /// 22–24% faster at 2048. Hence a measured per-model value instead of a
    /// global setting.
    static func tunePrefill(
        options: Options, model: String, base: URL, health: [String: Any]
    ) async -> Never {
        // Chunking matters most on long prompts; tune at the largest
        // requested size.
        let target = options.promptTokens.max() ?? 8_192
        let file = tuningFileURL()
        let previous = readTuningRecords(at: file)[model]
        let backup = URL(fileURLWithPath: file.path + ".tune-backup")

        // The sweep mutates the LIVE tuning file before each measurement, so
        // an interruption would otherwise leave a probe candidate installed
        // permanently. Before the first mutation: (1) write a sidecar backup
        // of the pre-sweep file so even SIGKILL is hand-recoverable, and
        // (2) install SIGINT/SIGTERM handlers that restore the pre-sweep
        // record (or remove the key when none existed) and exit non-zero.
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let originalData = (try? Data(contentsOf: file)) ?? Data("{}".utf8)
            try originalData.write(to: backup, options: .atomic)
        } catch {
            fputs("Cannot write backup \(backup.path): \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
        tuneSweepRestore = (file: file, model: model, previous: previous, backup: backup)
        signal(SIGINT) { _ in
            BenchCommand.tuneSweepAbortRestore()
            _Exit(EXIT_FAILURE)
        }
        signal(SIGTERM) { _ in
            BenchCommand.tuneSweepAbortRestore()
            _Exit(EXIT_FAILURE)
        }

        fputs("Tuning prefill step for \(model) at ~\(target) prompt tokens (candidates \(options.tuneCandidates), \(options.runs) run(s) each; backup: \(backup.path))…\n", stderr)

        // Warm the model (and its engine) so the first candidate doesn't
        // absorb the cold model load.
        _ = try? await measureOnce(
            base: base, model: model,
            prompt: makePrompt(targetTokens: 256, nonce: "tune-warm-\(UUID().uuidString)"),
            maxTokens: 8)

        var results: [(step: Int, medianTTFTMs: Double)] = []
        for step in options.tuneCandidates {
            do {
                try writeTuningRecord(
                    at: file, model: model,
                    record: ["prefillStepSize": step, "note": "candidate under test"])
            } catch {
                // Leave no half-tuned candidate behind on this exit either.
                tuneSweepAbortRestore()
                fputs("Cannot write \(file.path): \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
            var ttfts: [Double] = []
            for run in 0..<options.runs {
                do {
                    let sample = try await measureOnce(
                        base: base, model: model,
                        prompt: makePrompt(
                            targetTokens: target, nonce: "tune-\(step)-\(run)-\(UUID().uuidString)"),
                        maxTokens: 32)
                    ttfts.append(sample.ttftMs)
                } catch {
                    fputs("  step \(step) run \(run + 1) failed: \(error.localizedDescription)\n", stderr)
                }
            }
            guard !ttfts.isEmpty else { continue }
            let med = median(ttfts)
            results.append((step, med))
            fputs(String(format: "  step %4d: median uncached TTFT %.0f ms %@\n", step, med,
                         ttfts.map { String(format: "%.0f", $0) }.joined(separator: "/")), stderr)
        }

        guard let winner = selectTuneWinner(results) else {
            // Leave no half-tuned candidate behind.
            tuneSweepAbortRestore()
            fputs("All candidates failed; nothing persisted.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let chip = (health["hardware"] as? [String: Any])?["chip"] as? String
        var record: [String: Any] = [
            "prefillStepSize": winner.step,
            "measuredAt": ISO8601DateFormatter().string(from: Date()),
            "benchTTFTMs": winner.medianTTFTMs,
        ]
        if let chip { record["chip"] = chip }
        do {
            try writeTuningRecord(at: file, model: model, record: record)
        } catch {
            tuneSweepAbortRestore()
            fputs("Cannot persist result: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
        // Clean completion: the winner is persisted, so the interruption
        // safety net (sidecar backup + signal restore) is no longer wanted.
        tuneSweepRestore = nil
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        try? FileManager.default.removeItem(at: backup)
        fputs(String(
            format: "Winner: prefillStepSize=%d (median TTFT %.0f ms). Persisted to %@ — applies to the next request, no restart needed.\n",
            winner.step, winner.medianTTFTMs, file.path), stderr)
        exit(EXIT_SUCCESS)
    }

    // MARK: - Sweep interruption safety

    /// State the SIGINT/SIGTERM handlers need to undo a half-finished sweep.
    /// A C signal handler cannot capture context, so it lives in static
    /// storage that the (non-capturing) handler closures read.
    nonisolated(unsafe) static var tuneSweepRestore:
        (file: URL, model: String, previous: [String: Any]?, backup: URL)?

    /// Restores the pre-sweep tuning record (or removes the key when none
    /// existed) and deletes the sidecar backup. Called from every early-exit
    /// path of `tunePrefill` and from the SIGINT/SIGTERM handlers; a no-op
    /// once the sweep has completed cleanly.
    static func tuneSweepAbortRestore() {
        guard let state = tuneSweepRestore else { return }
        tuneSweepRestore = nil
        restoreTuningRecord(at: state.file, model: state.model, previous: state.previous)
        try? FileManager.default.removeItem(at: state.backup)
    }

    /// Winner selection with a noise-floor tie-break: among candidates whose
    /// median TTFT is within `tuneNoiseTolerance` of the best, pick the
    /// SMALLEST step. Near-ties resolve toward vmlx's default-adjacent value;
    /// 3% is under the tool's observed run-to-run noise, so a "win" inside
    /// that band is not evidence the larger step is actually faster.
    static let tuneNoiseTolerance = 0.03

    static func selectTuneWinner(
        _ results: [(step: Int, medianTTFTMs: Double)]
    ) -> (step: Int, medianTTFTMs: Double)? {
        guard let best = results.min(by: { $0.medianTTFTMs < $1.medianTTFTMs }) else {
            return nil
        }
        let cutoff = best.medianTTFTMs * (1 + tuneNoiseTolerance)
        return results.filter { $0.medianTTFTMs <= cutoff }.min { $0.step < $1.step }
    }

    /// The server-side reader is `ModelPrefillTuningStore` (OsaurusCore);
    /// the CLI writes the same JSON contract without linking OsaurusCore.
    static func tuningFileURL() -> URL {
        Configuration.root()
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("prefill-tuning.json")
    }

    static func readTuningRecords(at url: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return obj
    }

    static func writeTuningRecord(
        at url: URL, model: String, record: [String: Any]
    ) throws {
        var records = readTuningRecords(at: url)
        records[model] = record
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func restoreTuningRecord(
        at url: URL, model: String, previous: [String: Any]?
    ) {
        var records = readTuningRecords(at: url)
        if let previous {
            records[model] = previous
        } else {
            records.removeValue(forKey: model)
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - KV codec matrix (`--kv-matrix`)

    /// `cache.liveKVCodec` values under test (raw values of the vmlx
    /// `VMLXKVCacheCodec` contract in `server-runtime.json`). Baseline first,
    /// so turboquant cells can be reported against engine-selected behavior.
    static let kvMatrixCodecs = ["engine_selected", "turboquant"]

    static let kvMatrixCodecDescriptions: [String: String] = [
        "engine_selected":
            "engine-selected live KV baseline; effective codec resolution remains runtime-defined",
        "turboquant": "TurboQuant live KV — explicit opt-in, never auto-enabled",
    ]

    /// Below this many completion tokens the decode window is too short for
    /// a stable tok/s estimate, so the cell is flagged low-confidence.
    static let kvMatrixLowConfidenceCompletionTokens = 32

    enum KVMatrixError: LocalizedError {
        case malformedConfig(String)
        case restoreFailed(String)

        var errorDescription: String? {
            switch self {
            case .malformedConfig(let detail):
                return "server-runtime.json does not look like a runtime settings file (\(detail))"
            case .restoreFailed(let detail):
                return "could not restore server-runtime.json (\(detail))"
            }
        }
    }

    /// Fp16 vs TurboQuant live-KV measurement matrix. It produces per-model,
    /// per-machine evidence without changing runtime defaults.
    ///
    /// Per codec: write `cache.liveKVCodec`, full app restart (the app only
    /// reads `server-runtime.json` at launch — a bare server stop/serve keeps
    /// the in-memory snapshot), verify the active codec over HTTP, then run
    /// the same uncached/cached measurement pairs as the main bench path.
    static func kvMatrix(
        options: Options, model: String, base: URL, health: [String: Any]
    ) async -> Never {
        let configURL = runtimeConfigFileURL()
        let originalData: Data
        let codecConfigData: [String: Data]
        do {
            originalData = try Data(contentsOf: configURL)
            // Validate up front so we never restart on a file we could not
            // mutate (and therefore could not have restored) safely.
            codecConfigData = try Dictionary(
                uniqueKeysWithValues: kvMatrixCodecs.map { codec in
                    (codec, try configData(settingLiveKVCodec: codec, in: originalData))
                })
        } catch {
            fputs(
                "Cannot use \(configURL.path): \(error.localizedDescription)\nLaunch Osaurus once so the runtime settings file exists.\n",
                stderr)
            exit(EXIT_FAILURE)
        }

        // Interruption safety: the run mutates the LIVE server-runtime.json,
        // so Ctrl-C/SIGTERM mid-run would otherwise leave a probe codec
        // installed permanently. Before the first mutation: (1) write a
        // sidecar backup so even SIGKILL is hand-recoverable, and (2) install
        // SIGINT/SIGTERM handlers that restore the original bytes (printing
        // the recovery blob on failure) and exit non-zero.
        let backup = kvMatrixBackupURL(for: configURL)
        do {
            try createKVMatrixBackup(originalData, at: backup)
        } catch {
            fputs(
                "Cannot create backup \(backup.path): \(error.localizedDescription)\n"
                    + "If this is left from an interrupted run, restore or remove it before retrying.\n",
                stderr)
            exit(EXIT_FAILURE)
        }
        armKVMatrixRestore(
            configURL: configURL,
            originalData: originalData,
            ownedData: [originalData] + Array(codecConfigData.values),
            backup: backup
        )
        installKVMatrixSignalHandlers()

        fputs(
            "KV matrix for \(model): codecs \(kvMatrixCodecs), prompt sizes \(options.promptTokens), \(options.runs) run(s) each.\nEach codec needs a full app restart; your original config is restored afterwards (backup: \(backup.path)).\n",
            stderr)

        var codecBlocks: [[String: Any]] = []
        var cells: [KVMatrixCell] = []
        var fatal: String?
        var didMutateConfig = false
        var lastWrittenData: Data?

        measurement: for codec in kvMatrixCodecs {
            do {
                guard let mutated = codecConfigData[codec] else {
                    fatal = "missing prepared config for codec \(codec)"
                    break measurement
                }
                let expected = lastWrittenData ?? originalData
                guard try writeKVMatrixConfig(
                    at: configURL, expectedData: expected, newData: mutated)
                else {
                    fatal =
                        "server-runtime.json changed during the run; refusing to overwrite concurrent changes"
                    break measurement
                }
                didMutateConfig = true
                lastWrittenData = mutated
            } catch {
                fatal = "failed to write \(configURL.path): \(error.localizedDescription)"
                break measurement
            }
            fputs("[\(codec)] restarting server…\n", stderr)
            guard await restartServerForConfigReload(port: options.port) else {
                fatal = "server did not come back healthy after restart for codec \(codec)"
                break measurement
            }
            guard let active = await activeLiveKVCodec(base: base) else {
                fatal =
                    "cannot verify codec \"\(codec)\": /admin/runtime-settings did not return cache.liveKVCodec"
                break measurement
            }
            guard active == codec else {
                fatal =
                    "server reports live KV codec \"\(active)\" after restart (expected \"\(codec)\") — aborting so cells are not mislabeled"
                break measurement
            }
            // Absorb the cold model load after the restart so it doesn't
            // pollute the first uncached TTFT sample (same warm-up as
            // --tune-prefill).
            _ = try? await measureOnce(
                base: base, model: model,
                prompt: makePrompt(targetTokens: 256, nonce: "kv-warm-\(UUID().uuidString)"),
                maxTokens: 8)

            var scenarios: [[String: Any]] = []
            for target in options.promptTokens {
                var uncached: [Sample] = []
                var cached: [Sample] = []
                for run in 0..<options.runs {
                    // Unique-nonce prompt then identical resend, exactly like
                    // the main bench path: first request cannot hit the prefix
                    // cache, the resend measures the cache-hit path.
                    let prompt = makePrompt(
                        targetTokens: target, nonce: "kv-\(codec)-run\(run)-\(UUID().uuidString)")
                    do {
                        let first = try await measureOnce(
                            base: base, model: model, prompt: prompt, maxTokens: options.maxTokens)
                        let second = try await measureOnce(
                            base: base, model: model, prompt: prompt, maxTokens: options.maxTokens)
                        uncached.append(first)
                        cached.append(second)
                        fputs(
                            String(
                                format:
                                    "[%@] prompt≈%d run %d: uncached TTFT %.0f ms → cached %.0f ms, decode %.1f tok/s\n",
                                codec, target, run + 1, first.ttftMs, second.ttftMs,
                                first.decodeTps),
                            stderr)
                    } catch {
                        fatal =
                            "[\(codec)] prompt≈\(target) run \(run + 1) failed: \(error.localizedDescription)"
                        break measurement
                    }
                }
                guard uncached.count == options.runs, cached.count == options.runs else {
                    fatal =
                        "[\(codec)] prompt≈\(target) produced an incomplete sample set; no evidence report was emitted"
                    break measurement
                }
                let lowConfidence = kvMatrixIsLowConfidence(
                    completionTokens: (uncached + cached).map { $0.completionTokens })
                scenarios.append([
                    "target_prompt_tokens": target,
                    "actual_prompt_tokens": uncached.map { $0.promptTokens },
                    "completion_tokens": [
                        "uncached": uncached.map { $0.completionTokens },
                        "cached": cached.map { $0.completionTokens },
                    ],
                    "low_confidence": lowConfidence,
                    "uncached": summarize(uncached),
                    "cached": summarize(cached),
                ])
                cells.append(
                    KVMatrixCell(
                        codec: codec,
                        targetPromptTokens: target,
                        medianUncachedTTFTMs: median(uncached.map { $0.ttftMs }),
                        medianCachedTTFTMs: median(cached.map { $0.ttftMs }),
                        medianDecodeTps: median(uncached.map { $0.decodeTps }),
                        lowConfidence: lowConfidence))
            }
            codecBlocks.append(kvMatrixCodecBlock(codec: codec, scenarios: scenarios))
        }

        // Restore the user's config bytes unconditionally (defer-style: this
        // runs on the fatal paths above too), then restart once more so the
        // running server matches the restored on-disk settings again.
        if didMutateConfig {
            var restored = false
            if let lastWrittenData {
                do {
                    restored = try restoreKVMatrixConfig(
                        at: configURL,
                        expectedData: [lastWrittenData],
                        originalData: originalData)
                } catch {
                    let restoreFailure = "restore failed: \(error.localizedDescription)"
                    fatal = fatal.map { "\($0); \(restoreFailure)" } ?? restoreFailure
                }
            }
            if restored {
                fputs("Restored original \(configURL.lastPathComponent).\n", stderr)
            } else {
                let restoreFailure =
                    "server-runtime.json changed during the run; concurrent changes were preserved and the original bytes remain in \(backup.path)"
                if !((fatal ?? "").contains("restore failed")) {
                    fatal = fatal.map { "\($0); \(restoreFailure)" } ?? restoreFailure
                }
                fputs(
                    "Concurrent modification detected. Refusing to overwrite \(configURL.path). The current file was preserved; the pre-run bytes remain in \(backup.path).\n",
                    stderr)
            }
            // Disarm the signal-handler safety net; keep the sidecar backup
            // around when the restore failed (it is the recovery source).
            clearKVMatrixRestore()
            disarmKVMatrixSignalHandlers()
            if restored { try? FileManager.default.removeItem(at: backup) }
            if restored {
                if await restartServerForConfigReload(port: options.port) == false {
                    fatal = fatal
                        ?? "server did not come back healthy after restoring the original config"
                }
            } else {
                _ = await AppControl.terminateAppAndWait()
            }
        } else {
            // Nothing was mutated: just disarm the safety net.
            clearKVMatrixRestore()
            disarmKVMatrixSignalHandlers()
            try? FileManager.default.removeItem(at: backup)
        }

        if let fatal {
            fputs("KV matrix failed: \(fatal)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let measuredCodecs = Set(cells.map { $0.codec })
        guard measuredCodecs.count == kvMatrixCodecs.count else {
            fputs(
                "KV matrix incomplete: measured \(measuredCodecs.sorted()) of \(kvMatrixCodecs); no comparison possible.\n",
                stderr)
            exit(EXIT_FAILURE)
        }

        fputs("\n" + kvMatrixTableLines(cells).joined(separator: "\n") + "\n\n", stderr)

        let report: [String: Any] = [
            "schema": "osaurus-kv-matrix/1",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "model": model,
            "max_tokens": options.maxTokens,
            "runs": options.runs,
            "hardware": (health["hardware"] as? [String: Any]) ?? NSNull(),
            "codecs": codecBlocks,
            "methodology": [
                "sampling": "temperature 0 (greedy)",
                "token_counts": "server usage via stream_options.include_usage",
                "ttft": "request start → first non-empty content delta",
                "decode_tps": "(completion_tokens - 1) / (last delta - first delta)",
                "codec_application":
                    "cache.liveKVCodec written to server-runtime.json, full app restart per codec (the file is only read at launch), active setting verified after every restart, and original config restored afterwards",
                "codec_verified":
                    "always true in an emitted report; an unavailable endpoint, malformed response, or mismatch aborts the run",
                "low_confidence":
                    "cells with any sample below \(kvMatrixLowConfidenceCompletionTokens) completion_tokens are flagged low_confidence: the decode window is too short for a stable tok/s estimate",
                "context":
                    "per-family evidence for the fail-closed TurboQuant policy (2026-06-12): TurboQuant live KV is never auto-enabled and must win per family on measured numbers like these",
            ],
        ]
        emitReportAndExit(report, jsonPath: options.jsonPath)
    }

    /// Per-codec block of the JSON report. Pure so the codec_verified
    /// plumbing is unit-testable.
    static func kvMatrixCodecBlock(codec: String, scenarios: [[String: Any]]) -> [String: Any] {
        [
            "codec": codec,
            "description": kvMatrixCodecDescriptions[codec] ?? "",
            "codec_verified": true,
            "scenarios": scenarios,
        ]
    }

    /// Sidecar backup of the pre-run config, written before the first
    /// mutation and removed on clean completion — recovery source for
    /// SIGKILL (which no handler can catch) and for a failed restore.
    static func kvMatrixBackupURL(for configURL: URL) -> URL {
        URL(fileURLWithPath: configURL.path + ".kvmatrix-backup")
    }

    static func createKVMatrixBackup(_ data: Data, at backupURL: URL) throws {
        let temporaryURL = backupURL.deletingLastPathComponent().appendingPathComponent(
            ".\(backupURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        // Publishing with a hard link is atomic and fails when the recovery
        // path already exists; unlike Data's writing options, it supports
        // both guarantees together.
        try FileManager.default.linkItem(at: temporaryURL, to: backupURL)
    }

    struct KVMatrixRestoreState {
        let configURL: URL
        let originalData: Data
        let ownedData: [Data]
        let backup: URL
    }

    nonisolated(unsafe) static var kvMatrixRestore: KVMatrixRestoreState?
    private static let kvMatrixRestoreLock = NSLock()
    nonisolated(unsafe) static var kvMatrixSignalSources: [DispatchSourceSignal] = []

    static func armKVMatrixRestore(
        configURL: URL, originalData: Data, ownedData: [Data], backup: URL
    ) {
        kvMatrixRestoreLock.lock()
        kvMatrixRestore = KVMatrixRestoreState(
            configURL: configURL,
            originalData: originalData,
            ownedData: ownedData,
            backup: backup)
        kvMatrixRestoreLock.unlock()
    }

    @discardableResult
    static func clearKVMatrixRestore() -> KVMatrixRestoreState? {
        kvMatrixRestoreLock.lock()
        defer { kvMatrixRestoreLock.unlock() }
        let state = kvMatrixRestore
        kvMatrixRestore = nil
        return state
    }

    static func hasKVMatrixRestoreState() -> Bool {
        kvMatrixRestoreLock.lock()
        defer { kvMatrixRestoreLock.unlock() }
        return kvMatrixRestore != nil
    }

    static func installKVMatrixSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        kvMatrixSignalSources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                if BenchCommand.kvMatrixAbortRestore() {
                    _Exit(EXIT_FAILURE)
                }
            }
            source.resume()
            return source
        }
    }

    static func disarmKVMatrixSignalHandlers() {
        kvMatrixSignalSources.forEach { $0.cancel() }
        kvMatrixSignalSources = []
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    /// Restores the pre-run `server-runtime.json` bytes and removes the
    /// sidecar backup; prints the recovery blob (and keeps the backup) when
    /// the restore write fails. Called from the SIGINT/SIGTERM handlers;
    /// a no-op once the run has disarmed it.
    @discardableResult
    static func kvMatrixAbortRestore() -> Bool {
        guard let state = clearKVMatrixRestore() else { return false }
        do {
            if try restoreKVMatrixConfig(
                at: state.configURL,
                expectedData: state.ownedData,
                originalData: state.originalData) {
                try? FileManager.default.removeItem(at: state.backup)
                fputs(
                    "\nInterrupted — restored original \(state.configURL.lastPathComponent). The server may still be running a probe codec; restart it (`osaurus serve`) to reload the restored config.\n",
                    stderr)
            } else {
                fputs(
                    "\nInterrupted after a concurrent config edit. The current file was preserved; pre-run bytes remain in \(state.backup.path). Restart Osaurus to apply the current file.\n",
                    stderr)
            }
        } catch {
            fputs(
                "\nInterrupted — FAILED to restore \(state.configURL.path): \(error.localizedDescription)\nRestore it manually from \(state.backup.path) — original contents follow:\n\(String(bytes: state.originalData, encoding: .utf8) ?? "<binary>")\n",
                stderr)
        }
        return true
    }

    /// Restores only when the on-disk bytes are still owned by this run.
    /// Returning false preserves a concurrent writer's changes and keeps the
    /// sidecar backup available for manual reconciliation.
    static func restoreKVMatrixConfig(
        at configURL: URL, expectedData: [Data], originalData: Data
    ) throws -> Bool {
        let current = try Data(contentsOf: configURL)
        guard expectedData.contains(current) else { return false }
        try originalData.write(to: configURL, options: .atomic)
        guard try Data(contentsOf: configURL) == originalData else {
            throw KVMatrixError.restoreFailed("post-write byte verification failed")
        }
        return true
    }

    /// Replaces a probe config only if the file still contains the bytes this
    /// run last wrote. This catches settings-panel or process edits between
    /// codec cells instead of silently overwriting them.
    static func writeKVMatrixConfig(
        at configURL: URL, expectedData: Data, newData: Data
    ) throws -> Bool {
        guard try Data(contentsOf: configURL) == expectedData else { return false }
        try newData.write(to: configURL, options: .atomic)
        return try Data(contentsOf: configURL) == newData
    }

    /// The runtime settings file owned by the app's
    /// `ServerRuntimeSettingsStore` (OsaurusCore); the CLI edits the same
    /// JSON contract without linking OsaurusCore — mirrors `tuningFileURL()`.
    static func runtimeConfigFileURL() -> URL {
        Configuration.root()
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("server-runtime.json")
    }

    /// Returns `data` re-serialized with `cache.liveKVCodec` set to `codec`,
    /// leaving every other field untouched. Throws instead of inventing
    /// structure: a document without a `cache` object is not a runtime
    /// settings file, and writing a partial one could destroy user config.
    static func configData(settingLiveKVCodec codec: String, in data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KVMatrixError.malformedConfig("top level is not an object")
        }
        guard var cache = root["cache"] as? [String: Any] else {
            throw KVMatrixError.malformedConfig("no \"cache\" object")
        }
        cache["liveKVCodec"] = codec
        root["cache"] = cache
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func liveKVCodec(inConfigData data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = root["cache"] as? [String: Any]
        else { return nil }
        return cache["liveKVCodec"] as? String
    }

    static func kvMatrixIsLowConfidence(completionTokens: [Int]) -> Bool {
        completionTokens.contains { $0 < kvMatrixLowConfidenceCompletionTokens }
    }

    /// Stop notification → app termination → relaunch → serve notification →
    /// /health 200. A bare server stop/serve cycle is deliberately NOT used:
    /// the app never re-reads `server-runtime.json` after launch, so only a
    /// full app relaunch applies an on-disk codec edit (see
    /// `AppControl.terminateAppAndWait`).
    static func restartServerForConfigReload(port: Int) async -> Bool {
        AppControl.postDistributedNotification(
            name: "com.dinoki.osaurus.control.stop", userInfo: [:])
        // Let in-flight requests wind down before the app exits (Stop.swift's
        // stop-then-verify pattern, with a longer budget for model unload).
        let stopDeadline = Date().addingTimeInterval(10)
        while Date() < stopDeadline {
            if !(await ServerControl.checkHealth(port: port)) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard await AppControl.terminateAppAndWait() else { return false }
        await AppControl.launchAppIfNeeded()
        AppControl.postDistributedNotification(
            name: "com.dinoki.osaurus.control.serve", userInfo: [:])
        let start = Date()
        let deadline = start.addingTimeInterval(60)
        var reposted = false
        while Date() < deadline {
            if await ServerControl.checkHealth(port: port) { return true }
            // The app may miss the first signal while still initializing;
            // re-post once, like Serve.swift.
            if !reposted, Date().timeIntervalSince(start) > 3 {
                AppControl.postDistributedNotification(
                    name: "com.dinoki.osaurus.control.serve", userInfo: [:])
                reposted = true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Codec the running server actually applied (GET /admin/runtime-settings,
    /// the automation companion of the Server Settings panel). Nil when the
    /// endpoint is unavailable or malformed. The caller fails closed because
    /// an unverified codec label cannot be used as runtime evidence.
    static func activeLiveKVCodec(base: URL) async -> String? {
        guard let obj = await fetchJSON(base.appendingPathComponent("admin/runtime-settings")),
            let settings = obj["settings"] as? [String: Any],
            let cache = settings["cache"] as? [String: Any]
        else { return nil }
        return cache["liveKVCodec"] as? String
    }

    struct KVMatrixCell {
        let codec: String
        let targetPromptTokens: Int
        let medianUncachedTTFTMs: Double
        let medianCachedTTFTMs: Double
        let medianDecodeTps: Double
        let lowConfidence: Bool
    }

    /// Final medians table (stderr). Deltas are against the `engine_selected`
    /// baseline cell of the same prompt size — the comparison that decides
    /// whether TurboQuant earns a per-family allow-list entry.
    static func kvMatrixTableLines(_ cells: [KVMatrixCell]) -> [String] {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width
                ? text + " " : text + String(repeating: " ", count: width - text.count)
        }
        func delta(_ value: Double, _ baseline: Double?) -> String {
            guard let baseline, baseline > 0 else { return "" }
            return String(format: " (%+.0f%%)", (value - baseline) / baseline * 100)
        }
        var baselines: [Int: KVMatrixCell] = [:]
        for cell in cells where cell.codec == kvMatrixCodecs[0] {
            baselines[cell.targetPromptTokens] = cell
        }
        var lines = [
            pad("codec", 17) + pad("prompt", 8) + pad("uncached TTFT", 21) + pad("cached TTFT", 19)
                + "decode tok/s"
        ]
        for cell in cells {
            let baseline = cell.codec == kvMatrixCodecs[0]
                ? nil : baselines[cell.targetPromptTokens]
            let uncached =
                String(format: "%.0f ms", cell.medianUncachedTTFTMs)
                + delta(cell.medianUncachedTTFTMs, baseline?.medianUncachedTTFTMs)
            let cached =
                String(format: "%.0f ms", cell.medianCachedTTFTMs)
                + delta(cell.medianCachedTTFTMs, baseline?.medianCachedTTFTMs)
            var decode =
                String(format: "%.1f", cell.medianDecodeTps)
                + delta(cell.medianDecodeTps, baseline?.medianDecodeTps)
            if cell.lowConfidence { decode += " [low-confidence]" }
            lines.append(
                pad(cell.codec, 17) + pad(String(cell.targetPromptTokens), 8)
                    + pad(uncached, 21) + pad(cached, 19) + decode)
        }
        return lines
    }

    // MARK: - Single measurement

    struct Sample {
        let ttftMs: Double
        let decodeTps: Double
        let prefillTps: Double
        let promptTokens: Int
        let completionTokens: Int
    }

    enum BenchError: LocalizedError {
        case http(Int)
        case noContent
        case noUsage

        var errorDescription: String? {
            switch self {
            case .http(let code): return "HTTP \(code)"
            case .noContent: return "stream produced no content deltas"
            case .noUsage: return "final chunk carried no usage (older server?)"
            }
        }
    }

    static func measureOnce(
        base: URL, model: String, prompt: String, maxTokens: Int
    ) async throws -> Sample {
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ])

        let start = DispatchTime.now()
        var firstDelta: DispatchTime?
        var lastDelta: DispatchTime?
        var usage: (prompt: Int, completion: Int)?

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BenchError.http(http.statusCode)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }  // skips ": ping" keepalives
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard
                let obj = try? JSONSerialization.jsonObject(
                    with: Data(payload.utf8)) as? [String: Any]
            else { continue }

            if let u = obj["usage"] as? [String: Any],
                let promptTokens = u["prompt_tokens"] as? Int,
                let completionTokens = u["completion_tokens"] as? Int {
                usage = (promptTokens, completionTokens)
            }
            // Reasoning models stream `reasoning_content` deltas (often for
            // hundreds of tokens) before any `content` delta — and a short
            // max_tokens run can be reasoning-only. Both delta kinds are
            // generated tokens, so both count for TTFT and the decode window.
            if let choices = obj["choices"] as? [[String: Any]],
                let delta = choices.first?["delta"] as? [String: Any] {
                let content = delta["content"] as? String
                let reasoning = delta["reasoning_content"] as? String
                if (content?.isEmpty == false) || (reasoning?.isEmpty == false) {
                    let now = DispatchTime.now()
                    if firstDelta == nil { firstDelta = now }
                    lastDelta = now
                }
            }
        }

        guard let first = firstDelta, let last = lastDelta else { throw BenchError.noContent }
        guard let usage else { throw BenchError.noUsage }

        let ttftMs = ms(from: start, to: first)
        let decodeSeconds = ms(from: first, to: last) / 1_000
        // One token arrived *at* `first`, so the interval covers n-1 tokens.
        let decodeTps =
            decodeSeconds > 0 ? Double(usage.completion - 1) / decodeSeconds : 0
        let prefillTps = ttftMs > 0 ? Double(usage.prompt) / (ttftMs / 1_000) : 0
        return Sample(
            ttftMs: ttftMs,
            decodeTps: decodeTps,
            prefillTps: prefillTps,
            promptTokens: usage.prompt,
            completionTokens: usage.completion
        )
    }

    // MARK: - Helpers

    /// Deterministic filler prose sized to roughly `targetTokens` (the exact
    /// count is model-tokenizer-dependent; the report records the server's
    /// actual `prompt_tokens`). The nonce leads the prompt so no prefix-cache
    /// block from a previous run can match.
    static func makePrompt(targetTokens: Int, nonce: String) -> String {
        let sentence =
            "The quick brown fox jumps over the lazy dog while the observer takes careful notes about latency. "
        // ~4 chars/token is the standard rough conversion for English prose.
        let targetChars = targetTokens * 4
        var body = "[\(nonce)] Please summarize the following text in one short sentence.\n\n"
        while body.count < targetChars {
            body += sentence
        }
        return body
    }

    static func summarize(_ samples: [Sample]) -> [String: Any] {
        [
            "ttft_ms": ["median": median(samples.map { $0.ttftMs }), "samples": samples.map { $0.ttftMs }],
            "decode_tps": ["median": median(samples.map { $0.decodeTps }), "samples": samples.map { $0.decodeTps }],
            "prefill_tps": ["median": median(samples.map { $0.prefillTps }), "samples": samples.map { $0.prefillTps }],
        ]
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func ms(from: DispatchTime, to: DispatchTime) -> Double {
        Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func defaultModel(base: URL) async -> String? {
        guard let obj = await fetchJSON(base.appendingPathComponent("v1/models")),
            let data = obj["data"] as? [[String: Any]]
        else { return nil }
        return data.first?["id"] as? String
    }

    // MARK: - Argument parsing

    static func parseOptions(_ args: [String]) -> Options? {
        var options = Options(port: Configuration.resolveConfiguredPort() ?? 1337)
        var index = 0
        while index < args.count {
            let arg = args[index]
            func value() -> String? {
                index += 1
                return index < args.count ? args[index] : nil
            }
            switch arg {
            case "--model":
                guard let v = value() else { return nil }
                options.model = v
            case "--prompt-tokens":
                guard let v = value() else { return nil }
                let parsed = v.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
                guard !parsed.isEmpty else { return nil }
                options.promptTokens = parsed
                options.promptTokensExplicit = true
            case "--max-tokens":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                options.maxTokens = n
            case "--runs":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                options.runs = n
                options.runsExplicit = true
            case "--json":
                guard let v = value() else { return nil }
                options.jsonPath = v
            case "--port":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                options.port = n
            case "--tune-prefill":
                options.tunePrefill = true
            case "--kv-matrix":
                options.kvMatrix = true
            case "--candidates":
                guard let v = value() else { return nil }
                let parsed = v.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
                guard !parsed.isEmpty else { return nil }
                options.tuneCandidates = parsed
            default:
                fputs("Unknown option: \(arg)\n", stderr)
                return nil
            }
            index += 1
        }
        if options.tunePrefill && options.kvMatrix {
            fputs("--tune-prefill and --kv-matrix are mutually exclusive.\n", stderr)
            return nil
        }
        return options
    }

    private static func printUsage() {
        fputs(
            """
            Usage: osaurus bench [--model <id>] [--prompt-tokens 1024,8192]
                                 [--max-tokens 128] [--runs 3] [--json <path>] [--port N]
                   osaurus bench --tune-prefill [--model <id>] [--candidates 512,1024,2048,4096]
                                 [--prompt-tokens 8192] [--runs 3]
                   osaurus bench --kv-matrix [--model <id>] [--prompt-tokens 8192,32768]
                                 [--runs 2] [--json <path>]

            Requires a running server (`osaurus serve`). Reports uncached/cached
            TTFT, prefill tok/s, and decode tok/s per prompt size as JSON.

            --tune-prefill measures the model's TTFT at each candidate prefill
            step size and persists the per-model winner (the optimum is
            model-architecture-dependent); the server applies it immediately.

            --kv-matrix measures engine-selected vs TurboQuant live-KV
            per prompt size: uncached/cached TTFT and decode tok/s. It edits
            cache.liveKVCodec in server-runtime.json and restarts the app per
            codec (the file is only read at launch); the original config is
            always restored. Measurement only — it changes no defaults.

            """, stderr)
    }
}
