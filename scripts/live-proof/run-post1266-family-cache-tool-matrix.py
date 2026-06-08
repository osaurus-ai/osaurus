#!/usr/bin/env python3
"""Live Osaurus family tool/cache matrix probe.

This script intentionally drives the same HTTP chat path a user hits through the
Osaurus app server. It does not add sampler overrides. It records raw requests,
responses, health, cache stats, durations, and a compact SUMMARY.json for each
model row.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

LEAK_PATTERNS = [
    "<｜DSML｜",
    "DSML",
    "tool_calls",
    "tool_call",
    "<tool_call",
    "</tool_call",
    "<think>",
    "</think>",
    "reasoning_content",
    "<｜Assistant",
    "<|assistant",
]

FAMILY_PATTERNS: list[tuple[str, str]] = [
    ("nemotron", "nemotron_omni"),
    ("nemo", "nemotron_omni"),
    ("hy3", "hy3"),
    ("hunyuan", "hy3"),
    ("ling", "ling"),
    ("zaya", "zaya"),
    ("deepseek-v4", "dsv4"),
    ("dsv4", "dsv4"),
    ("qwen", "qwen"),
    ("gemma", "gemma"),
    ("minimax", "minimax"),
    ("mimo", "mimo"),
]

TOOL_SCHEMA = [
    {
        "type": "function",
        "function": {
            "name": "line_count",
            "description": "Count newline-separated lines in text.",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                },
                "required": ["text"],
            },
        },
    }
]

# Tool-call proofs must not fail just because a reasoning-capable family
# spends tokens restating the requested schema before emitting the protocol
# block. This is a harness cap only; production/API defaults stay model-owned.
REQUIRED_TOOL_MAX_TOKENS = 1536
# Reasoning-capable families can spend nearly the whole small cap in hidden
# reasoning before emitting the visible answer. Keep this high enough that the
# harness tests visible-answer behavior instead of clipping a correct decode.
VISIBLE_ANSWER_MAX_TOKENS = 320


def now_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def request_json(base_url: str, path: str, payload: dict[str, Any] | None = None, timeout: float = 180.0) -> dict[str, Any]:
    url = base_url.rstrip("/") + path
    if payload is None:
        req = urllib.request.Request(url, method="GET")
    else:
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {url}: {text}") from exc
    if not data:
        return {}
    return json.loads(data)


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def model_family(model_id: str) -> str:
    low = model_id.lower()
    for needle, family in FAMILY_PATTERNS:
        if needle in low:
            return family
    return "unknown"


def pick_models(all_models: list[str], patterns: list[str], per_family: int) -> list[str]:
    if patterns:
        selected = []
        for pat in patterns:
            rx = re.compile(pat, re.I)
            selected.extend([m for m in all_models if rx.search(m)])
        return list(dict.fromkeys(selected))
    selected_by_family: dict[str, list[str]] = {}
    for mid in all_models:
        if mid.startswith("_"):
            continue
        family = model_family(mid)
        if family == "unknown":
            continue
        selected_by_family.setdefault(family, []).append(mid)
    selected: list[str] = []
    for family in ["nemotron_omni", "hy3", "ling", "zaya", "dsv4", "qwen", "gemma", "minimax", "mimo"]:
        selected.extend(selected_by_family.get(family, [])[:per_family])
    return selected


def leak_hits(value: Any) -> list[str]:
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    return [needle for needle in LEAK_PATTERNS if needle in text]


def message_content(choice: dict[str, Any]) -> str:
    msg = choice.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content
    return ""


def first_tool_call(choice: dict[str, Any]) -> dict[str, Any] | None:
    msg = choice.get("message") or {}
    calls = msg.get("tool_calls") or []
    if not calls:
        return None
    return calls[0]


def parse_tool_args(call: dict[str, Any]) -> dict[str, Any]:
    function = call.get("function") or {}
    raw = function.get("arguments") or "{}"
    if isinstance(raw, dict):
        return raw
    return json.loads(raw)


def assert_tool_call(choice: dict[str, Any], expected_text: str) -> tuple[bool, list[str], dict[str, Any] | None]:
    failures: list[str] = []
    visible = message_content(choice)
    visible_leaks = leak_hits(visible)
    if visible.strip():
        failures.append(f"visible_content_on_tool_turn={visible[:120]!r}")
    if visible_leaks:
        failures.append(f"visible_protocol_leak={visible_leaks}")
    call = first_tool_call(choice)
    if call is None:
        failures.append("missing_tool_call")
        return False, failures, None
    function = call.get("function") or {}
    if function.get("name") != "line_count":
        failures.append(f"wrong_tool_name={function.get('name')!r}")
    try:
        args = parse_tool_args(call)
    except Exception as exc:  # noqa: BLE001 - artifact should preserve parser failure
        failures.append(f"arguments_not_json={exc}")
        args = {}
    if args.get("text") != expected_text:
        failures.append(f"wrong_text_arg={args.get('text')!r}")
    return not failures, failures, call


def cache_counters(stats: dict[str, Any], model: str) -> dict[str, int]:
    for row in stats.get("models") or []:
        if row.get("name") != model:
            continue
        block = row.get("block_disk_store") or {}
        paged = row.get("paged_cache") or {}
        companion = row.get("companion_cache") or {}
        ssm = row.get("ssm_companion_cache") or {}
        zaya = row.get("zaya_cca_disk_payload_restore") or {}
        return {
            "disk_l2_hits": int(block.get("hits") or 0),
            "disk_l2_misses": int(block.get("misses") or 0),
            "disk_l2_stores": int(block.get("stores") or 0),
            "paged_hits": int(paged.get("hits") or 0),
            "paged_misses": int(paged.get("misses") or 0),
            "prefix_hits": int((stats.get("aggregate") or {}).get("prefix_hits") or 0),
            "prefix_misses": int((stats.get("aggregate") or {}).get("prefix_misses") or 0),
            "companion_hits": int(companion.get("hits") or 0),
            "companion_misses": int(companion.get("misses") or 0),
            "companion_rederives": int(companion.get("rederives") or 0),
            "ssm_companion_hits": int(ssm.get("hits") or 0),
            "ssm_companion_misses": int(ssm.get("misses") or 0),
            "ssm_companion_rederives": int(ssm.get("rederives") or 0),
            "zaya_cca_disk_payload_hits": int(zaya.get("hits") or 0),
            "zaya_cca_disk_payload_misses": int(zaya.get("misses") or 0),
            "zaya_cca_disk_payload_stores": int(zaya.get("stores") or 0),
        }
    return {
        "disk_l2_hits": 0,
        "disk_l2_misses": 0,
        "disk_l2_stores": 0,
        "paged_hits": 0,
        "paged_misses": 0,
        "prefix_hits": 0,
        "prefix_misses": 0,
        "companion_hits": 0,
        "companion_misses": 0,
        "companion_rederives": 0,
        "ssm_companion_hits": 0,
        "ssm_companion_misses": 0,
        "ssm_companion_rederives": 0,
        "zaya_cca_disk_payload_hits": 0,
        "zaya_cca_disk_payload_misses": 0,
        "zaya_cca_disk_payload_stores": 0,
    }


def counter_delta(before: dict[str, Any], after: dict[str, Any], model: str) -> dict[str, int]:
    keys = list(cache_counters(after, model).keys())
    b = cache_counters(before, model)
    a = cache_counters(after, model)
    out: dict[str, int] = {}
    for key in keys:
        out[key] = a.get(key, 0) - b.get(key, 0)
    return out


def model_cache_topology(stats: dict[str, Any], model: str) -> dict[str, Any]:
    for row in stats.get("models") or []:
        if row.get("name") == model:
            return row.get("cache_topology") or {}
    return {}


def cache_boundaries_for_topology(family: str, delta: dict[str, int], topology: dict[str, Any]) -> list[str]:
    boundaries: list[str] = []
    zaya_layers = int(topology.get("zaya_cca_layer_count") or 0)
    tags = topology.get("tags") or []
    ssm_required = (
        family != "zaya"
        and (
            int(topology.get("mamba_layer_count") or 0) > 0
            or any(str(tag) == "companion=ssm" for tag in tags)
        )
    )
    if family == "zaya" or zaya_layers > 0:
        if delta.get("zaya_cca_disk_payload_hits", 0) <= 0:
            boundaries.append("ZAYA CCA disk payload restore was not proven")
    if ssm_required:
        if delta.get("ssm_companion_hits", 0) <= 0 and delta.get("companion_hits", 0) <= 0:
            boundaries.append("SSM companion hit was not proven")
    return boundaries


def run_model(base_url: str, model: str, out_dir: Path, timeout: float) -> dict[str, Any]:
    row_dir = out_dir / re.sub(r"[^A-Za-z0-9_.-]+", "_", model)
    row_dir.mkdir(parents=True, exist_ok=True)

    summary: dict[str, Any] = {
        "model": model,
        "family": model_family(model),
        "classification": "fail",
        "failures": [],
        "boundaries": [],
        "sampler_overrides": "none in script payloads",
        "token_per_second": "not emitted by OpenAI-compatible response; durations and usage recorded",
    }

    before_health = request_json(base_url, "/health", timeout=10)
    before_cache = request_json(base_url, "/admin/cache-stats", timeout=10)
    write_json(row_dir / "00_health_before.json", before_health)
    write_json(row_dir / "00_cache_before.json", before_cache)

    text1 = "alpha\nbeta\ngamma"
    req1 = {
        "model": model,
        "messages": [
            {"role": "user", "content": f"Use the line_count tool on exactly this text, preserving newlines:\n{text1}"}
        ],
        "tools": TOOL_SCHEMA,
        "tool_choice": "required",
        "max_tokens": REQUIRED_TOOL_MAX_TOKENS,
    }
    write_json(row_dir / "01_required_tool_request.json", req1)
    t0 = time.time()
    resp1 = request_json(base_url, "/v1/chat/completions", req1, timeout=timeout)
    dt1 = time.time() - t0
    write_json(row_dir / "01_required_tool_response.json", resp1)
    (row_dir / "01_required_tool_duration.txt").write_text(f"{dt1:.3f}\n", encoding="utf-8")
    choice1 = (resp1.get("choices") or [{}])[0]
    ok1, failures1, call1 = assert_tool_call(choice1, text1)
    summary["turn1_required_tool"] = {"ok": ok1, "duration_seconds": round(dt1, 3), "failures": failures1}
    summary["failures"].extend([f"turn1:{f}" for f in failures1])

    if call1 is None:
        after_cache = request_json(base_url, "/admin/cache-stats", timeout=10)
        write_json(row_dir / "99_cache_after_failure.json", after_cache)
        summary["cache_delta"] = counter_delta(before_cache, after_cache, model)
        write_json(row_dir / "SUMMARY.json", summary)
        return summary

    tool_call_id = call1.get("id") or "call_line_count_1"
    messages2 = [
        req1["messages"][0],
        {"role": "assistant", "content": None, "tool_calls": [call1]},
        {"role": "tool", "tool_call_id": tool_call_id, "content": json.dumps({"lines": 3})},
        {"role": "user", "content": "Answer visibly in one short sentence: how many lines were counted? Do not call a tool."},
    ]
    req2 = {
        "model": model,
        "messages": messages2,
        "tools": TOOL_SCHEMA,
        "tool_choice": "none",
        "max_tokens": VISIBLE_ANSWER_MAX_TOKENS,
    }
    write_json(row_dir / "02_visible_after_tool_request.json", req2)
    t0 = time.time()
    resp2 = request_json(base_url, "/v1/chat/completions", req2, timeout=timeout)
    dt2 = time.time() - t0
    write_json(row_dir / "02_visible_after_tool_response.json", resp2)
    (row_dir / "02_visible_after_tool_duration.txt").write_text(f"{dt2:.3f}\n", encoding="utf-8")
    choice2 = (resp2.get("choices") or [{}])[0]
    visible2 = message_content(choice2)
    leaks2 = leak_hits(visible2)
    ok2 = bool(visible2.strip()) and not leaks2 and not first_tool_call(choice2)
    failures2: list[str] = []
    if not visible2.strip():
        failures2.append("blank_visible_answer_after_tool")
    if leaks2:
        failures2.append(f"visible_leak={leaks2}")
    if first_tool_call(choice2):
        failures2.append("unexpected_tool_call_when_tool_choice_none")
    summary["turn2_visible_after_tool"] = {"ok": ok2, "duration_seconds": round(dt2, 3), "failures": failures2, "content_preview": visible2[:180]}
    summary["failures"].extend([f"turn2:{f}" for f in failures2])

    text3 = "one\ntwo"
    messages3 = messages2 + [
        {"role": "assistant", "content": visible2},
        {"role": "user", "content": f"Now use line_count on exactly this new text, preserving newlines:\n{text3}"},
    ]
    req3 = {
        "model": model,
        "messages": messages3,
        "tools": TOOL_SCHEMA,
        "tool_choice": "required",
        "max_tokens": REQUIRED_TOOL_MAX_TOKENS,
    }
    write_json(row_dir / "03_second_required_tool_request.json", req3)
    t0 = time.time()
    resp3 = request_json(base_url, "/v1/chat/completions", req3, timeout=timeout)
    dt3 = time.time() - t0
    write_json(row_dir / "03_second_required_tool_response.json", resp3)
    (row_dir / "03_second_required_tool_duration.txt").write_text(f"{dt3:.3f}\n", encoding="utf-8")
    choice3 = (resp3.get("choices") or [{}])[0]
    ok3, failures3, _ = assert_tool_call(choice3, text3)
    summary["turn3_second_required_tool"] = {"ok": ok3, "duration_seconds": round(dt3, 3), "failures": failures3}
    summary["failures"].extend([f"turn3:{f}" for f in failures3])

    after_cache = request_json(base_url, "/admin/cache-stats", timeout=10)
    after_health = request_json(base_url, "/health", timeout=10)
    write_json(row_dir / "99_cache_after.json", after_cache)
    write_json(row_dir / "99_health_after.json", after_health)
    delta = counter_delta(before_cache, after_cache, model)
    topology = model_cache_topology(after_cache, model)
    summary["cache_delta"] = delta
    summary["cache_topology"] = topology
    summary["cache_hit_proven"] = any(
        delta.get(k, 0) > 0
        for k in ("disk_l2_hits", "paged_hits", "prefix_hits", "companion_hits", "ssm_companion_hits", "zaya_cca_disk_payload_hits")
    )
    summary["cache_store_or_miss_seen"] = any(
        delta.get(k, 0) > 0
        for k in (
            "disk_l2_stores",
            "disk_l2_misses",
            "paged_misses",
            "prefix_misses",
            "companion_misses",
            "companion_rederives",
            "ssm_companion_misses",
            "ssm_companion_rederives",
            "zaya_cca_disk_payload_misses",
            "zaya_cca_disk_payload_stores",
        )
    )
    if not summary["cache_hit_proven"]:
        summary["boundaries"].append("cache counters moved but no hit counter was proven in this short row")
    summary["boundaries"].extend(cache_boundaries_for_topology(summary["family"], delta, topology))

    if summary["failures"]:
        summary["classification"] = "fail"
    elif summary["cache_hit_proven"] and not summary["boundaries"]:
        summary["classification"] = "pass"
    else:
        summary["classification"] = "pass_with_cache_boundary"

    write_json(row_dir / "SUMMARY.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:1337")
    parser.add_argument("--artifact-dir", default=f"/tmp/osaurus-post1266-live-family-cache-matrix-{now_slug()}")
    parser.add_argument("--model", action="append", default=[], help="Exact model id or regex pattern. Can be repeated.")
    parser.add_argument("--per-family", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=240.0)
    parser.add_argument("--inventory-only", action="store_true")
    args = parser.parse_args()

    out_dir = Path(args.artifact_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    models_resp = request_json(args.base_url, "/v1/models", timeout=10)
    all_models = [item.get("id", "") for item in models_resp.get("data", []) if item.get("id")]
    inventory = [{"id": mid, "family": model_family(mid)} for mid in all_models]
    write_json(out_dir / "00_model_inventory.json", inventory)

    selected = pick_models(all_models, args.model, args.per_family)
    write_json(out_dir / "00_selected_models.json", selected)
    if args.inventory_only:
        print(json.dumps({"artifact_dir": str(out_dir), "selected": selected, "inventory_count": len(all_models)}, indent=2))
        return 0
    if not selected:
        print(json.dumps({"artifact_dir": str(out_dir), "error": "no selected models"}, indent=2), file=sys.stderr)
        return 2

    summaries = []
    exit_code = 0
    for model in selected:
        try:
            summaries.append(run_model(args.base_url, model, out_dir, args.timeout))
        except Exception as exc:  # noqa: BLE001 - row artifact should preserve runtime failure
            row = {"model": model, "family": model_family(model), "classification": "error", "error": str(exc)}
            summaries.append(row)
            exit_code = 1
            write_json(out_dir / (re.sub(r"[^A-Za-z0-9_.-]+", "_", model) + "_ERROR.json"), row)
    aggregate = {
        "artifact_dir": str(out_dir),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "selected": selected,
        "summaries": summaries,
    }
    write_json(out_dir / "SUMMARY.json", aggregate)
    print(json.dumps(aggregate, indent=2, sort_keys=True))
    if any(s.get("classification") in {"fail", "error"} for s in summaries):
        exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
