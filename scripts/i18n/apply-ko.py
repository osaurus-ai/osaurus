#!/usr/bin/env python3
"""Apply a locale's translations into an .xcstrings catalog.

Reads one or more translation maps produced by translators (JSON objects of
``{key: "value"}`` for singular strings or ``{key: {category: "value"}}`` for
plurals) plus the export manifest (which lists ``verbatim_keys`` that should be
copied from English unchanged), then:

* injects the locale into every maintained key that is missing it,
* validates placeholder parity (same %-specifiers + newline count as English),
* validates full coverage of the maintained/translatable set,
* writes the catalog back in Xcode's exact serialization so the diff only adds
  the new locale.

Use ``--validate-only`` to check translation maps without writing.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog  # noqa: E402

# Apple/C/Swift format specifiers. Flags exclude space and apostrophe on
# purpose: a literal percent sign followed by a word (e.g. "85% of") must not be
# mistaken for a "% o" specifier.
PLACEHOLDER_RE = re.compile(
    r"%(?:\d+\$)?[#0\-+]*[\d.*]*(?:hh|h|ll|l|q|L|z|t|j)?[@diouxXeEfFgGaAcsp%]"
)
POSITIONAL_RE = re.compile(r"^%\d+\$")


def dump_xcode(catalog: dict) -> str:
    """Serialize exactly like Xcode's String Catalog editor (no trailing newline)."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))


def placeholder_signature(text: str) -> tuple:
    """A reorder-tolerant signature of format specifiers + newline count."""
    text = text or ""
    tokens = [POSITIONAL_RE.sub("%", t) for t in PLACEHOLDER_RE.findall(text)]
    return (tuple(sorted(Counter(tokens).items())), text.count("\n"))


def en_singular(key: str, entry: dict) -> str:
    en = entry.get("localizations", {}).get("en", {})
    unit = en.get("stringUnit")
    if unit and isinstance(unit.get("value"), str) and unit["value"].strip():
        return unit["value"]
    return key


def en_plural(entry: dict) -> dict | None:
    plural = entry.get("localizations", {}).get("en", {}).get("variations", {}).get("plural")
    if not plural:
        return None
    return {cat: unit.get("stringUnit", {}).get("value", "") for cat, unit in plural.items()}


def make_unit(value: str, state: str) -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def make_plural(values: dict, state: str) -> dict:
    return {"variations": {"plural": {cat: make_unit(v, state) for cat, v in values.items()}}}


def load_maps(paths: list[Path]) -> dict:
    merged: dict = {}
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise SystemExit(f"{path}: expected a JSON object mapping key->value")
        for key, value in data.items():
            merged[key] = value
    return merged


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--locale", default="ko")
    parser.add_argument("--reference-locales", default="de,zh-Hans")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--maps", type=Path, nargs="+", required=True, help="Translation map JSON files")
    parser.add_argument("--state", default="translated")
    parser.add_argument("--verbatim-state", default="needs_review")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()

    refs = [r.strip() for r in args.reference_locales.split(",") if r.strip()]
    catalog = load_catalog(args.catalog)
    strings = catalog.get("strings", {})

    # Sanity: confirm our serializer reproduces the catalog before edits.
    if dump_xcode(catalog) != args.catalog.read_text(encoding="utf-8"):
        print(
            f"warning: {args.catalog} is not in canonical Xcode format; "
            "diff may be larger than the new locale.",
            file=sys.stderr,
        )

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    verbatim_keys = set(manifest.get("verbatim_keys", []))
    translations = load_maps(args.maps)

    errors: list[str] = []
    translated = 0
    verbatim_applied = 0

    for key, entry in strings.items():
        if not key.strip():
            continue
        locs = entry.get("localizations") or {}
        if not all(r in locs for r in refs):
            continue
        if args.locale in locs:
            continue

        loc_value: dict | None = None

        if key in verbatim_keys or entry.get("shouldTranslate") is False:
            plural = en_plural(entry)
            if plural:
                loc_value = make_plural(plural, args.verbatim_state)
            else:
                loc_value = make_unit(en_singular(key, entry), args.verbatim_state)
            verbatim_applied += 1
        elif key in translations:
            value = translations[key]
            en_pl = en_plural(entry)
            if en_pl:
                if not isinstance(value, dict):
                    errors.append(f"{key}: expected plural object, got string")
                    continue
                missing_cats = set(en_pl) - set(value)
                if missing_cats:
                    errors.append(f"{key}: missing plural categories {sorted(missing_cats)}")
                    continue
                for cat, en_val in en_pl.items():
                    ko_val = value.get(cat, "")
                    if not str(ko_val).strip():
                        errors.append(f"{key}[{cat}]: empty translation")
                    if placeholder_signature(en_val) != placeholder_signature(str(ko_val)):
                        errors.append(
                            f"{key}[{cat}]: placeholder mismatch en={en_val!r} ko={ko_val!r}"
                        )
                loc_value = make_plural({cat: value[cat] for cat in en_pl}, args.state)
            else:
                if isinstance(value, dict):
                    errors.append(f"{key}: expected string, got plural object")
                    continue
                if not str(value).strip():
                    errors.append(f"{key}: empty translation")
                en_val = en_singular(key, entry)
                if placeholder_signature(en_val) != placeholder_signature(str(value)):
                    errors.append(f"{key}: placeholder mismatch en={en_val!r} ko={value!r}")
                loc_value = make_unit(value, args.state)
            translated += 1
        else:
            errors.append(f"{key}: MISSING translation")
            continue

        locs[args.locale] = loc_value
        # Re-sort locale codes so the new locale lands in Xcode's alphabetical order.
        entry["localizations"] = {code: locs[code] for code in sorted(locs)}

    print(
        f"{args.catalog}: translated={translated} verbatim={verbatim_applied} "
        f"errors={len(errors)}"
    )
    if errors:
        for err in errors[:40]:
            print(f"  - {err}", file=sys.stderr)
        if len(errors) > 40:
            print(f"  ... and {len(errors) - 40} more", file=sys.stderr)

    if args.validate_only:
        return 1 if errors else 0
    if errors:
        print("Refusing to write catalog with errors. Fix maps and re-run.", file=sys.stderr)
        return 1

    args.catalog.write_text(dump_xcode(catalog), encoding="utf-8")
    print(f"Wrote {args.catalog}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
