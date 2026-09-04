//
//  BenchGauntlet.swift
//  osaurus
//
//  `osaurus bench --gauntlet` — onboarding verification suite. Where plain
//  `bench` answers "how fast", the gauntlet answers "is this model fit to
//  serve": it runs measured probes against the live server (load,
//  template-token leakage, tool calling, stop sequences, long-generation
//  degeneration, native-MTP output equivalence, and a perf snapshot) and
//  merge-writes one record per model into the capability ledger
//  (~/.osaurus/config/model-ledger.json) that `ModelCapabilityLedger` in
//  OsaurusCore consults. Like the prefill-tuning writer, the CLI mirrors the
//  ledger's JSON contract instead of linking OsaurusCore.
//
//  Verdict policy (v1): probes and evidence are recorded, but the CLI does
//  not mutate `productionServing`. A promotion must eventually be bound to a
//  weights digest that the runtime can verify; otherwise a re-quant under the
//  same name could inherit stale evidence. Existing safety verdicts and
//  unknown ledger fields are preserved by a field-level merge.
//

import CryptoKit
import Foundation

extension BenchCommand {

    // MARK: - Probe outcome

    struct ProbeOutcome {
        let verdict: String  // "pass" | "fail" | "untested" (ModelCapabilityLedger.Verdict raw values)
        let evidence: String

        static func pass(_ evidence: String) -> ProbeOutcome {
            ProbeOutcome(verdict: "pass", evidence: evidence)
        }
        static func fail(_ evidence: String) -> ProbeOutcome {
            ProbeOutcome(verdict: "fail", evidence: evidence)
        }
        static func untested(_ evidence: String) -> ProbeOutcome {
            ProbeOutcome(verdict: "untested", evidence: evidence)
        }
    }

    /// Probes whose collective pass makes the report a production-serving
    /// candidate. V1 records evidence but does not mutate the runtime ledger
    /// verdict. tool-call and mtp-equivalence are deliberately excluded:
    /// text-only models legitimately reject tools, and non-MTP bundles are
    /// legitimately untestable for equivalence.
    static let gauntletCriticalProbes = [
        "load", "template-leak", "stop-sequence", "degeneration-canary",
    ]

    // MARK: - Suite runner

    static func runGauntlet(
        options: Options, model: String, base: URL, health: [String: Any]
    ) async -> Never {
        fputs("Gauntlet: verifying \(model) against \(base.absoluteString)…\n", stderr)

        var probes: [String: String] = [:]
        var evidence: [String: String] = [:]
        func record(_ index: Int, _ name: String, _ outcome: ProbeOutcome) {
            probes[name] = outcome.verdict
            evidence[name] = outcome.evidence
            fputs("  [\(index)/7] \(name): \(outcome.verdict) — \(outcome.evidence)\n", stderr)
        }

        record(1, "load", await probeLoad(base: base, model: model))
        record(2, "template-leak", await probeTemplateLeak(base: base, model: model))
        record(3, "tool-call", await probeToolCall(base: base, model: model))
        record(4, "stop-sequence", await probeStopSequence(base: base, model: model))
        record(5, "degeneration-canary", await probeDegenerationCanary(base: base, model: model))
        // After probe 1 the model is resident, so /health now reflects its
        // actual draft strategy — the equivalence probe re-reads it.
        record(6, "mtp-equivalence", await probeMTPEquivalence(base: base, model: model))

        // Perf snapshot carries no verdict: numbers are evidence for humans
        // and future calibrated gates, not a pass/fail policy in v1.
        let perf = await perfSnapshotEvidence(base: base, model: model, options: options)
        evidence["perf"] = perf
        fputs("  [7/7] perf: \(perf)\n", stderr)

        let allCriticalPass = gauntletCriticalProbes.allSatisfy { probes[$0] == "pass" }
        let ledgerRecord = GauntletLedgerRecord(
            productionServing: nil,
            source: "gauntlet",
            chip: (health["hardware"] as? [String: Any])?["chip"] as? String,
            measuredAt: ISO8601DateFormatter().string(from: Date()),
            probes: probes,
            evidence: evidence
        )
        let ledgerURL = ledgerFileURL()
        let ledgerKey = ledgerNormalize(model)
        do {
            try writeLedgerRecord(at: ledgerURL, modelKey: ledgerKey, record: ledgerRecord)
        } catch {
            fputs("Failed to write \(ledgerURL.path): \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
        if allCriticalPass {
            fputs(
                "All critical probes passed — recorded candidate evidence for \(ledgerKey) in \(ledgerURL.path). Production promotion remains unchanged until the evidence can be bound to a weights digest.\n",
                stderr)
        } else {
            let notPassing = gauntletCriticalProbes
                .filter { probes[$0] != "pass" }
                .map { "\($0)=\(probes[$0] ?? "missing")" }
                .joined(separator: ", ")
            fputs(
                "Critical probe(s) not passing (\(notPassing)) — recorded probe results for \(ledgerKey) in \(ledgerURL.path) without a productionServing verdict (v1 never auto-writes fail).\n",
                stderr)
        }

        let report: [String: Any] = [
            "schema": "osaurus-gauntlet/1",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "model": model,
            "hardware": (health["hardware"] as? [String: Any]) ?? NSNull(),
            "probes": probes,
            "evidence": evidence,
            "production_serving_candidate": allCriticalPass ? "pass" : NSNull(),
            "production_serving_recorded": NSNull(),
            "ledger_path": ledgerURL.path,
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
        exit(allCriticalPass ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    // MARK: - Probe 1: load

    static func probeLoad(base: URL, model: String) async -> ProbeOutcome {
        do {
            let chat = try await gauntletChat(
                base: base, model: model,
                prompt: "Reply with the single word: ready.",
                maxTokens: 32)
            guard !(chat.content + chat.reasoning).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .fail("model returned an empty transcript for a trivial request")
            }
            return .pass("model returned a non-empty streamed response")
        } catch {
            return .fail("model did not answer a trivial request: \(error.localizedDescription)")
        }
    }

    // MARK: - Probe 2: template-leak

    /// Special tokens that must never surface in user-visible channels: chat
    /// template markers (`<|im_start|>`/`<|im_end|>`, `〈|EOS|〉`), thinking
    /// tags the server should have routed to `reasoning_content`, tool-call
    /// markers (`<tool_call>`, the `]~!b[`/`[e~[` JANG framing), and the
    /// U+FFFE in-band sentinel the SSE writer must always peel off.
    static let templateLeakTokens: [String] = [
        "<|im_start|>", "<|im_end|>", "〈|EOS|〉", "<think>", "</think>",
        "<tool_call>", "]~!b[", "[e~[", "<start_of_turn>", "<end_of_turn>",
        "<|eot_id|>", "<|start_header_id|>", "<|end_header_id|>", "<|end|>",
        "<|endoftext|>", "\u{FFFE}",
    ]

    static let gauntletMinLeakTranscriptChars = 1

    static func templateLeakVerdict(content: String, reasoning: String) -> ProbeOutcome {
        let transcript = reasoning + content
        guard transcript.count >= gauntletMinLeakTranscriptChars else {
            return .untested("empty transcript cannot prove template-token isolation")
        }
        for (channel, text) in [("content", content), ("reasoning", reasoning)] {
            if let leaked = templateLeakTokens.first(where: { text.contains($0) }) {
                return .fail(
                    "special token \(printableLeakToken(leaked)) leaked into streamed \(channel)")
            }
        }
        return .pass("non-empty transcript contains no known special-token markers")
    }

    static func probeTemplateLeak(base: URL, model: String) async -> ProbeOutcome {
        let prompts = [
            "Say hello in one short sentence.",
            "What is 2 + 2? Reply with just the number.",
            "Name the capital of France in one word.",
        ]
        for prompt in prompts {
            let chat: GauntletChat
            do {
                chat = try await gauntletChat(
                    base: base, model: model, prompt: prompt, maxTokens: 200)
            } catch {
                // A chat that fails outright proves nothing about leakage.
                return .untested("chat failed before leak scan: \(error.localizedDescription)")
            }
            let verdict = templateLeakVerdict(content: chat.content, reasoning: chat.reasoning)
            if verdict.verdict != "pass" {
                return verdict
            }
        }
        return .pass(
            "no special-token leakage across \(prompts.count) greedy chats (\(templateLeakTokens.count) markers scanned)")
    }

    private static func printableLeakToken(_ token: String) -> String {
        token == "\u{FFFE}" ? "U+FFFE sentinel" : "\"\(token)\""
    }

    // MARK: - Probe 3: tool-call

    static func probeToolCall(base: URL, model: String) async -> ProbeOutcome {
        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get the current weather for a location.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "location": [
                            "type": "string",
                            "description": "City name, e.g. Paris",
                        ]
                    ],
                    "required": ["location"],
                ],
            ],
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "What is the weather in Paris right now?"]],
            "temperature": 0,
            "max_tokens": 512,
            "stream": false,
            "tools": [tool],
            "tool_choice": ["type": "function", "function": ["name": "get_weather"]],
        ]
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard status == 200 else {
                let message = serverErrorMessage(obj) ?? "HTTP \(status)"
                if status == 400 {
                    // Runtime policy (e.g. "tool calling as unsupported")
                    // rejects the request before the model runs, so it says
                    // nothing about the model's actual tool behavior.
                    return .untested("server rejected tools for this model: \(message)")
                }
                return .fail("tools request failed: HTTP \(status): \(message)")
            }
            let choice = (obj?["choices"] as? [[String: Any]])?.first
            guard
                let message = choice?["message"] as? [String: Any],
                let toolCalls = message["tool_calls"] as? [[String: Any]],
                let function = toolCalls.first?["function"] as? [String: Any],
                let name = function["name"] as? String,
                let arguments = function["arguments"] as? String
            else {
                let finish = choice?["finish_reason"] as? String ?? "?"
                return .fail("no tool_calls entry in response (finish_reason=\(finish))")
            }
            guard name == "get_weather" else {
                return .fail("tool_calls returned unexpected function \(name)")
            }
            guard
                let decoded = try? JSONSerialization.jsonObject(with: Data(arguments.utf8))
                    as? [String: Any],
                let location = decoded["location"] as? String,
                !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .fail(
                    "tool_calls arguments do not contain a non-empty string location: \(String(arguments.prefix(120)))")
            }
            return .pass(
                "forced tool call returned \(name)(\(String(arguments.prefix(120)))) with parseable JSON arguments")
        } catch {
            return .fail("tools request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Probe 4: stop-sequence

    static func probeStopSequence(base: URL, model: String) async -> ProbeOutcome {
        do {
            let prompt = "Output exactly ALPHA<<GAUNTLET_STOP>>OMEGA with no other text."
            let control = try await gauntletChat(
                base: base, model: model, prompt: prompt, maxTokens: 64)
            guard control.content.contains("ALPHA<<GAUNTLET_STOP>>OMEGA") else {
                return .untested("control run did not emit the requested stop boundary")
            }
            let chat = try await gauntletChat(
                base: base, model: model,
                prompt: prompt, maxTokens: 64, stop: ["<<GAUNTLET_STOP>>"])
            return stopSequenceVerdict(content: chat.content, finishReason: chat.finishReason)
        } catch {
            return .fail("stop-sequence request failed: \(error.localizedDescription)")
        }
    }

    /// Pure verdict for the stopped half of the probe. The caller first proves
    /// the model can emit `ALPHA<<GAUNTLET_STOP>>OMEGA` without a stop. A pass
    /// then requires exact pre-boundary text, no marker/OMEGA leakage, and a
    /// stop finish reason. Other model output is `untested`, not false proof.
    static func stopSequenceVerdict(content: String, finishReason: String?) -> ProbeOutcome {
        let finish = finishReason ?? "none"
        if content.contains("<<GAUNTLET_STOP>>") {
            return .fail(
                "stop sequence leaked into content (finish_reason=\(finish))")
        }
        if content.contains("OMEGA") {
            return .fail("content continued past the stop boundary (finish_reason=\(finish))")
        }
        guard content.trimmingCharacters(in: .whitespacesAndNewlines) == "ALPHA" else {
            return .untested("stopped run did not produce the exact pre-boundary text")
        }
        guard finish == "stop" else {
            return .fail("finish_reason=\(finish) is not stop-related")
        }
        return .pass(
            "control emitted the full boundary and stopped run emitted only ALPHA (finish_reason=stop)")
    }

    // MARK: - Probe 5: degeneration-canary

    static func probeDegenerationCanary(base: URL, model: String) async -> ProbeOutcome {
        do {
            let chat = try await gauntletChat(
                base: base, model: model,
                prompt:
                    "Think carefully step by step: explain why the sky is blue, then critique your own explanation.",
                maxTokens: 1_024)
            // Loops routinely start inside the thinking channel, so the
            // detector sees the full transcript, not just `content`.
            let full = chat.reasoning.isEmpty ? chat.content : chat.reasoning + "\n" + chat.content
            return degenerationCanaryVerdict(transcript: full)
        } catch {
            return .fail("canary generation failed: \(error.localizedDescription)")
        }
    }

    /// Below this many transcript characters the canary has not observed
    /// enough generation to certify "no runaway repetition" — a 0-char run
    /// must not pass on vacuous evidence.
    static let gauntletMinCanaryTranscriptChars = 256

    /// Pure verdict for the degeneration canary. A detector hit is a fail on
    /// any transcript length (repetition observed is repetition observed);
    /// a clean short/empty transcript is `untested`, not pass.
    static func degenerationCanaryVerdict(transcript: String) -> ProbeOutcome {
        if let hit = DegenerationDetector.detect(in: transcript) {
            return .fail(hit)
        }
        guard transcript.count >= gauntletMinCanaryTranscriptChars else {
            return .untested(
                "transcript too short to judge degeneration (\(transcript.count) chars, need ≥\(gauntletMinCanaryTranscriptChars))")
        }
        return .pass("no runaway repetition in \(transcript.count) generated characters")
    }

    // MARK: - Probe 6: mtp-equivalence

    /// Native MTP (self-speculative decode) must be output-lossless: greedy
    /// text through the MTP path must be byte-identical to the plain
    /// autoregressive path, otherwise the speedup is silently changing
    /// answers. Only testable when the model actually loaded with a
    /// `native_mtp*` draft strategy (visible in /health after probe 1).
    static func probeMTPEquivalence(base: URL, model: String) async -> ProbeOutcome {
        guard let health = await fetchJSON(base.appendingPathComponent("health")),
            let resident = health["resident_models"] as? [[String: Any]]
        else {
            return .untested("could not read resident_models from /health")
        }
        let key = ledgerNormalize(model)
        let row = resident.first { ledgerNormalize(($0["name"] as? String) ?? "") == key }
        guard let strategy = row?["draft_strategy"] as? String, strategy.hasPrefix("native_mtp")
        else {
            let observed = row?["draft_strategy"] as? String ?? "none"
            return .untested(
                "model is not serving with a native MTP draft strategy (draft_strategy=\(observed))")
        }

        // Identical prompt for both runs (greedy decode output does not
        // depend on prefix-cache hits), long enough to clear the runtime's
        // tiny-prompt AR fallback (24 tokens).
        let prompt = makePrompt(targetTokens: 256, nonce: "gauntlet-mtp-equivalence")
        do {
            // Pure explicit greedy: the only sampling shape the runtime lets
            // native MTP serve.
            let mtp = try await gauntletChat(
                base: base, model: model, prompt: prompt, maxTokens: 256)
            // Forced AR with identical decoding: `top_k: 1` fails
            // MLXBatchAdapter.requestSamplingIsExplicitGreedy, so the runtime
            // drops the draft strategy (fallback reason "explicit_sampling"),
            // and at temperature 0 vmlx's sampler() is ArgMaxSampler, which
            // ignores topK — the knob forces the AR path and is then dropped,
            // so decoding is identical greedy. (A nonzero frequency_penalty
            // would also force AR — vmlx's canUseNativeMTP rejects it — but
            // it is NOT dropped: vmlx builds a FrequencyPenaltyContext that
            // perturbs logits, so a hash mismatch could be the penalty
            // instead of MTP.)
            let ar = try await gauntletChat(
                base: base, model: model, prompt: prompt, maxTokens: 256,
                extraParameters: ["top_k": 1])
            // Empty (or near-empty) transcripts hash identically without
            // proving anything: ""=="" is not equivalence evidence.
            if let short = mtpEquivalenceTranscriptGuard(
                mtpCompletionTokens: mtp.completionTokens,
                arCompletionTokens: ar.completionTokens) {
                return short
            }
            let mtpHash = transcriptHash(mtp)
            let arHash = transcriptHash(ar)
            guard mtpHash == arHash else {
                return .fail(
                    "\(strategy) greedy output diverges from forced-AR (mtp sha256 \(mtpHash.prefix(12)) vs ar \(arHash.prefix(12)))")
            }
            return .untested(
                "\(strategy) output matched forced-AR (sha256 \(mtpHash.prefix(12))), but per-request MTP telemetry is unavailable so active MTP use is unproven")
        } catch {
            return .untested("equivalence runs failed: \(error.localizedDescription)")
        }
    }

    /// Equivalence needs at least this many completion tokens from BOTH runs
    /// before matching hashes count as evidence.
    static let gauntletMinEquivalenceCompletionTokens = 16

    /// Pure guard for the mtp-equivalence probe: returns the `untested`
    /// outcome when either transcript is too short to compare, nil when the
    /// hash comparison may proceed.
    static func mtpEquivalenceTranscriptGuard(
        mtpCompletionTokens: Int?, arCompletionTokens: Int?
    ) -> ProbeOutcome? {
        let mtpTokens = mtpCompletionTokens ?? 0
        let arTokens = arCompletionTokens ?? 0
        guard mtpTokens >= gauntletMinEquivalenceCompletionTokens,
            arTokens >= gauntletMinEquivalenceCompletionTokens
        else {
            return .untested(
                "empty transcript: equivalence needs ≥\(gauntletMinEquivalenceCompletionTokens) completion tokens from both runs (mtp \(mtpTokens), ar \(arTokens))")
        }
        return nil
    }

    /// sha256 over (reasoning + NUL + content): the separator keeps
    /// "reasoning boundary moved" distinguishable from "same bytes".
    static func transcriptHash(_ chat: GauntletChat) -> String {
        let digest = SHA256.hash(data: Data((chat.reasoning + "\u{0000}" + chat.content).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Probe 7: perf snapshot (evidence only)

    static func perfSnapshotEvidence(
        base: URL, model: String, options: Options
    ) async -> String {
        var parts: [String] = []
        for target in [1_024, 8_192] {
            // Unique prefix → uncached prefill; identical re-send → cached.
            let prompt = makePrompt(
                targetTokens: target, nonce: "gauntlet-perf-\(target)-\(UUID().uuidString)")
            do {
                let uncached = try await measureOnce(
                    base: base, model: model, prompt: prompt, maxTokens: options.maxTokens)
                let cached = try await measureOnce(
                    base: base, model: model, prompt: prompt, maxTokens: options.maxTokens)
                parts.append(
                    String(
                        format: "%dK: uncached TTFT %.0f ms, cached TTFT %.0f ms, decode %.1f tok/s",
                        target / 1_024, uncached.ttftMs, cached.ttftMs, uncached.decodeTps))
            } catch {
                parts.append("\(target / 1_024)K: failed (\(error.localizedDescription))")
            }
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Streaming chat helper

    struct GauntletChat {
        var content = ""
        var reasoning = ""
        var finishReason: String?
        /// Server-reported completion tokens (`stream_options.include_usage`);
        /// nil on older servers whose final chunk carries no usage.
        var completionTokens: Int?
    }

    enum GauntletError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return "HTTP \(code): \(message)"
            }
        }
    }

    /// One greedy streamed chat, returning the full text of both channels
    /// and the final finish_reason. Unlike `measureOnce` this keeps the
    /// bytes (the gauntlet inspects text, not timing).
    static func gauntletChat(
        base: URL, model: String, prompt: String, maxTokens: Int,
        stop: [String]? = nil, extraParameters: [String: Any] = [:]
    ) async throws -> GauntletChat {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let stop { body["stop"] = stop }
        for (key, value) in extraParameters { body[key] = value }

        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var bodyText = ""
            for try await line in bytes.lines where bodyText.count < 4_096 {
                bodyText += line
            }
            let obj = try? JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any]
            throw GauntletError.http(http.statusCode, serverErrorMessage(obj) ?? bodyText)
        }

        var result = GauntletChat()
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }  // skips ": ping" keepalives
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard
                let obj = try? JSONSerialization.jsonObject(
                    with: Data(payload.utf8)) as? [String: Any]
            else { continue }
            // The usage chunk arrives with an empty `choices` array, so it
            // must be read before the choice guard below.
            if let usage = obj["usage"] as? [String: Any],
                let completionTokens = usage["completion_tokens"] as? Int {
                result.completionTokens = completionTokens
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any] {
                if let piece = delta["content"] as? String { result.content += piece }
                if let piece = delta["reasoning_content"] as? String { result.reasoning += piece }
            }
            if let finish = choice["finish_reason"] as? String { result.finishReason = finish }
        }
        return result
    }

    /// Extracts `error.message` from an OpenAI-style error body.
    static func serverErrorMessage(_ obj: [String: Any]?) -> String? {
        ((obj?["error"] as? [String: Any])?["message"] as? String)
    }

    // MARK: - Ledger write (CLI-side mirror of ModelCapabilityLedger)

    /// CLI-side mirror of `ModelCapabilityLedger.Record` (OsaurusCore),
    /// written without linking OsaurusCore — exactly like the prefill-tuning
    /// helpers mirror `ModelPrefillTuningStore`. `probes` (verdict map) and
    /// `evidence` are gauntlet-added fields; the server-side decoder ignores
    /// keys it does not know, so the contract stays one-directional.
    struct GauntletLedgerRecord: Codable {
        /// Reserved for a future digest-bound promotion path. Gauntlet v1
        /// leaves this absent and preserves any existing ledger verdict.
        var productionServing: String?
        var source: String
        var chip: String?
        var measuredAt: String
        var probes: [String: String]
        var evidence: [String: String]
    }

    /// The server-side reader is `ModelCapabilityLedger` (OsaurusCore).
    static func ledgerFileURL() -> URL {
        Configuration.root()
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("model-ledger.json")
    }

    /// Same normalization as `ModelCapabilityLedger.normalize` so the
    /// server's exact-key lookup finds gauntlet-written records.
    static func ledgerNormalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    /// Field-merges one record under the normalized key. Unknown fields and
    /// an existing production verdict/block reason survive a gauntlet run;
    /// evidence collection must never silently remove a safety decision.
    static func writeLedgerRecord(
        at url: URL, modelKey: String, record: GauntletLedgerRecord
    ) throws {
        var records: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            records = existing
        }
        let encoded = try JSONEncoder().encode(record)
        let update = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        var modelRecord = records[modelKey] as? [String: Any] ?? [:]
        for (key, value) in update where key != "productionServing" {
            modelRecord[key] = value
        }
        if let verdict = record.productionServing {
            modelRecord["productionServing"] = verdict
        }
        records[modelKey] = modelRecord
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
