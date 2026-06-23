#!/usr/bin/env python3
"""Export catalog strings missing a target locale into batched JSON files.

Used to hand bulk translation off to LLM translators. For every "maintained"
key (one that already has all --reference-locales) that lacks --locale and is
translatable, this emits the English source text plus any comment context.

Keys with ``shouldTranslate: false`` are reported in the manifest under
``verbatim_keys`` and are NOT emitted for translation -- they should be copied
from the English source verbatim at apply time.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog  # noqa: E402


def en_source(key: str, entry: dict) -> str:
    """English text for a singular key: explicit en unit, else the key itself."""
    en = entry.get("localizations", {}).get("en", {})
    unit = en.get("stringUnit")
    if unit and isinstance(unit.get("value"), str) and unit["value"].strip():
        return unit["value"]
    return key


def en_plural(entry: dict) -> dict | None:
    """English plural forms ({category: value}) if the entry is pluralized."""
    plural = entry.get("localizations", {}).get("en", {}).get("variations", {}).get("plural")
    if not plural:
        return None
    return {cat: unit.get("stringUnit", {}).get("value", "") for cat, unit in plural.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path, help="Path to the .xcstrings catalog")
    parser.add_argument("--locale", default="ko", help="Target locale to fill")
    parser.add_argument(
        "--reference-locales",
        default="de,zh-Hans",
        help="Only export keys that already have ALL of these (the maintained set)",
    )
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=300)
    parser.add_argument("--tag", default="main", help="Filename prefix for batch files")
    args = parser.parse_args()

    refs = [r.strip() for r in args.reference_locales.split(",") if r.strip()]
    catalog = load_catalog(args.catalog)
    strings = catalog.get("strings", {})

    items: list[dict] = []
    verbatim: list[str] = []
    skipped_unmaintained = 0

    for key, entry in strings.items():
        if not key.strip():
            continue
        locs = entry.get("localizations") or {}
        if refs and not all(r in locs for r in refs):
            skipped_unmaintained += 1
            continue
        if args.locale in locs:
            continue
        if entry.get("shouldTranslate") is False:
            verbatim.append(key)
            continue

        item: dict = {"key": key}
        comment = entry.get("comment")
        if comment:
            item["comment"] = comment
        plural = en_plural(entry)
        if plural:
            item["plural"] = plural
        else:
            item["en"] = en_source(key, entry)
        items.append(item)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    batches = [items[i : i + args.batch_size] for i in range(0, len(items), args.batch_size)]
    batch_files: list[str] = []
    for idx, batch in enumerate(batches, 1):
        path = args.out_dir / f"{args.tag}-batch-{idx:02d}.json"
        path.write_text(json.dumps(batch, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        batch_files.append(str(path))

    manifest = {
        "catalog": str(args.catalog),
        "locale": args.locale,
        "reference_locales": refs,
        "to_translate": len(items),
        "plural_keys": [it["key"] for it in items if "plural" in it],
        "batches": len(batches),
        "batch_files": batch_files,
        "verbatim_keys": sorted(verbatim),
        "skipped_unmaintained": skipped_unmaintained,
    }
    (args.out_dir / f"{args.tag}-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(
        f"{args.catalog}: to_translate={len(items)} "
        f"verbatim={len(verbatim)} batches={len(batches)} "
        f"skipped_unmaintained={skipped_unmaintained}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
