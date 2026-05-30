#!/usr/bin/env python3
"""Run a live Osaurus VLM media/cache proof against the app server.

This harness uses the OpenAI-compatible chat endpoint with a real data-URL
image payload. It verifies that the model sees the image, that the repeated
request has a stable prefix hash, and that cache telemetry records L2 reuse.
"""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import struct
import subprocess
import time
import urllib.error
import urllib.request
import zlib
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


def make_png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def aggregate(cache: dict[str, Any] | None) -> dict[str, int]:
    if not isinstance(cache, dict):
        return {}
    value = cache.get("aggregate")
    return value if isinstance(value, dict) else {}


def delta(before: dict[str, Any] | None, after: dict[str, Any] | None) -> dict[str, int]:
    left = aggregate(before)
    right = aggregate(after)
    keys = sorted(set(left) | set(right))
    out: dict[str, int] = {}
    for key in keys:
        if isinstance(left.get(key, 0), int) and isinstance(right.get(key, 0), int):
            out[key] = int(right.get(key, 0)) - int(left.get(key, 0))
    return out


def answer_text(response: dict[str, Any]) -> str:
    return response["choices"][0]["message"].get("content") or ""


def finish_reason(response: dict[str, Any]) -> str | None:
    return response["choices"][0].get("finish_reason")


def run(args: argparse.Namespace) -> int:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    root = pathlib.Path(args.artifact_root or f"/tmp/osaurus-vl-media-proof-{args.model}-{stamp}")
    root.mkdir(parents=True, exist_ok=True)

    if args.color != "red":
        raise ValueError("only red is currently supported by this deterministic harness")

    png = make_png(args.size, args.size, (255, 0, 0))
    save(root / "red.png.base64.txt", base64.b64encode(png).decode("ascii"))
    (root / "red.png").write_bytes(png)
    data_url = "data:image/png;base64," + base64.b64encode(png).decode("ascii")
    payload = {
        "model": args.model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "What is the dominant color in this image? Answer one word only."},
                    {"type": "image_url", "image_url": {"url": data_url}},
                ],
            }
        ],
        "max_tokens": args.max_tokens,
    }

    summary: dict[str, Any] = {
        "artifact_dir": str(root),
        "base_url": args.base_url,
        "model": args.model,
        "image": {"color": args.color, "width": args.size, "height": args.size},
        "started": datetime.now(timezone.utc).isoformat(),
        "checks": {},
    }

    save(root / "process-before.txt", process_snapshot())
    save(root / "vm-before.txt", vm_snapshot())
    cache_before = request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30)
    save(root / "cache-before.json", cache_before)
    health_before = request_json(args.base_url, "GET", "/health", timeout=30)
    save(root / "health-before.json", health_before)
    save(root / "request.json", payload)

    try:
        start = time.monotonic()
        first = request_json(args.base_url, "POST", "/v1/chat/completions", payload, timeout=args.timeout)
        first_elapsed = time.monotonic() - start
        save(root / "response-first.json", first)

        cache_before_repeat = request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30)
        save(root / "cache-before-repeat.json", cache_before_repeat)
        start = time.monotonic()
        repeat = request_json(args.base_url, "POST", "/v1/chat/completions", payload, timeout=args.timeout)
        repeat_elapsed = time.monotonic() - start
        save(root / "response-repeat.json", repeat)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        save(root / "http-error-body.txt", body)
        summary["error"] = f"HTTPError {exc.code}"
        summary["error_body"] = body
        summary["passed"] = False
        save(root / "SUMMARY.json", summary)
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 2

    time.sleep(args.settle_seconds)
    cache_after = request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30)
    health_after = request_json(args.base_url, "GET", "/health", timeout=30)
    save(root / "cache-after.json", cache_after)
    save(root / "health-after.json", health_after)
    save(root / "process-after.txt", process_snapshot())
    save(root / "vm-after.txt", vm_snapshot())

    first_text = answer_text(first)
    repeat_text = answer_text(repeat)
    first_rate = (first.get("usage", {}).get("completion_tokens") or 0) / first_elapsed if first_elapsed > 0 else None
    repeat_rate = (repeat.get("usage", {}).get("completion_tokens") or 0) / repeat_elapsed if repeat_elapsed > 0 else None
    repeat_delta = delta(cache_before_repeat, cache_after)

    checks = {
        "server_healthy_after": health_after.get("status") == "healthy",
        "model_resident_after": args.model in json.dumps(health_after),
        "first_stop": finish_reason(first) == "stop",
        "repeat_stop": finish_reason(repeat) == "stop",
        "first_mentions_red": "red" in first_text.lower(),
        "repeat_mentions_red": "red" in repeat_text.lower(),
        "first_no_protocol_leak": marker_leaks(first) == [],
        "repeat_no_protocol_leak": marker_leaks(repeat) == [],
        "stable_prefix_hash": bool(first.get("prefix_hash")) and first.get("prefix_hash") == repeat.get("prefix_hash"),
        "repeat_disk_l2_hit": repeat_delta.get("disk_l2_hits", 0) > 0,
    }
    summary.update(
        {
            "checks": checks,
            "failed_checks": [key for key, value in checks.items() if not value],
            "first": {
                "content": first_text,
                "finish_reason": finish_reason(first),
                "prefix_hash": first.get("prefix_hash"),
                "elapsed_seconds": first_elapsed,
                "tokens_per_second": first_rate,
                "usage": first.get("usage"),
            },
            "repeat": {
                "content": repeat_text,
                "finish_reason": finish_reason(repeat),
                "prefix_hash": repeat.get("prefix_hash"),
                "elapsed_seconds": repeat_elapsed,
                "tokens_per_second": repeat_rate,
                "usage": repeat.get("usage"),
            },
            "cache_delta_total": delta(cache_before, cache_after),
            "cache_delta_repeat": repeat_delta,
            "cache_after": cache_after,
            "health_after": health_after,
            "passed": all(checks.values()),
            "finished": datetime.now(timezone.utc).isoformat(),
        }
    )
    save(root / "SUMMARY.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:1337")
    parser.add_argument("--artifact-root")
    parser.add_argument("--model", required=True)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--settle-seconds", type=float, default=2)
    parser.add_argument("--color", default="red")
    parser.add_argument("--size", type=int, default=64)
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
