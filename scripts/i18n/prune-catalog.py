#!/usr/bin/env python3
"""Remove unmaintained keys from an .xcstrings catalog.

Drops entries with no localizations, blank keys, and en-only Xcode auto-extraction stubs.
Keeps keys that have at least one of the required locales (e.g. de, zh-Hans).
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import is_maintained_entry, is_stale_entry, load_catalog, save_catalog  # noqa: E402


def prune_catalog(
    catalog: dict,
    required_locales: list[str],
    *,
    remove_stale: bool = False,
) -> tuple[dict, Counter]:
    reasons: Counter = Counter()
    kept: dict = {}

    for key, entry in catalog.get("strings", {}).items():
        if remove_stale and is_stale_entry(entry):
            reasons["stale"] += 1
            continue
        if is_maintained_entry(key, entry, required_locales):
            kept[key] = entry
            continue
        if not key.strip():
            reasons["blank_key"] += 1
        elif not entry.get("localizations"):
            reasons["no_localizations"] += 1
        else:
            reasons["en_only_or_other"] += 1

    catalog["strings"] = kept
    return catalog, reasons


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path, help="Path to Localizable.xcstrings")
    parser.add_argument(
        "--required-locales",
        default="de,zh-Hans",
        help="Comma-separated locale codes that mark a maintained key",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report counts without writing",
    )
    parser.add_argument(
        "--remove-stale",
        action="store_true",
        help='Also remove entries with extractionState: "stale"',
    )
    parser.add_argument(
        "--fail-if-changed",
        action="store_true",
        help="Exit with status 1 if pruning would remove any keys",
    )
    args = parser.parse_args()

    locales = [loc.strip() for loc in args.required_locales.split(",") if loc.strip()]
    catalog = load_catalog(args.catalog)
    before = len(catalog.get("strings", {}))
    pruned, reasons = prune_catalog(catalog, locales, remove_stale=args.remove_stale)
    after = len(pruned.get("strings", {}))

    print(f"{args.catalog}: {before} keys -> {after} keys (removed {before - after})")
    for reason, count in sorted(reasons.items()):
        print(f"  {reason}: {count}")

    removed = before - after

    if args.dry_run:
        return 1 if args.fail_if_changed and removed else 0

    save_catalog(args.catalog, pruned)
    print(f"Wrote {args.catalog}")
    return 1 if args.fail_if_changed and removed else 0


if __name__ == "__main__":
    sys.exit(main())
