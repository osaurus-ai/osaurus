#!/usr/bin/env python3
"""Collect PR 1147 HTTP route artifacts from a running Osaurus server.

The default mode is metadata-only and does not generate text. Use
--run-generation with --model only when a model is intentionally loaded or the
row is meant to trigger just-in-time loading.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_GETS = [
    "/health",
    "/v1/models",
    "/models",
    "/tags",
    "/mcp/health",
    "/admin/cache-stats",
]


def safe_name(method: str, path: str) -> str:
    clean = path.strip("/").replace("/", "_") or "root"
    return f"{method.lower()}_{clean}"


def labeled_name(method: str, path: str, label: str | None) -> str:
    base = safe_name(method, path)
    if not label:
        return base
    clean = "".join(c if c.isalnum() or c in "._-" else "_" for c in label)
    return f"{base}.{clean}"


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def memory_snapshot() -> list[dict[str, Any]]:
    proc = subprocess.run(
        ["ps", "-axo", "pid,ppid,rss,etimes,comm,args"],
        check=False,
        capture_output=True,
        text=True,
    )
    rows: list[dict[str, Any]] = []
    for line in proc.stdout.splitlines()[1:]:
        stripped = line.strip()
        lower = stripped.lower()
        if not stripped or (
            "osaurus" not in lower
            and "vmlx" not in lower
            and "runbench" not in lower
            and "swift-frontend" not in lower
        ):
            continue
        parts = stripped.split(maxsplit=5)
        if len(parts) < 6:
            continue
        rows.append(
            {
                "pid": int(parts[0]),
                "ppid": int(parts[1]),
                "rss_kb": int(parts[2]),
                "etimes_s": int(parts[3]),
                "comm": parts[4],
                "args": parts[5],
            }
        )
    return rows


def write_memory_snapshot(out_dir: Path, label: str) -> str:
    path = out_dir / "memory" / f"{label}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(path, {"label": label, "timestamp": time.time(), "processes": memory_snapshot()})
    return str(path)


def request(
    base_url: str,
    method: str,
    path: str,
    out_dir: Path,
    *,
    body: dict[str, Any] | None = None,
    label: str | None = None,
    timeout: float = 30.0,
) -> dict[str, Any]:
    url = base_url.rstrip("/") + path
    data = None
    headers = {"User-Agent": "osaurus-pr1147-live-gate/1.0"}
    request_body_path = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
        request_body_path = out_dir / f"{labeled_name(method, path, label)}.request.json"
        write_json(request_body_path, body)

    started = time.time()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    result: dict[str, Any] = {
        "method": method,
        "path": path,
        "label": label,
        "url": url,
        "request_body_path": str(request_body_path) if request_body_path else None,
    }
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read()
            result.update(
                {
                    "ok": 200 <= resp.status < 300,
                    "status": resp.status,
                    "reason": resp.reason,
                    "content_type": resp.headers.get("content-type"),
                    "elapsed_ms": round((time.time() - started) * 1000, 3),
                    "headers": dict(resp.headers.items()),
                }
            )
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        result.update(
            {
                "ok": False,
                "status": exc.code,
                "reason": exc.reason,
                "content_type": exc.headers.get("content-type"),
                "elapsed_ms": round((time.time() - started) * 1000, 3),
                "headers": dict(exc.headers.items()),
                "error": "http_error",
            }
        )
    except Exception as exc:  # noqa: BLE001 - this is an artifact collector.
        result.update(
            {
                "ok": False,
                "status": None,
                "reason": type(exc).__name__,
                "content_type": None,
                "elapsed_ms": round((time.time() - started) * 1000, 3),
                "headers": {},
                "error": str(exc),
            }
        )
        payload = b""

    body_path = out_dir / f"{labeled_name(method, path, label)}.body"
    body_path.write_bytes(payload)
    result["body_path"] = str(body_path)
    result["body_bytes"] = len(payload)
    result["body_excerpt"] = payload[:4000].decode("utf-8", errors="replace")
    return result


def generation_bodies(model: str, prompt: str, max_tokens: int | None) -> list[tuple[str, str, dict[str, Any], str]]:
    chat_messages = [{"role": "user", "content": prompt}]
    chat_base: dict[str, Any] = {"model": model, "messages": chat_messages}
    messages_base: dict[str, Any] = {
        "model": model,
        "messages": chat_messages,
        "max_tokens": max_tokens or 256,
    }
    responses_base: dict[str, Any] = {"model": model, "input": prompt}
    ollama_chat_base: dict[str, Any] = {"model": model, "messages": chat_messages}
    ollama_generate_base: dict[str, Any] = {"model": model, "prompt": prompt}
    if max_tokens is not None:
        chat_base["max_tokens"] = max_tokens
        responses_base["max_output_tokens"] = max_tokens
        ollama_chat_base["options"] = {"num_predict": max_tokens}
        ollama_generate_base["options"] = {"num_predict": max_tokens}

    rows: list[tuple[str, str, dict[str, Any], str]] = []
    for stream in [False, True]:
        body = dict(chat_base)
        body["stream"] = stream
        rows.append(("POST", "/v1/chat/completions", body, f"stream_{str(stream).lower()}"))
    for stream in [False, True]:
        body = dict(responses_base)
        body["stream"] = stream
        rows.append(("POST", "/v1/responses", body, f"stream_{str(stream).lower()}"))
    for stream in [False, True]:
        body = dict(messages_base)
        body["stream"] = stream
        rows.append(("POST", "/v1/messages", body, f"stream_{str(stream).lower()}"))
    for stream in [False, True]:
        body = dict(ollama_chat_base)
        body["stream"] = stream
        rows.append(("POST", "/api/chat", body, f"stream_{str(stream).lower()}"))
    for stream in [False, True]:
        body = dict(ollama_generate_base)
        body["stream"] = stream
        rows.append(("POST", "/api/generate", body, f"stream_{str(stream).lower()}"))
    return rows


def collect_snapshot(
    base_url: str,
    out_dir: Path,
    label: str,
    timeout: float,
) -> dict[str, Any]:
    snapshot_dir = out_dir / "snapshots" / label
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    rows = [
        request(base_url, "GET", "/health", snapshot_dir, timeout=timeout),
        request(base_url, "GET", "/admin/cache-stats", snapshot_dir, timeout=timeout),
    ]
    memory_path = write_memory_snapshot(out_dir, label)
    return {
        "label": label,
        "health": rows[0],
        "cache_stats": rows[1],
        "memory_path": memory_path,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:1337")
    parser.add_argument(
        "--output-dir",
        default="docs/internal/live-gates/pr1147/http-route-probe",
    )
    parser.add_argument("--model", help="Model id/path to use for generation rows.")
    parser.add_argument("--prompt", default="Say exactly: osaurus route probe")
    parser.add_argument("--max-tokens", type=int)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--run-generation",
        action="store_true",
        help="POST generation routes. Requires --model.",
    )
    parser.add_argument(
        "--no-snapshots",
        action="store_true",
        help="Do not collect before/after /health, /admin/cache-stats, and process-memory snapshots.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.run_generation and not args.model:
        raise SystemExit("--run-generation requires --model")

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    snapshots = []
    for path in DEFAULT_GETS:
        results.append(request(args.base_url, "GET", path, out_dir, timeout=args.timeout))
    if args.run_generation:
        if not args.no_snapshots:
            snapshots.append(collect_snapshot(args.base_url, out_dir, "before_generation", args.timeout))
        for index, (method, path, body, label) in enumerate(
            generation_bodies(args.model, args.prompt, args.max_tokens),
            start=1,
        ):
            route_label = f"{index:02d}_{label}"
            if not args.no_snapshots:
                snapshots.append(collect_snapshot(args.base_url, out_dir, f"before_{route_label}", args.timeout))
            results.append(
                request(
                    args.base_url,
                    method,
                    path,
                    out_dir,
                    body=body,
                    label=route_label,
                    timeout=args.timeout,
                )
            )
            if not args.no_snapshots:
                snapshots.append(collect_snapshot(args.base_url, out_dir, f"after_{route_label}", args.timeout))
        if not args.no_snapshots:
            snapshots.append(collect_snapshot(args.base_url, out_dir, "after_generation", args.timeout))

    manifest = {
        "base_url": args.base_url,
        "model": args.model,
        "run_generation": args.run_generation,
        "prompt": args.prompt,
        "max_tokens": args.max_tokens,
        "snapshots": snapshots,
        "results": results,
    }
    write_json(out_dir / "http_route_probe.json", manifest)
    lines = [
        "# PR 1147 HTTP Route Probe",
        "",
        f"Base URL: `{args.base_url}`",
        f"Generation rows: `{str(args.run_generation).lower()}`",
        "",
        "| Method | Path | Label | Status | Content-Type | Bytes |",
        "|---|---|---|---:|---|---:|",
    ]
    for row in results:
        lines.append(
            f"| {row['method']} | {row['path']} | {row.get('label') or ''} | {row['status']} | "
            f"{row['content_type'] or ''} | {row['body_bytes']} |"
        )
    if snapshots:
        lines.extend(
            [
                "",
                f"Snapshots: `{len(snapshots)}` before/after health, cache-stats, and process-memory captures.",
            ]
        )
    lines.append("")
    (out_dir / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {len(results)} HTTP probe rows to {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
