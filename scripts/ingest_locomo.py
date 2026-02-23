#!/usr/bin/env python3
"""
Ingest LoCoMo conversation data into the Osaurus memory system.

For each sample in locomo10.json, this script:
  1. Creates a deterministic agent UUID from the sample_id
  2. Iterates through conversation sessions in chronological order
  3. Pairs adjacent speaker turns as user/assistant exchanges
  4. POSTs them to the Osaurus /memory/ingest endpoint

Usage:
    python scripts/ingest_locomo.py [--data path/to/locomo10.json] [--base-url http://localhost:1337]
"""

import argparse
import json
import uuid
import time
import httpx
from pathlib import Path


def sample_id_to_uuid(sample_id: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"locomo.{sample_id}"))


def pair_turns(turns: list[dict]) -> list[dict]:
    """Pair consecutive speaker turns into user/assistant exchanges."""
    pairs = []
    i = 0
    while i < len(turns) - 1:
        pairs.append({
            "user": f"{turns[i]['speaker']}: {turns[i]['text']}",
            "assistant": f"{turns[i+1]['speaker']}: {turns[i+1]['text']}",
        })
        i += 2
    if i < len(turns):
        pairs.append({
            "user": f"{turns[i]['speaker']}: {turns[i]['text']}",
            "assistant": "(no response)",
        })
    return pairs


def ingest_sample(client: httpx.Client, base_url: str, sample: dict):
    sample_id = sample["sample_id"]
    agent_id = sample_id_to_uuid(sample_id)
    conv = sample.get("conversation", {})

    session_keys = sorted(
        [k for k in conv if k.startswith("session_") and "date_time" not in k],
        key=lambda x: int(x.split("_")[1]),
    )

    total_turns = 0
    for sk in session_keys:
        session_num = sk.split("_")[1]
        conversation_id = f"{sample_id}_session_{session_num}"
        date_str = conv.get(f"{sk}_date_time", "unknown date")
        turns = conv[sk]

        date_header_turn = {
            "user": f"[Conversation date: {date_str}]",
            "assistant": "(acknowledged)",
        }
        pairs = [date_header_turn] + pair_turns(turns)

        payload = {
            "agent_id": agent_id,
            "conversation_id": conversation_id,
            "turns": pairs,
        }

        resp = client.post(f"{base_url}/memory/ingest", json=payload, timeout=60)
        resp.raise_for_status()
        result = resp.json()
        ingested = result.get("turns_ingested", 0)
        total_turns += ingested
        print(f"  {sk} ({date_str}): {ingested} turns ingested")

    return total_turns


def main():
    parser = argparse.ArgumentParser(description="Ingest LoCoMo data into Osaurus memory")
    parser.add_argument(
        "--data",
        default="benchmarks/EasyLocomo/data/locomo10.json",
        help="Path to locomo10.json",
    )
    parser.add_argument(
        "--base-url",
        default="http://localhost:1337",
        help="Osaurus server base URL",
    )
    parser.add_argument(
        "--samples",
        type=int,
        default=None,
        help="Limit number of samples to ingest",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=1.0,
        help="Delay in seconds between sessions to allow async memory processing",
    )
    args = parser.parse_args()

    data_path = Path(args.data)
    if not data_path.exists():
        print(f"Error: {data_path} not found")
        return

    samples = json.load(open(data_path))
    if args.samples:
        samples = samples[: args.samples]

    print(f"Ingesting {len(samples)} samples into Osaurus memory at {args.base_url}")
    print()

    # Print agent ID mapping for reference
    print("Agent ID mapping:")
    for s in samples:
        sid = s["sample_id"]
        aid = sample_id_to_uuid(sid)
        print(f"  {sid} -> {aid}")
    print()

    client = httpx.Client()
    grand_total = 0

    for i, sample in enumerate(samples):
        sample_id = sample["sample_id"]
        agent_id = sample_id_to_uuid(sample_id)
        print(f"[{i+1}/{len(samples)}] Sample {sample_id} (agent: {agent_id})")

        total = ingest_sample(client, args.base_url, sample)
        grand_total += total
        print(f"  Total: {total} turns\n")

        if args.delay > 0:
            time.sleep(args.delay)

    print(f"Done! Ingested {grand_total} turns across {len(samples)} samples.")
    print()
    print("Agent IDs for EasyLocomo --no-context evaluation:")
    for s in samples:
        sid = s["sample_id"]
        aid = sample_id_to_uuid(sid)
        print(f"  {sid}: {aid}")


if __name__ == "__main__":
    main()
