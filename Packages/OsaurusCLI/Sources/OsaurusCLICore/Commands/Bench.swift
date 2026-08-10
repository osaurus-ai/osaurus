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

    struct Options {
        var model: String?
        var promptTokens: [Int] = BenchCommand.defaultPromptTokens
        var maxTokens: Int = BenchCommand.defaultMaxTokens
        var runs: Int = BenchCommand.defaultRuns
        var jsonPath: String?
        var port: Int
        var tunePrefill: Bool = false
        var tuneCandidates: [Int] = BenchCommand.defaultTuneCandidates
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

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        } catch {
            fputs("Failed to encode report: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
        if let path = options.jsonPath {
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
            case "--max-tokens":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                options.maxTokens = n
            case "--runs":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                options.runs = n
            case "--json":
                guard let v = value() else { return nil }
                options.jsonPath = v
            case "--port":
                guard let v = value(), let n = Int(v), n > 0 else { return nil }
                options.port = n
            case "--tune-prefill":
                options.tunePrefill = true
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
        return options
    }

    private static func printUsage() {
        fputs(
            """
            Usage: osaurus bench [--model <id>] [--prompt-tokens 1024,8192]
                                 [--max-tokens 128] [--runs 3] [--json <path>] [--port N]
                   osaurus bench --tune-prefill [--model <id>] [--candidates 512,1024,2048,4096]
                                 [--prompt-tokens 8192] [--runs 3]

            Requires a running server (`osaurus serve`). Reports uncached/cached
            TTFT, prefill tok/s, and decode tok/s per prompt size as JSON.

            --tune-prefill measures the model's TTFT at each candidate prefill
            step size and persists the per-model winner (the optimum is
            model-architecture-dependent); the server applies it immediately.

            """, stderr)
    }
}
