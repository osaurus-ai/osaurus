#!/usr/bin/env python3
"""Ensure Swift localization literals are present in the core string catalog."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog  # noqa: E402


MARKERS = [
    'L("',
    'Text(localized: "',
    'Button(localized: "',
    'Label(localized: "',
    'localizedHelp("',
]


def unescape_swift_string(raw: str) -> str:
    # Preserve Swift interpolation syntax while unescaping quotes.
    return raw.replace(r"\"", '"')


def parse_swift_string_from_marker(line: str, marker: str, start: int) -> tuple[str, int] | None:
    index = start + len(marker)
    chars: list[str] = []
    interpolation_depth = 0
    escape_next = False

    while index < len(line):
        char = line[index]
        nxt = line[index + 1] if index + 1 < len(line) else ""

        if escape_next:
            chars.append("\\" + char)
            escape_next = False
            index += 1
            continue

        if char == "\\" and nxt == "(":
            interpolation_depth += 1
            chars.append(r"\(")
            index += 2
            continue

        if char == "\\":
            escape_next = True
            index += 1
            continue

        if interpolation_depth > 0:
            chars.append(char)
            if char == "(":
                interpolation_depth += 1
            elif char == ")":
                interpolation_depth -= 1
            index += 1
            continue

        if char == '"':
            return "".join(chars), index + 1

        chars.append(char)
        index += 1

    return None


def referenced_keys(root: Path) -> dict[str, list[str]]:
    refs: dict[str, list[str]] = {}
    for path in sorted(root.rglob("*.swift")):
        if ".build" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for line_no, line in enumerate(text.splitlines(), 1):
            for marker in MARKERS:
                search_from = 0
                while True:
                    start = line.find(marker, search_from)
                    if start == -1:
                        break
                    parsed = parse_swift_string_from_marker(line, marker, start)
                    search_from = start + len(marker)
                    if not parsed:
                        continue
                    raw_key, next_index = parsed
                    search_from = next_index
                    key = unescape_swift_string(raw_key)
                    if key.strip():
                        refs.setdefault(key, []).append(f"{path}:{line_no}")
    return refs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--swift-root", type=Path, required=True)
    parser.add_argument("--max-report", type=int, default=30)
    args = parser.parse_args()

    catalog = load_catalog(args.catalog)
    catalog_keys = set(catalog.get("strings", {}))
    refs = referenced_keys(args.swift_root)
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
