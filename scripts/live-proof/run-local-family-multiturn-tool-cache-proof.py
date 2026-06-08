#!/usr/bin/env python3
"""Run strict live multi-turn tool/cache proof against a local Osaurus app.

This harness exercises the OpenAI-compatible chat endpoint used by real
clients. It verifies a required tool call, a no-tool follow-up after a tool
result, and a second required tool call after tool history while recording
health/cache telemetry.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import time
import urllib.request
from datetime import datetime, timezone
from typing import Any


PROTOCOL_MARKERS = (
    "<｜",
    "</｜",
    "</s>",
    "DSML",
    ":json{",
    "tool_ccalls",
    "tool_crs",
    "<|im_start|>",
    "<|im_end|>",
    "<tool_call>",
    "</tool_call>",
)


def request_json(base_url: str, method: str, path: str, payload: Any | None = None, timeout: int = 900) -> Any:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=data,
        headers={"Accept": "application/json", "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        raw = response.read()
    return json.loads(raw)


def save(path: pathlib.Path, value: Any) -> None:
    if isinstance(value, (dict, list)):
        path.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    else:
        path.write_text(str(value), encoding="utf-8")


def process_snapshot() -> str:
    cmd = (
        "ps -axo pid,ppid,stat,etime,rss,command | "
        "rg -i 'CodeSigningHelper|/Contents/MacOS/osaurus|RunBench|vmlx_engine\\.cli' | "
        "rg -v 'rg -i|codex|zsh -lc' || true"
    )
    return subprocess.run(cmd, shell=True, text=True, capture_output=True).stdout


def vm_snapshot() -> str:
    cmd = "vm_stat | sed -n '1,10p'; sysctl vm.swapusage"
    result = subprocess.run(cmd, shell=True, text=True, capture_output=True)
    return result.stdout + result.stderr


def marker_leaks(value: Any) -> list[str]:
    text = json.dumps(value, ensure_ascii=False)
    return [marker for marker in PROTOCOL_MARKERS if marker in text]


def message(response: dict[str, Any]) -> dict[str, Any]:
    return response["choices"][0]["message"]


def finish(response: dict[str, Any]) -> str | None:
    return response["choices"][0].get("finish_reason")


def token_rate(response: dict[str, Any], elapsed: float) -> dict[str, float | int | None]:
    usage = response.get("usage")
    completion_tokens = usage.get("completion_tokens") if isinstance(usage, dict) else None
    if isinstance(completion_tokens, int) and elapsed > 0:
        return {
            "completion_tokens": completion_tokens,
            "elapsed_seconds": elapsed,
            "tokens_per_second": completion_tokens / elapsed,
        }
    return {
        "completion_tokens": completion_tokens,
        "elapsed_seconds": elapsed,
        "tokens_per_second": None,
    }


def parse_args(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {"_raw": raw}
    return value if isinstance(value, dict) else {"_raw": value}


def aggregate(cache: dict[str, Any] | None) -> dict[str, int]:
    if not isinstance(cache, dict):
        return {}
    value = cache.get("aggregate")
    return value if isinstance(value, dict) else {}


def model_entry(cache: dict[str, Any] | None, model: str) -> dict[str, Any]:
    if not isinstance(cache, dict):
        return {}
    models = cache.get("models")
    if not isinstance(models, list):
        return {}
    for entry in models:
        if isinstance(entry, dict) and entry.get("name") == model:
            return entry
    return {}


def current_health_model_matches(health: dict[str, Any], model: str) -> bool:
    if health.get("current_model") == model:
        return True
    loaded = health.get("loaded")
    if isinstance(loaded, list) and model in loaded:
        return True
    return False


def cache_evidence_checks(
    required: list[str],
    cache_after: dict[str, Any],
    delta: dict[str, int],
    model: str,
) -> dict[str, bool]:
    entry = model_entry(cache_after, model)
    topology = entry.get("cache_topology") if isinstance(entry, dict) else None
    topology = topology if isinstance(topology, dict) else {}
    block_disk = entry.get("block_disk_store") if isinstance(entry, dict) else None
    block_disk = block_disk if isinstance(block_disk, dict) else {}
    companion = entry.get("companion_cache") if isinstance(entry, dict) else None
    companion = companion if isinstance(companion, dict) else {}
    ssm = entry.get("ssm_companion_cache") if isinstance(entry, dict) else None
    ssm = ssm if isinstance(ssm, dict) else {}
    zaya = entry.get("zaya_cca_disk_payload_restore") if isinstance(entry, dict) else None
    zaya = zaya if isinstance(zaya, dict) else {}

    checks: dict[str, bool] = {}
    for name in required:
        if name == "cache_topology":
            checks["cache_evidence_cache_topology"] = bool(topology) and topology.get("layer_count", 0) > 0
        elif name == "disk_l2_hits":
            checks["cache_evidence_disk_l2_hits"] = delta.get("block_disk_hits", 0) > 0
        elif name == "requires_disk_backed_restore":
            checks["cache_evidence_requires_disk_backed_restore"] = topology.get("requires_disk_backed_restore") is True
        elif name == "ssm_companion_cache":
            checks["cache_evidence_ssm_companion_cache"] = (
                topology.get("requires_ssm_companion_state") is True
                and (bool(ssm) or "companion=ssm" in (companion.get("kinds") or []))
            )
        elif name == "companion_cache":
            checks["cache_evidence_companion_cache"] = (
                bool(companion.get("kinds"))
                or companion.get("hits", 0) > 0
                or companion.get("rederives", 0) > 0
                or topology.get("requires_ssm_companion_state") is True
                or topology.get("zaya_cca_layer_count", 0) > 0
            )
        elif name == "zaya_cca_disk_payload_restore":
            checks["cache_evidence_zaya_cca_disk_payload_restore"] = (
                bool(zaya)
                or topology.get("zaya_cca_layer_count", 0) > 0
                or "companion=zaya-cca" in (companion.get("kinds") or [])
            )
        elif name == "hybrid_pool_layer_count":
            checks["cache_evidence_hybrid_pool_layer_count"] = topology.get("hybrid_pool_layer_count", 0) > 0
        elif name == "rotating_kv_layer_count":
            checks["cache_evidence_rotating_kv_layer_count"] = topology.get("rotating_kv_layer_count", 0) > 0
        else:
            checks[f"cache_evidence_unknown_{name}"] = False
    return checks


def flatten_cache_counters(entry: dict[str, Any]) -> dict[str, int]:
    counters: dict[str, int] = {}

    def add(prefix: str, value: Any) -> None:
        if not isinstance(value, dict):
            return
        for key, raw in value.items():
            if isinstance(raw, int):
                counters[f"{prefix}_{key}"] = raw

    add("block_disk", entry.get("block_disk_store"))
    add("paged", entry.get("paged_cache"))
    add("companion", entry.get("companion_cache"))
    add("ssm_companion", entry.get("ssm_companion_cache"))
    add("zaya_cca_disk_payload", entry.get("zaya_cca_disk_payload_restore"))
    topology = entry.get("cache_topology")
    if isinstance(topology, dict):
        for key, raw in topology.items():
            if isinstance(raw, int):
                counters[f"topology_{key}"] = raw
    return counters


def counter_delta(left: dict[str, int], right: dict[str, int]) -> dict[str, int]:
    keys = sorted(set(left) | set(right))
    out: dict[str, int] = {}
    for key in keys:
        if isinstance(left.get(key, 0), int) and isinstance(right.get(key, 0), int):
            out[key] = int(right.get(key, 0)) - int(left.get(key, 0))
    return out


def aggregate_delta(before: dict[str, Any] | None, after: dict[str, Any] | None) -> dict[str, int]:
    return counter_delta(aggregate(before), aggregate(after))


def model_delta(before: dict[str, Any] | None, after: dict[str, Any] | None, model: str) -> dict[str, int]:
    return counter_delta(
        flatten_cache_counters(model_entry(before, model)),
        flatten_cache_counters(model_entry(after, model)),
    )


def call_chat(base_url: str, payload: dict[str, Any], timeout: int) -> tuple[dict[str, Any], float]:
    start = time.monotonic()
    response = request_json(base_url, "POST", "/v1/chat/completions", payload, timeout=timeout)
    return response, time.monotonic() - start


def failure_summary(model: str, error: BaseException, root: pathlib.Path) -> dict[str, Any]:
    label = model.replace("/", "_").replace(":", "_")
    summary: dict[str, Any] = {
        "model": model,
        "checks": {"harness_completed": False},
        "failed_checks": ["harness_completed"],
        "error": {
            "type": type(error).__name__,
            "message": str(error),
        },
        "passed": False,
        "finished": datetime.now(timezone.utc).isoformat(),
    }
    save(root / f"{label}_error.json", summary)
    save(root / f"{label}_summary.json", summary)
    return summary


def run_model(args: argparse.Namespace, model: str, root: pathlib.Path) -> dict[str, Any]:
    label = model.replace("/", "_").replace(":", "_")
    summary: dict[str, Any] = {
        "model": model,
        "checks": {},
        "started": datetime.now(timezone.utc).isoformat(),
    }

    tool = {
        "type": "function",
        "function": {
            "name": "line_count",
            "description": "Count newline-separated text lines.",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
                "additionalProperties": False,
            },
        },
    }

    health_before = request_json(args.base_url, "GET", "/health", timeout=30)
    cache_before = request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30)
    save(root / f"{label}_health_before.json", health_before)
    save(root / f"{label}_cache_before.json", cache_before)

    req1 = {
        "model": model,
        "messages": [{"role": "user", "content": "Use the line_count tool on this exact text: red\ngreen\nblue"}],
        "tools": [tool],
        "tool_choice": "required",
        "max_tokens": args.max_tokens,
    }
    save(root / f"{label}_01_required.request.json", req1)
    resp1, elapsed1 = call_chat(args.base_url, req1, args.timeout)
    save(root / f"{label}_01_required.response.json", resp1)
    msg1 = message(resp1)
    calls1 = msg1.get("tool_calls") or []
    call1 = calls1[0] if calls1 else {}
    args1 = parse_args(call1.get("function", {}).get("arguments"))
    history_valid = finish(resp1) == "tool_calls" and len(calls1) == 1 and bool(call1.get("id"))

    if history_valid:
        req2 = {
            "model": model,
            "messages": [
                req1["messages"][0],
                {"role": "assistant", "content": msg1.get("content"), "tool_calls": calls1},
                {
                    "role": "tool",
                    "tool_call_id": call1.get("id"),
                    "content": json.dumps({"lines": 3}, sort_keys=True),
                },
                {
                    "role": "user",
                    "content": "How many lines were counted? Answer plainly in one short sentence. Do not call another tool.",
                },
            ],
            "tools": [tool],
            "tool_choice": "none",
            "max_tokens": args.max_tokens,
        }
        save(root / f"{label}_02_none_followup.request.json", req2)
        resp2, elapsed2 = call_chat(args.base_url, req2, args.timeout)
        save(root / f"{label}_02_none_followup.response.json", resp2)
        msg2 = message(resp2)
        content2 = msg2.get("content") or ""

        req3 = {
            "model": model,
            "messages": [
                *req2["messages"],
                {"role": "assistant", "content": content2},
                {"role": "user", "content": "Now use line_count on this exact text: one\ntwo"},
            ],
            "tools": [tool],
            "tool_choice": "required",
            "max_tokens": args.max_tokens,
        }
        save(root / f"{label}_03_required_again.request.json", req3)
        resp3, elapsed3 = call_chat(args.base_url, req3, args.timeout)
        save(root / f"{label}_03_required_again.response.json", resp3)
        msg3 = message(resp3)
        calls3 = msg3.get("tool_calls") or []
        call3 = calls3[0] if calls3 else {}
        args3 = parse_args(call3.get("function", {}).get("arguments"))
    else:
        req2 = {"skipped": "turn1 did not produce a valid structured tool call"}
        req3 = {"skipped": "turn1 did not produce a valid structured tool call"}
        resp2 = {"choices": [{"message": {}, "finish_reason": "skipped"}], "usage": {}}
        resp3 = {"choices": [{"message": {}, "finish_reason": "skipped"}], "usage": {}}
        elapsed2 = 0.0
        elapsed3 = 0.0
        msg2 = {}
        msg3 = {}
        content2 = ""
        calls3 = []
        call3 = {}
        args3 = {}
        save(root / f"{label}_02_none_followup.request.json", req2)
        save(root / f"{label}_02_none_followup.response.json", resp2)
        save(root / f"{label}_03_required_again.request.json", req3)
        save(root / f"{label}_03_required_again.response.json", resp3)

    time.sleep(args.settle_seconds)
    health_after = request_json(args.base_url, "GET", "/health", timeout=30)
    cache_after = request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30)
    save(root / f"{label}_health_after.json", health_after)
    save(root / f"{label}_cache_after.json", cache_after)

    delta = model_delta(cache_before, cache_after, model)
    checks = {
        "no_inflight_before": not health_before.get("inflight"),
        "server_healthy_after": health_after.get("status") == "healthy",
        "no_inflight_after": not health_after.get("inflight"),
        "requested_model_current_after": current_health_model_matches(health_after, model),
        "requested_model_cache_entry_after": bool(model_entry(cache_after, model)),
        "turn1_finish_tool_calls": finish(resp1) == "tool_calls",
        "turn1_has_one_tool_call": len(calls1) == 1,
        "turn1_name_line_count": call1.get("function", {}).get("name") == "line_count",
        "turn1_args_exact": args1.get("text") == "red\ngreen\nblue",
        "turn1_no_visible_content": msg1.get("content") in (None, ""),
        "turn1_no_protocol_leak": marker_leaks(resp1) == [],
        "history_valid_after_turn1": history_valid,
        "turn2_no_tool_calls": not msg2.get("tool_calls"),
        "turn2_visible_mentions_3": "3" in content2 or "three" in content2.lower(),
        "turn2_not_length_stop": finish(resp2) != "length",
        "turn2_no_protocol_leak": marker_leaks(resp2) == [],
        "turn3_finish_tool_calls": finish(resp3) == "tool_calls",
        "turn3_has_one_tool_call": len(calls3) == 1,
        "turn3_name_line_count": call3.get("function", {}).get("name") == "line_count",
        "turn3_args_exact": args3.get("text") == "one\ntwo",
        "turn3_no_visible_content": msg3.get("content") in (None, ""),
        "turn3_no_protocol_leak": marker_leaks(resp3) == [],
    }
    checks.update(cache_evidence_checks(args.required_cache_evidence, cache_after, delta, model))
    summary.update(
        {
            "checks": checks,
            "failed_checks": [key for key, value in checks.items() if not value],
            "durations": {"turn1": elapsed1, "turn2": elapsed2, "turn3": elapsed3},
            "token_rates": {
                "turn1": token_rate(resp1, elapsed1),
                "turn2": token_rate(resp2, elapsed2),
                "turn3": token_rate(resp3, elapsed3),
            },
            "turns": {
                "turn1_finish": finish(resp1),
                "turn1_args": args1,
                "turn2_finish": finish(resp2),
                "turn2_content": content2,
                "turn3_finish": finish(resp3),
                "turn3_args": args3,
            },
            "required_cache_evidence": args.required_cache_evidence,
            "cache_delta": delta,
            "aggregate_cache_delta": aggregate_delta(cache_before, cache_after),
            "cache_after": cache_after,
            "health_after": health_after,
            "passed": all(checks.values()),
            "finished": datetime.now(timezone.utc).isoformat(),
        }
    )
    save(root / f"{label}_summary.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:1337")
    parser.add_argument("--artifact-root", required=True)
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--max-tokens", type=int, default=384)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--settle-seconds", type=float, default=2)
    parser.add_argument("--required-cache-evidence", action="append", default=[])
    args = parser.parse_args()

    root = pathlib.Path(args.artifact_root)
    root.mkdir(parents=True, exist_ok=True)
    save(root / "process-before.txt", process_snapshot())
    save(root / "vm-before.txt", vm_snapshot())
    started = datetime.now(timezone.utc).isoformat()
    results: dict[str, Any] = {}
    for model in args.model:
        try:
            results[model] = run_model(args, model, root)
        except BaseException as error:
            results[model] = failure_summary(model, error, root)
    save(root / "process-after.txt", process_snapshot())
    save(root / "vm-after.txt", vm_snapshot())
    summary = {
        "artifact_dir": str(root),
        "started": started,
        "finished": datetime.now(timezone.utc).isoformat(),
        "models": results,
        "passed": all(row.get("passed") for row in results.values()),
    }
    save(root / "SUMMARY.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
