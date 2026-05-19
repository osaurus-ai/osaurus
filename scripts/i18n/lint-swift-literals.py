#!/usr/bin/env python3
"""Flag Swift literal patterns that bypass the OsaurusCore catalog."""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCAN_DIR = ROOT / "Packages" / "OsaurusCore"
ALLOWLIST_FILE = ROOT / "scripts" / "i18n" / "lint-allowlist.txt"

PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        'Text("...") without bundle/localized',
        re.compile(r'\bText\("[A-Z][^"\n]*"\s*\)'),
    ),
    (
        '.help("...")',
        re.compile(r'\.help\("[A-Z][A-Za-z0-9 ,.\-!?\u2026]+"\)'),
    ),
    (
        '.help(Text("..."))',
        re.compile(r'\.help\(Text\("[A-Z][^"\n]*"\s*\)\)'),
    ),
    (
        'Button("...") single-line label',
        re.compile(r'\bButton\("[A-Z][^"\n]*"\s*\)'),
    ),
    (
        'Label("...") without localized initializer',
        re.compile(r'\bLabel\("[A-Z][^"\n]*",\s*systemImage:'),
    ),
    (
        'ToastManager raw literal',
        re.compile(
            r'ToastManager\.shared\.'
            r'(success|info|warning|error|loading|action|withOpenChatAction|showForAgent|loadingForAgent)'
            r'\(\s*"[A-Z][^"\n]*"'
        ),
    ),
    (
        'showToast raw literal',
        re.compile(r'\bshowToast\(\s*"[A-Z][^"\n]*"'),
    ),
    (
        'panel title/message/prompt literal',
        re.compile(r'panel\.(title|message|prompt)\s*=\s*"[A-Z][^"\n]*"'),
    ),
    (
        'NSAlert message/informative literal',
        re.compile(r'(messageText|informativeText)\s*=\s*"[A-Z][^"\n]*"'),
    ),
    (
        'notification title/body literal',
        re.compile(r'content\.(title|body)\s*=\s*"[A-Z][^"\n]*"'),
    ),
]


def load_allowlist() -> list[str]:
    if not ALLOWLIST_FILE.exists():
        return []
    entries: list[str] = []
    for raw in ALLOWLIST_FILE.read_text(encoding="utf-8").splitlines():
        value = raw.split("#", 1)[0].strip()
        if value:
            entries.append(value)
    return entries


def is_allowlisted(line: str, allowlist: list[str]) -> bool:
    return any(entry in line for entry in allowlist)


def iter_swift_files() -> list[Path]:
    return sorted(
        path
        for path in SCAN_DIR.rglob("*.swift")
        if ".build" not in path.parts
    )


def main() -> int:
    allowlist = load_allowlist()
    findings: dict[str, list[str]] = defaultdict(list)

    for path in iter_swift_files():
        rel_path = path.relative_to(ROOT)
        for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            display = f"{rel_path}:{line_no}: {line.strip()}"
            if is_allowlisted(display, allowlist):
                continue
            for label, pattern in PATTERNS:
                if pattern.search(line):
                    findings[label].append(display)

    total = sum(len(items) for items in findings.values())
    if total == 0:
        print(f"Localization lint: OK (0 suspect literals in {SCAN_DIR.relative_to(ROOT)}).")
        return 0

    print(f"Localization lint failed: {total} suspect literal(s).", file=sys.stderr)
    print(
        "Wrap with L(), Text(localized:), or .localizedHelp(), or allowlist in "
        "scripts/i18n/lint-allowlist.txt.",
        file=sys.stderr,
    )
    for label, items in findings.items():
        print(f"\n--- {label} ({len(items)} hits) ---", file=sys.stderr)
        for item in items:
            print(item, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
