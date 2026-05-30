#!/usr/bin/env python3
"""Run a live local Osaurus chat/tool/cache proof against the app server.

This is a proof harness, not model-runtime code. It intentionally talks to the
same OpenAI-compatible endpoint used by clients so rows can be replayed against
a no-sign PR app build without involving signing, notarization, or keychain.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
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
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw.decode("utf-8", "replace")


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


def choice_message(response: dict[str, Any]) -> dict[str, Any]:
    return response["choices"][0]["message"]


def choice_finish(response: dict[str, Any]) -> str | None:
    return response["choices"][0].get("finish_reason")


def run(args: argparse.Namespace) -> int:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    root = pathlib.Path(args.artifact_root or f"/tmp/osaurus-family-proof-{args.label}-{stamp}")
    root.mkdir(parents=True, exist_ok=True)

    fixture = root / "fixture.txt"
    fixture.write_text("alpha\nbravo\ncharlie\ndelta\necho\n", encoding="utf-8")

    summary: dict[str, Any] = {
        "artifact": str(root),
        "base_url": args.base_url,
        "label": args.label,
        "model": args.model,
        "started": datetime.now().isoformat(),
        "checks": {},
    }

    tool = {
        "type": "function",
        "function": {
            "name": "line_count",
            "description": "Count newline-separated lines in a local text file.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
                "additionalProperties": False,
            },
        },
    }

    try:
        save(root / "process-before.txt", process_snapshot())
        save(root / "vm-before.txt", vm_snapshot())
        summary["health_before"] = request_json(args.base_url, "GET", "/health", timeout=30)
        save(root / "health-before.json", summary["health_before"])
        try:
            save(root / "cache-before.json", request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30))
        except Exception as exc:  # cache stats may be gated in some app modes
            save(root / "cache-before-error.txt", repr(exc))

        req1 = {
            "model": args.model,
            "messages": [
                {
                    "role": "user",
                    "content": f"Use the line_count tool on this exact path: {fixture}. Return only a tool call.",
                }
            ],
            "tools": [tool],
            "tool_choice": "required",
            "max_tokens": args.max_tokens,
        }
        save(root / "request1.json", req1)
        start = time.monotonic()
        resp1 = request_json(args.base_url, "POST", "/v1/chat/completions", req1, timeout=args.timeout)
        summary["request1_elapsed_s"] = round(time.monotonic() - start, 3)
        save(root / "response1.json", resp1)

        msg1 = choice_message(resp1)
        calls = msg1.get("tool_calls") or []
        summary["request1_finish_reason"] = choice_finish(resp1)
        summary["request1_usage"] = resp1.get("usage")
        summary["request1_protocol_leaks"] = marker_leaks(resp1)
        summary["checks"]["request1_finish_tool_calls"] = choice_finish(resp1) == "tool_calls"
        summary["checks"]["request1_content_null_or_empty"] = msg1.get("content") in (None, "")
        summary["checks"]["request1_one_tool_call"] = len(calls) == 1
        summary["checks"]["request1_no_protocol_leak"] = summary["request1_protocol_leaks"] == []

        if not calls:
            raise RuntimeError("first request did not produce structured tool_calls")

        call = calls[0]
        summary["request1_tool_name"] = call.get("function", {}).get("name")
        args_raw = call.get("function", {}).get("arguments") or "{}"
        try:
            summary["request1_tool_args"] = json.loads(args_raw) if isinstance(args_raw, str) else args_raw
        except json.JSONDecodeError:
            summary["request1_tool_args"] = {"_raw": args_raw}
        tool_args = summary["request1_tool_args"]
        if isinstance(tool_args, dict) and tool_args.get("path") == str(fixture):
            summary["request1_tool_args_classification"] = "exact_path"
        elif isinstance(tool_args, dict) and tool_args.get("_error") == "invalid_tool_arguments":
            summary["request1_tool_args_classification"] = "invalid_tool_arguments"
        else:
            summary["request1_tool_args_classification"] = "missing_required_path"
        summary["checks"]["request1_tool_args_path_or_invalid"] = (
            summary["request1_tool_args_classification"] in ("exact_path", "invalid_tool_arguments")
        )

        req2 = {
            "model": args.model,
            "messages": [
                req1["messages"][0],
                {"role": "assistant", "content": msg1.get("content"), "tool_calls": calls},
                {
                    "role": "tool",
                    "tool_call_id": call.get("id"),
                    "name": call.get("function", {}).get("name"),
                    "content": json.dumps({"path": str(fixture), "lines": 5}, sort_keys=True),
                },
                {
                    "role": "user",
                    "content": "How many lines did the file have? Answer plainly in one short sentence. Do not call another tool.",
                },
            ],
            "tools": [tool],
            "tool_choice": "auto",
            "max_tokens": args.max_tokens,
        }
        save(root / "request2.json", req2)
        start = time.monotonic()
        resp2 = request_json(args.base_url, "POST", "/v1/chat/completions", req2, timeout=args.timeout)
        summary["request2_elapsed_s"] = round(time.monotonic() - start, 3)
        save(root / "response2.json", resp2)

        msg2 = choice_message(resp2)
        content2 = msg2.get("content") or ""
        summary["request2_content"] = content2
        summary["request2_finish_reason"] = choice_finish(resp2)
        summary["request2_usage"] = resp2.get("usage")
        summary["request2_protocol_leaks"] = marker_leaks(resp2)
        summary["checks"]["request2_visible_answer"] = bool(content2.strip())
        summary["checks"]["request2_mentions_5_or_five"] = "5" in content2 or "five" in content2.lower()
        summary["checks"]["request2_no_protocol_leak"] = summary["request2_protocol_leaks"] == []

        time.sleep(args.settle_seconds)
        summary["health_after"] = request_json(args.base_url, "GET", "/health", timeout=30)
        save(root / "health-after.json", summary["health_after"])
        try:
            save(root / "cache-after.json", request_json(args.base_url, "GET", "/admin/cache-stats", timeout=30))
        except Exception as exc:
            save(root / "cache-after-error.txt", repr(exc))
        save(root / "process-after.txt", process_snapshot())
        save(root / "vm-after.txt", vm_snapshot())
        summary["checks"]["health_after_ok"] = summary["health_after"].get("status") == "healthy"
        summary["checks"]["model_resident_after"] = args.model in json.dumps(summary["health_after"])
        summary["passed"] = all(summary["checks"].values())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        summary["error"] = f"HTTPError {exc.code}"
        summary["error_body"] = body
        save(root / "http-error-body.txt", body)
        summary["passed"] = False
    except Exception as exc:
        summary["error"] = repr(exc)
        summary["passed"] = False
    finally:
        try:
            summary["health_final"] = request_json(args.base_url, "GET", "/health", timeout=10)
        except Exception as exc:
            summary["health_final_error"] = repr(exc)
        save(root / "process-final.txt", process_snapshot())
        save(root / "SUMMARY.json", summary)
        print(json.dumps(summary, indent=2, sort_keys=True))

    return 0 if summary.get("passed") else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("OSAURUS_BASE_URL", "http://127.0.0.1:1337"))
    parser.add_argument("--model", required=True)
    parser.add_argument("--label", default="local")
    parser.add_argument("--artifact-root")
    parser.add_argument("--max-tokens", type=int, default=160)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--settle-seconds", type=float, default=2.0)
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
