#!/usr/bin/env python3
"""Ensure Swift localization literals are present in the core string catalog."""

from __future__ import annotations

import argparse
import re
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

# Apple's String.LocalizationValue encodes Swift interpolations as printf-style
# format specifiers at compile time, so the catalog key the runtime looks up is
# e.g. "%lld plugins" for L("\(count) plugins"). This pattern matches one such
# format specifier (with optional length modifier like "ll" for Int64) so we
# can compare Swift literals against canonical-form keys.
FORMAT_SPEC = (
    r"%"
    r"[+\-#0 ]*"
    r"[0-9]*"
    r"(?:\.[0-9]+)?"
    r"(?:hh|h|ll|l|L|j|z|t)?"
    r"[diouxXeEfgGaAcspn@%]"
)


def unescape_swift_string(raw: str) -> str:
    # Preserve Swift interpolation syntax while unescaping quotes.
    return raw.replace(r"\"", '"')


def split_interp(s: str) -> list[tuple[str | None, str | None]]:
    """Split a catalog/literal key into (literal, None) and (None, interp) segments.

    Handles balanced parens and nested string literals inside the interpolation,
    e.g. `\\(pluginNames.first ?? "1 plugin")`.
    """
    i, out = 0, []
    while i < len(s):
        start = s.find("\\(", i)
        if start == -1:
            out.append((s[i:], None))
            return out
        out.append((s[i:start], None))
        depth, j = 1, start + 2
        while j < len(s) and depth > 0:
            c = s[j]
            if c == '"':
                j += 1
                while j < len(s) and s[j] != '"':
                    j += 2 if s[j] == "\\" else 1
                j += 1
                continue
            depth += (c == "(") - (c == ")")
            j += 1
        out.append((None, s[start:j]))
        i = j
    return out


def canonical_pattern(literal_key: str) -> re.Pattern[str]:
    """Build a regex that matches catalog keys equivalent to *literal_key*.

    Each `\\(...)` interpolation is replaced with a single format specifier, so
    `\\(count) plugins available` matches `%lld plugins available`.
    """
    parts = ["^"]
    for lit, interp in split_interp(literal_key):
        if interp is not None:
            parts.append(FORMAT_SPEC)
        else:
            parts.append(re.escape(lit))
    parts.append("$")
    return re.compile("".join(parts))


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

    missing: list[str] = []
    for key in sorted(refs):
        if key in catalog_keys:
            continue
        if "\\(" in key:
            pattern = canonical_pattern(key)
            if any(pattern.match(ck) for ck in catalog_keys):
                continue
        missing.append(key)

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
