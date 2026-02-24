#!/usr/bin/env python3
"""Clear LOCOMO conversation chunks from Osaurus memory (for re-ingestion)."""

import argparse
import json
import httpx
from pathlib import Path

from locomo_utils import sample_id_to_uuid


def main():
    parser = argparse.ArgumentParser(description="Clear LOCOMO chunks from Osaurus")
    parser.add_argument(
        "--data",
        default="benchmarks/EasyLocomo/data/locomo10.json",
        help="Path to locomo10.json (used for agent ID mapping)",
    )
    parser.add_argument(
        "--base-url",
        default="http://localhost:1337",
        help="Osaurus server base URL",
    )
    args = parser.parse_args()

    data_path = Path(args.data)
    if not data_path.exists():
        print(f"Error: {data_path} not found")
        return

    with open(data_path) as f:
        samples = json.load(f)

    print(f"Clearing chunks for {len(samples)} LOCOMO agents…")
    with httpx.Client() as client:
        for sample in samples:
            agent_id = sample_id_to_uuid(sample["sample_id"])
            resp = client.post(
                f"{args.base_url}/memory/clear-chunks",
                json={"agent_id": agent_id},
                timeout=30,
            )
            resp.raise_for_status()
            print(f"  {sample['sample_id']} ({agent_id}): cleared")

    print("Done!")


if __name__ == "__main__":
    main()
