#!/usr/bin/env python3
"""Run focused PR 1147 live multi-turn API sequences.

This helper is intentionally an artifact collector, not a pass/fail oracle. It
drives the VLM/Omni sequence required by the PR 1147 live gate: image+text,
text-only, different-image, repeat-image, video, and audio turns. It records raw
request/response bodies, health/cache snapshots, process memory, and extracted
output tails for later human review.
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".heic"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm", ".mkv"}
AUDIO_EXTS = {".wav", ".mp3", ".flac", ".m4a", ".aac", ".ogg"}


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def safe_label(value: str) -> str:
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in value)


def mime_type(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if ext == ".png":
        return "image/png"
    if ext == ".webp":
        return "image/webp"
    if ext == ".gif":
        return "image/gif"
    if ext == ".heic":
        return "image/heic"
    if ext == ".mov":
        return "video/quicktime"
    if ext == ".webm":
        return "video/webm"
    if ext in VIDEO_EXTS:
        return "video/mp4"
    if ext == ".wav":
        return "audio/wav"
    if ext == ".mp3":
        return "audio/mpeg"
    if ext == ".flac":
        return "audio/flac"
    if ext == ".m4a":
        return "audio/m4a"
    if ext in AUDIO_EXTS:
        return "audio/" + ext.lstrip(".")
    return "application/octet-stream"


def media_kind(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in IMAGE_EXTS:
        return "image"
    if ext in VIDEO_EXTS:
        return "video"
    if ext in AUDIO_EXTS:
        return "audio"
    raise ValueError(f"unsupported media extension for {path}")


def data_url(path: Path) -> str:
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime_type(path)};base64,{encoded}"


def media_descriptor(path: Path) -> dict[str, Any]:
    resolved = path.expanduser().resolve()
    kind = media_kind(resolved)
    return {
        "kind": kind,
        "path": str(resolved),
        "mime_type": mime_type(resolved),
        "format": resolved.suffix.lower().lstrip("."),
    }


def build_vlm_turn_plan(
    *,
    image: Path | None = None,
    different_image: Path | None = None,
    video: Path | None = None,
    audio: Path | None = None,
    prompt: str = "Describe the media in one short sentence.",
    different_image_prompt: str | None = None,
) -> list[dict[str, Any]]:
    turns: list[dict[str, Any]] = []
    if image is not None:
        turns.append(
            {
                "label": "t1_image_text",
                "prompt": prompt,
                "media": [media_descriptor(image)],
            }
        )
        turns.append(
            {
                "label": "t2_text_only",
                "prompt": "Follow up in one sentence without using any new image.",
                "media": [],
            }
        )
        if different_image is not None:
            turns.append(
                {
                    "label": "t3_different_image",
                    "prompt": different_image_prompt or prompt,
                    "media": [media_descriptor(different_image)],
                }
            )
        turns.append(
            {
                "label": "t4_repeat_image",
                "prompt": "Describe this repeated image again in one short sentence.",
                "media": [media_descriptor(image)],
            }
        )
    else:
        turns.append(
            {
                "label": "t1_text_only",
                "prompt": prompt,
                "media": [],
            }
        )

    if video is not None:
        turns.append(
            {
                "label": "t5_video",
                "prompt": "Describe the video in one short sentence.",
                "media": [media_descriptor(video)],
            }
        )
    if audio is not None:
        turns.append(
            {
                "label": "t6_audio",
                "prompt": "Transcribe or summarize the audio in one short sentence.",
                "media": [media_descriptor(audio)],
            }
        )
    return turns


def chat_content_for_turn(turn: dict[str, Any]) -> str | list[dict[str, Any]]:
    media = turn["media"]
    if not media:
        return turn["prompt"]
    parts: list[dict[str, Any]] = [{"type": "text", "text": turn["prompt"]}]
    for item in media:
        path = Path(item["path"])
        if item["kind"] == "image":
            parts.append({"type": "image_url", "image_url": {"url": data_url(path)}})
        elif item["kind"] == "video":
            parts.append({"type": "video_url", "video_url": {"url": data_url(path)}})
        elif item["kind"] == "audio":
            parts.append(
                {
                    "type": "input_audio",
                    "input_audio": {
                        "data": base64.b64encode(path.read_bytes()).decode("ascii"),
                        "format": item["format"],
                    },
                }
            )
    return parts


def responses_content_for_turn(turn: dict[str, Any]) -> str | list[dict[str, Any]]:
    media = turn["media"]
    if not media:
        return turn["prompt"]
    parts: list[dict[str, Any]] = [{"type": "input_text", "text": turn["prompt"]}]
    for item in media:
        path = Path(item["path"])
        if item["kind"] == "image":
            parts.append({"type": "input_image", "image_url": data_url(path)})
        elif item["kind"] == "video":
            parts.append({"type": "input_image", "image_url": data_url(path), "detail": "video"})
        elif item["kind"] == "audio":
            # Open Responses in this app has image/text parts only. Keep audio
            # out of Responses requests instead of fabricating an unsupported
            # schema; Chat Completions covers the Omni audio row.
            parts.append({"type": "input_text", "text": "[audio supplied on chat route only]"})
    return parts


def chat_request_body(
    *,
    model: str,
    messages: list[dict[str, Any]],
    turn: dict[str, Any],
    stream: bool,
    max_tokens: int | None,
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": model,
        "messages": messages + [{"role": "user", "content": chat_content_for_turn(turn)}],
        "stream": stream,
    }
    if max_tokens is not None:
        body["max_tokens"] = max_tokens
    return body


def responses_request_body(
    *,
    model: str,
    messages: list[dict[str, Any]],
    turn: dict[str, Any],
    stream: bool,
    max_tokens: int | None,
) -> dict[str, Any]:
    items: list[dict[str, Any]] = []
    for message in messages:
        role = message.get("role", "user")
        if role not in {"user", "assistant", "system"}:
            continue
        items.append({"type": "message", "role": role, "content": message.get("content", "")})
    items.append({"type": "message", "role": "user", "content": responses_content_for_turn(turn)})
    body: dict[str, Any] = {"model": model, "input": items, "stream": stream}
    if max_tokens is not None:
        body["max_output_tokens"] = max_tokens
    return body


def user_history_message(route_name: str, turn: dict[str, Any]) -> dict[str, Any]:
    if route_name == "responses":
        return {"role": "user", "content": responses_content_for_turn(turn)}
    return {"role": "user", "content": chat_content_for_turn(turn)}


def request_json_or_body(
    base_url: str,
    path: str,
    body: dict[str, Any] | None,
    out_dir: Path,
    label: str,
    timeout: float,
) -> dict[str, Any]:
    url = base_url.rstrip("/") + path
    headers = {"User-Agent": "osaurus-pr1147-live-sequence/1.0"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
        write_json(out_dir / f"{label}.request.json", body)
    started = time.time()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if body is not None else "GET")
    result: dict[str, Any] = {"path": path, "url": url, "label": label}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read()
            result.update(
                {
                    "ok": 200 <= resp.status < 300,
                    "status": resp.status,
                    "reason": resp.reason,
                    "content_type": resp.headers.get("content-type"),
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
                "headers": dict(exc.headers.items()),
                "error": "http_error",
            }
        )
    except Exception as exc:  # noqa: BLE001 - artifact collector.
        payload = b""
        result.update(
            {
                "ok": False,
                "status": None,
                "reason": type(exc).__name__,
                "content_type": None,
                "headers": {},
                "error": str(exc),
            }
        )
    body_path = out_dir / f"{label}.body"
    body_path.write_bytes(payload)
    result["elapsed_ms"] = round((time.time() - started) * 1000, 3)
    result["body_path"] = str(body_path)
    result["body_bytes"] = len(payload)
    result["body_excerpt"] = payload[:4000].decode("utf-8", errors="replace")
    result["output_tail"] = extract_output_tail(payload, path)
    return result


def extract_output_tail(payload: bytes, path: str) -> str:
    text = payload.decode("utf-8", errors="replace")
    if not text:
        return ""
    if "text/event-stream" in text[:100].lower() or text.startswith("data:"):
        return text[-800:]
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return text[-800:]
    if path == "/v1/chat/completions":
        content = obj.get("choices", [{}])[0].get("message", {}).get("content")
        return str(content or "")[-800:]
    if path == "/v1/responses":
        output = obj.get("output", [])
        pieces: list[str] = []
        for item in output:
            for part in item.get("content", []) if isinstance(item, dict) else []:
                if isinstance(part, dict):
                    pieces.append(str(part.get("text") or ""))
        return "\n".join(pieces)[-800:]
    return text[-800:]


def parse_ps_line(line: str) -> dict[str, Any] | None:
    parts = line.strip().split(maxsplit=3)
    if len(parts) < 4:
        return None
    try:
        pid = int(parts[0])
        ppid = int(parts[1])
        rss_kb = int(parts[2])
    except ValueError:
        return None
    return {
        "pid": pid,
        "ppid": ppid,
        "rss_kb": rss_kb,
        "command": parts[3],
    }


def memory_snapshot() -> list[dict[str, Any]]:
    proc = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,command="],
        check=False,
        capture_output=True,
        text=True,
    )
    rows: list[dict[str, Any]] = []
    for line in proc.stdout.splitlines()[1:]:
        stripped = line.strip()
        lower = stripped.lower()
        if not stripped or ("osaurus" not in lower and "vmlx" not in lower and "runbench" not in lower):
            continue
        row = parse_ps_line(stripped)
        if row is not None:
            rows.append(row)
    return rows


def snapshot(base_url: str, out_dir: Path, label: str, timeout: float) -> dict[str, Any]:
    snap_dir = out_dir / "snapshots" / safe_label(label)
    snap_dir.mkdir(parents=True, exist_ok=True)
    health = request_json_or_body(base_url, "/health", None, snap_dir, "health", timeout)
    cache = request_json_or_body(base_url, "/admin/cache-stats", None, snap_dir, "cache_stats", timeout)
    memory_path = snap_dir / "memory.json"
    write_json(memory_path, {"label": label, "timestamp": time.time(), "processes": memory_snapshot()})
    return {"label": label, "health": health, "cache_stats": cache, "memory_path": str(memory_path)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:4242")
    parser.add_argument("--model", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--different-image", type=Path)
    parser.add_argument("--video", type=Path)
    parser.add_argument("--audio", type=Path)
    parser.add_argument("--prompt", default="Describe the media in one short sentence.")
    parser.add_argument(
        "--different-image-prompt",
        help=(
            "Prompt for the different-image turn. Defaults to --prompt. Use an "
            "explicit latest-image prompt when the row needs to disambiguate "
            "new media from prior assistant descriptions."
        ),
    )
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--routes", default="chat,responses", help="Comma-separated: chat,responses")
    parser.add_argument("--stream", action="store_true", help="Use streaming route bodies.")
    parser.add_argument("--no-snapshots", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    turns = build_vlm_turn_plan(
        image=args.image,
        different_image=args.different_image,
        video=args.video,
        audio=args.audio,
        prompt=args.prompt,
        different_image_prompt=args.different_image_prompt,
    )
    routes = {route.strip() for route in args.routes.split(",") if route.strip()}
    route_specs: list[tuple[str, str]] = []
    if "chat" in routes:
        route_specs.append(("chat", "/v1/chat/completions"))
    if "responses" in routes:
        route_specs.append(("responses", "/v1/responses"))

    route_histories: dict[str, list[dict[str, Any]]] = {name: [] for name, _ in route_specs}
    results: list[dict[str, Any]] = []
    snapshots: list[dict[str, Any]] = []
    if not args.no_snapshots:
        snapshots.append(snapshot(args.base_url, out_dir, "before_sequence", args.timeout))

    for turn_index, turn in enumerate(turns, start=1):
        for route_name, path in route_specs:
            label = safe_label(f"{turn_index:02d}_{turn['label']}_{route_name}")
            if not args.no_snapshots:
                snapshots.append(snapshot(args.base_url, out_dir, f"before_{label}", args.timeout))
            messages = route_histories[route_name]
            if route_name == "chat":
                body = chat_request_body(
                    model=args.model,
                    messages=messages,
                    turn=turn,
                    stream=args.stream,
                    max_tokens=args.max_tokens,
                )
            else:
                body = responses_request_body(
                    model=args.model,
                    messages=messages,
                    turn=turn,
                    stream=args.stream,
                    max_tokens=args.max_tokens,
                )
            result = request_json_or_body(args.base_url, path, body, out_dir, label, args.timeout)
            result["turn"] = turn
            result["route_name"] = route_name
            results.append(result)
            messages.append(user_history_message(route_name, turn))
            assistant_tail = result.get("output_tail") or ""
            if assistant_tail:
                messages.append({"role": "assistant", "content": assistant_tail})
            if not args.no_snapshots:
                snapshots.append(snapshot(args.base_url, out_dir, f"after_{label}", args.timeout))

    if not args.no_snapshots:
        snapshots.append(snapshot(args.base_url, out_dir, "after_sequence", args.timeout))

    manifest = {
        "base_url": args.base_url,
        "model": args.model,
        "stream": args.stream,
        "max_tokens": args.max_tokens,
        "turns": turns,
        "snapshots": snapshots,
        "results": results,
    }
    write_json(out_dir / "live_sequence_probe.json", manifest)

    lines = [
        "# PR 1147 Live Sequence Probe",
        "",
        f"Model: `{args.model}`",
        f"Base URL: `{args.base_url}`",
        f"Stream: `{str(args.stream).lower()}`",
        "",
        "| Turn | Route | Status | Bytes | Output Tail |",
        "|---|---|---:|---:|---|",
    ]
    for row in results:
        tail = (row.get("output_tail") or "").replace("\n", " ")[:160]
        lines.append(f"| {row['turn']['label']} | {row['path']} | {row['status']} | {row['body_bytes']} | {tail} |")
    lines.append("")
    (out_dir / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {len(results)} live sequence rows to {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
