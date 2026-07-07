//
//  ModelVerificationLedgerTests.swift
//  osaurus
//
//  Ledger-write merge semantics on a temp file, key normalization, and the
//  vendored template-leak token scan.
//

import Foundation
import Testing

@testable import OsaurusCore

private let passingOutcome = VerificationProbeOutcome(
    loadVerdict: .pass,
    loadEvidence: "loaded and generated 8-token greedy sample in 12.3s",
    templateLeakVerdict: .pass,
    templateLeakEvidence: "no template control tokens in 8-token greedy sample",
    elapsedSeconds: 12.3
)

private func tempLedgerURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-ledger-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("model-ledger.json")
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(parsed != nil)
    return parsed ?? [:]
}

struct ModelVerificationLedgerTests {

    @Test func creates_fresh_ledger_when_file_absent() throws {
        let url = tempLedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ModelVerificationLedger.recordAutorunProbes(
            modelName: "Qwen3-4B-Instruct",
            outcome: passingOutcome,
            chip: "Apple M3 Pro",
            fileURL: url
        )

        let root = try readJSON(url)
        #expect(root["version"] as? Int == 1)
        let models = root["models"] as? [String: Any]
        let record = models?["qwen3_4b_instruct"] as? [String: Any]
        #expect(record != nil)
        #expect(record?["displayName"] as? String == "Qwen3-4B-Instruct")
        #expect(record?["chip"] as? String == "Apple M3 Pro")
        #expect(record?["productionServing"] == nil)

        let probes = record?["probes"] as? [String: Any]
        let load = probes?["load"] as? [String: Any]
        #expect(load?["verdict"] as? String == "pass")
        #expect(load?["source"] as? String == "autorun")
        #expect(load?["evidence"] as? String == passingOutcome.loadEvidence)
        let leak = probes?["templateLeak"] as? [String: Any]
        #expect(leak?["verdict"] as? String == "pass")
        #expect(leak?["source"] as? String == "autorun")
    }

    @Test func merge_preserves_foreign_records_probes_and_serving_gate() throws {
        let url = tempLedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Seed a ledger as another writer (the gauntlet CLI) would have left
        // it: a foreign top-level field, a foreign model record, and — on the
        // model autorun is about to update — a serving verdict, a foreign
        // probe, and an unknown field.
        let seeded: [String: Any] = [
            "version": 3,
            "generatedBy": "osaurus verify 0.1",
            "models": [
                "other_model": [
                    "displayName": "Other-Model",
                    "probes": ["load": ["verdict": "fail", "source": "gauntlet"]],
                    "productionServing": false,
                ],
                "qwen3_4b_instruct": [
                    "displayName": "stale-name",
                    "productionServing": true,
                    "customNote": "hand-edited",
                    "probes": [
                        "toolCall": ["verdict": "pass", "source": "gauntlet"],
                        "load": ["verdict": "fail", "source": "gauntlet", "evidence": "old"],
                    ],
                ],
            ],
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: seeded).write(to: url)

        try ModelVerificationLedger.recordAutorunProbes(
            modelName: "Qwen3-4B-Instruct",
            outcome: passingOutcome,
            chip: "Apple M4",
            fileURL: url
        )

        let root = try readJSON(url)
        // Foreign top-level fields survive.
        #expect(root["version"] as? Int == 3)
        #expect(root["generatedBy"] as? String == "osaurus verify 0.1")

        let models = root["models"] as? [String: Any]
        // Foreign model record is untouched.
        let other = models?["other_model"] as? [String: Any]
        #expect(other?["productionServing"] as? Bool == false)
        #expect((other?["probes"] as? [String: Any])?.keys.contains("load") == true)

        let record = models?["qwen3_4b_instruct"] as? [String: Any]
        // Serving gate and unknown fields on our record are untouched;
        // autorun must never write productionServing.
        #expect(record?["productionServing"] as? Bool == true)
        #expect(record?["customNote"] as? String == "hand-edited")
        // Fields autorun owns are replaced.
        #expect(record?["displayName"] as? String == "Qwen3-4B-Instruct")
        #expect(record?["chip"] as? String == "Apple M4")

        let probes = record?["probes"] as? [String: Any]
        // Foreign probe entry preserved.
        let toolCall = probes?["toolCall"] as? [String: Any]
        #expect(toolCall?["source"] as? String == "gauntlet")
        // Our probe entries overwritten with autorun evidence.
        let load = probes?["load"] as? [String: Any]
        #expect(load?["verdict"] as? String == "pass")
        #expect(load?["source"] as? String == "autorun")
        #expect(load?["evidence"] as? String == passingOutcome.loadEvidence)
    }

    @Test func normalized_keys_are_lowercased_and_underscored() {
        #expect(ModelVerificationLedger.normalizedKey(for: "Qwen3-4B Instruct") == "qwen3_4b_instruct")
        #expect(
            ModelVerificationLedger.normalizedKey(for: "mlx-community/Llama-3.2-1B")
                == "mlx_community_llama_3.2_1b"
        )
        #expect(ModelVerificationLedger.normalizedKey(for: "--weird  name--") == "weird_name")
        #expect(ModelVerificationLedger.normalizedKey(for: "already_normal.4bit") == "already_normal.4bit")
    }
}

struct AutorunTemplateLeakScanTests {

    @Test func clean_prose_does_not_trip_the_scan() {
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "Ready.") == nil)
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "note that a < b and b |> c") == nil)
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "") == nil)
    }

    @Test func detects_chatml_and_llama3_and_gemma_markers() {
        // "First" is token-list order, not position-in-text — any hit fails
        // the probe, so the specific token only needs to be deterministic.
        #expect(
            AutorunTemplateLeakScan.firstLeakedToken(in: "Hi<|im_end|>\n<|im_start|>user")
                == "<|im_start|>"
        )
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "answer<|eot_id|>") == "<|eot_id|>")
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "ok<end_of_turn>") == "<end_of_turn>")
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "sure [/INST] done") == "[/INST]")
        #expect(AutorunTemplateLeakScan.firstLeakedToken(in: "done</s>") == "</s>")
    }

    @Test func token_list_matches_vendored_contract() {
        // The list is a vendored mirror of StreamTemplateLeakDetector
        // (mlx-perf/runtime-guardrails); pin the members so an accidental
        // edit here is loud, and drift against the detector is reviewable.
        #expect(AutorunTemplateLeakScan.leakTokens.count == 22)
        #expect(AutorunTemplateLeakScan.leakTokens.contains("<|im_start|>"))
        #expect(AutorunTemplateLeakScan.leakTokens.contains("<|start_header_id|>"))
        #expect(AutorunTemplateLeakScan.leakTokens.contains("<|channel|>"))
        #expect(AutorunTemplateLeakScan.leakTokens.contains("<<SYS>>"))
        // No duplicates.
        #expect(Set(AutorunTemplateLeakScan.leakTokens).count == AutorunTemplateLeakScan.leakTokens.count)
    }
}
