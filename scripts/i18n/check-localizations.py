#!/usr/bin/env python3
"""Validate .xcstrings catalogs have required locale coverage."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import check_catalog, load_catalog, stale_keys  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument(
        "--required-locales",
        required=True,
        help="Comma-separated locale codes, e.g. de,zh-Hans",
    )
    parser.add_argument(
        "--max-report",
        type=int,
        default=30,
        help="Max issues to print (0 = all)",
    )
    parser.add_argument(
        "--strict-stale",
        action="store_true",
        help='Fail if any keys have extractionState: "stale"',
    )
    args = parser.parse_args()

    catalog = load_catalog(args.catalog)
    locales = [loc.strip() for loc in args.required_locales.split(",") if loc.strip()]
    errors = check_catalog(catalog, locales)
    stale = stale_keys(catalog)
    if args.strict_stale:
        errors.extend(f"{key}: extractionState is stale" for key in stale)

    if errors:
        print(f"{args.catalog}: {len(errors)} issue(s)", file=sys.stderr)
        limit = len(errors) if args.max_report == 0 else args.max_report
        for err in errors[:limit]:
            print(f"  - {err}", file=sys.stderr)
        if limit < len(errors):
            print(f"  ... and {len(errors) - limit} more", file=sys.stderr)
        return 1

    key_count = len(catalog.get("strings", {}))
    print(f"{args.catalog}: OK ({key_count} keys, locales: {', '.join(locales)})")
    if stale:
        print(f"{args.catalog}: warning: {len(stale)} stale key(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
