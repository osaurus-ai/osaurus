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

    struct Options {
        var model: String?
        var promptTokens: [Int] = BenchCommand.defaultPromptTokens
        var maxTokens: Int = BenchCommand.defaultMaxTokens
        var runs: Int = BenchCommand.defaultRuns
        var jsonPath: String?
        var port: Int
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

            Requires a running server (`osaurus serve`). Reports uncached/cached
            TTFT, prefill tok/s, and decode tok/s per prompt size as JSON.

            """, stderr)
    }
}
