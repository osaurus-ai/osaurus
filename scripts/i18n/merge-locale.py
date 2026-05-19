#!/usr/bin/env python3
"""Merge localizations for a locale from a source .xcstrings into a target .xcstrings."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog, merge_locale, save_catalog  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, required=True, help="Catalog to update")
    parser.add_argument("--source", type=Path, required=True, help="Catalog to copy from")
    parser.add_argument("--locale", required=True, help="Locale code, e.g. zh-Hans")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace existing locale entries in target",
    )
    args = parser.parse_args()

    target = load_catalog(args.target)
    source = load_catalog(args.source)
    merged, skipped = merge_locale(target, source, args.locale, overwrite=args.overwrite)

    save_catalog(args.target, target)
    print(
        f"Merged {merged} {args.locale} entries into {args.target} "
        f"(skipped {skipped} existing)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
