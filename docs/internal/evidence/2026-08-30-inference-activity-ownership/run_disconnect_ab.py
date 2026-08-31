#!/usr/bin/env python3
"""Live request-isolation proof for the exact Release Osaurus binary."""

from __future__ import annotations

import http.client
import json
import threading
import time
from pathlib import Path
from urllib.request import urlopen


HOST = "127.0.0.1"
PORT = 1337
MODEL = "lfm2.5-2.6b-jang_6m"
HERE = Path(__file__).resolve().parent


def payload(label: str) -> bytes:
    return json.dumps(
        {
            "model": MODEL,
            "stream": True,
            "stream_options": {"include_usage": True},
            "messages": [
                {
                    "role": "user",
                    "content": (
                        f"Output {label} then consecutive integers starting at 1, "
                        "one per line. Continue until the token limit. Do not explain."
                    ),
                }
            ],
            "temperature": 0,
            "max_tokens": 1200,
        },
        separators=(",", ":"),
    ).encode()


def stream(label: str, disconnect_after: int | None, result: dict) -> None:
    connection = http.client.HTTPConnection(HOST, PORT, timeout=120)
    started = time.time()
    first_data = None
    lines: list[str] = []
    usage = None
    finish_reason = None
    data_lines = 0
    try:
        connection.request(
            "POST",
            "/v1/chat/completions",
            body=payload(label),
            headers={"Content-Type": "application/json", "Connection": "close"},
        )
        response = connection.getresponse()
        result["http_status"] = response.status
        while True:
            raw = response.readline()
            if not raw:
                break
            text = raw.decode("utf-8", errors="replace")
            lines.append(text)
            if text.startswith("data: "):
                data_lines += 1
                data = text[6:].strip()
                if data != "[DONE]":
                    chunk = json.loads(data)
                    if first_data is None and any(
                        choice.get("delta", {}).get("content")
                        or choice.get("delta", {}).get("reasoning_content")
                        for choice in chunk.get("choices", [])
                    ):
                        first_data = time.time()
                    if chunk.get("usage"):
                        usage = chunk["usage"]
                    for choice in chunk.get("choices", []):
                        if choice.get("finish_reason"):
                            finish_reason = choice["finish_reason"]
                if disconnect_after is not None and data_lines >= disconnect_after:
                    result["client_disconnected"] = True
                    response.close()
                    connection.close()
                    break
    finally:
        connection.close()
        ended = time.time()
        (HERE / f"{label.lower()}.sse").write_text("".join(lines), encoding="utf-8")
        result.update(
            {
                "label": label,
                "started_epoch": started,
                "ended_epoch": ended,
                "duration_seconds": round(ended - started, 4),
                "ttft_seconds": None if first_data is None else round(first_data - started, 4),
                "data_lines": data_lines,
                "finish_reason": finish_reason,
                "usage": usage,
            }
        )


def activity() -> dict:
    with urlopen(f"http://{HOST}:{PORT}/admin/cache-stats", timeout=5) as response:
        return json.load(response)


def main() -> None:
    disconnected: dict = {}
    survivor: dict = {}
    thread_a = threading.Thread(target=stream, args=("DISCONNECT_A", 250, disconnected))
    thread_b = threading.Thread(target=stream, args=("SURVIVOR_B", None, survivor))
    thread_a.start()
    time.sleep(0.2)
    thread_b.start()

    timeline = []
    while thread_a.is_alive() or thread_b.is_alive():
        snapshot = activity()
        timeline.append(
            {
                "timestamp": snapshot["timestamp"],
                "active_count": snapshot["batch_diagnostics"]["active_count"],
                "activities": snapshot["inference_activity"],
            }
        )
        time.sleep(0.25)

    thread_a.join()
    thread_b.join()
    for _ in range(40):
        snapshot = activity()
        timeline.append(
            {
                "timestamp": snapshot["timestamp"],
                "active_count": snapshot["batch_diagnostics"]["active_count"],
                "activities": snapshot["inference_activity"],
            }
        )
        if not snapshot["inference_activity"] and snapshot["batch_diagnostics"]["active_count"] == 0:
            break
        time.sleep(0.25)

    proof = {
        "model": MODEL,
        "disconnected": disconnected,
        "survivor": survivor,
        "final_idle": not timeline[-1]["activities"] and timeline[-1]["active_count"] == 0,
        "timeline": timeline,
    }
    (HERE / "disconnect-ab-summary.json").write_text(
        json.dumps(proof, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(proof, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
