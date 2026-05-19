#!/usr/bin/env python3
"""Ensure Swift localization literals are present in the core string catalog."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog, swift_referenced_keys  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--swift-root", type=Path, required=True)
    parser.add_argument("--max-report", type=int, default=30)
    args = parser.parse_args()

    catalog = load_catalog(args.catalog)
    catalog_keys = set(catalog.get("strings", {}))
    refs = swift_referenced_keys(args.swift_root)
    missing = sorted(key for key in refs if key not in catalog_keys)

    if missing:
        print(f"{args.catalog}: {len(missing)} Swift localization key(s) missing from catalog", file=sys.stderr)
        limit = len(missing) if args.max_report == 0 else args.max_report
        for key in missing[:limit]:
            print(f"  - {key} ({refs[key][0]})", file=sys.stderr)
        if limit < len(missing):
            print(f"  ... and {len(missing) - limit} more", file=sys.stderr)
        return 1

    print(f"{args.catalog}: OK ({len(refs)} Swift localization keys referenced)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
