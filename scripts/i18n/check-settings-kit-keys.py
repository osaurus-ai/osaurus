#!/usr/bin/env python3
"""Ensure plain-string SettingsKit labels are present in the core string catalog.

SettingsKit components take `String` titles and look them up at runtime with
`LocalizedStringKey(title)`, so Xcode never extracts them and the Swift key
check (which follows `L("…")` and friends) never sees them. A label missing
from the catalog renders in English in every locale.

Scoped to the surfaces listed in SCOPE; widen it as other screens are cleaned
up.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog  # noqa: E402


SCOPE = [
    "Views/Sharing",
    "Views/Settings/DevicesView.swift",
    "Views/Approvals/ApprovalsView.swift",
    "Views/Shared/RemoteAccessConsent.swift",
    "Views/Shared/PresenceStatusChip.swift",
    "Views/Chat/HostedSecretCard.swift",
    "Views/Agent/ShareAgentSheet.swift",
]

LABELED = re.compile(
    r'\b(?:title|subtitle|description|message|caption|hint|placeholder|actionTitle|help|label|configureLabel)'
    r':\s*"((?:[^"\\]|\\.)*)"'
)
POSITIONAL = re.compile(
    r'\b(?:SettingsGroupFooter|SettingsRowDescription|SettingsSectionHeader)\(\s*"((?:[^"\\]|\\.)*)"'
)
# `SettingsButton(.style, "Title"` and `SettingsButton(.style, flag ? "A" : "B"`.
BUTTON = re.compile(r'\bSettingsButton\(\s*\.\w+,\s*([^,{]*)')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def swift_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for entry in SCOPE:
        path = root / entry
        if path.is_dir():
            files.extend(sorted(path.rglob("*.swift")))
        elif path.exists():
            files.append(path)
    return files


def kit_literals(path: Path) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or "verbatim: true" in line:
            continue
        raws = [m.group(1) for pattern in (LABELED, POSITIONAL) for m in pattern.finditer(line)]
        for button in BUTTON.finditer(line):
            if "L(" not in button.group(1):
                raws += [m.group(1) for m in LITERAL.finditer(button.group(1))]
        for raw in raws:
            # Interpolated strings go through L(), which the Swift key check
            # already covers; lowercase values are ids or symbols.
            if not raw or "\\(" in raw or not raw[0].isupper():
                continue
            found.append((line_no, raw.replace('\\"', '"')))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--swift-root", type=Path, required=True)
    args = parser.parse_args()

    strings = load_catalog(args.catalog).get("strings", {})
    missing: list[str] = []
    checked = 0
    for path in swift_files(args.swift_root):
        for line_no, key in kit_literals(path):
            checked += 1
            if key not in strings:
                missing.append(f"{path.relative_to(args.swift_root)}:{line_no}: {key}")

    if missing:
        print(f"SettingsKit labels missing from the catalog: {len(missing)}", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(f"SettingsKit labels: OK ({checked} literals in {len(SCOPE)} scoped paths).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
