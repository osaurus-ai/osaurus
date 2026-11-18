#!/usr/bin/env python3
"""Generate the per-language translation status table in docs/TRANSLATORS.md.

Coverage is measured over the catalog keys that OsaurusCore Swift sources
actually reference (tests excluded) -- the same set the CI job summary from
``report-untranslated-referenced.py`` reports on -- so stale keys and unused
Xcode stubs don't count either way. A key is translated for a locale when it
has a non-empty value in state ``translated`` or ``needs_review``; the
``needs_review`` share is shown separately as the native-review backlog.

Usage (from the repo root):
    python3 scripts/i18n/coverage.py           # update docs/TRANSLATORS.md
    python3 scripts/i18n/coverage.py --stdout  # print, do not write
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from xcstrings_util import iter_string_units, load_catalog, locale_issues  # noqa: E402

CATALOG = REPO_ROOT / "Packages/OsaurusCore/Resources/Localizable.xcstrings"
INFOPLIST_CATALOG = REPO_ROOT / "App/osaurus/InfoPlist.xcstrings"
SWIFT_ROOT = REPO_ROOT / "Packages/OsaurusCore"

# Keep aligned with docs/LOCALIZATION.md "Supported locales" and the
# required list in scripts/i18n/check.sh.
LOCALES: list[tuple[str, str, str]] = [
    ("de", "German", "Maintained"),
    ("zh-Hans", "Simplified Chinese", "Maintained"),
    ("ko", "Korean", "Maintained"),
    ("ru", "Russian", "Maintained"),
    ("zh-Hant", "Traditional Chinese", "Community-maintained"),
    ("es", "Spanish", "**Help wanted**"),
    ("ja", "Japanese", "**Help wanted**"),
]
REQUIRED_LOCALES = ["de", "zh-Hans", "ko", "ru"]
TOP_SURFACES = 10

START_MARKER = "<!-- COVERAGE:START -->"
END_MARKER = "<!-- COVERAGE:END -->"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def referenced_keys(catalog: dict, swift_root: Path) -> dict[str, list[str]]:
    """Catalog key -> sorted referencing sites, for translatable keys used outside tests."""
    scanner = _load("check-swift-catalog-keys")
    report = _load("report-untranslated-referenced")
    strings = catalog.get("strings", {})
    catalog_keys = sorted(strings)
    sites: dict[str, set[str]] = {}
    for literal, refs in scanner.referenced_keys(swift_root).items():
        kept = [r for r in refs if not report.is_excluded(r, swift_root, {"Tests"})]
        if not kept:
            continue
        key = report.resolve_catalog_key(literal, catalog_keys, scanner.canonical_pattern)
        if key is None or strings[key].get("shouldTranslate") is False:
            continue
        sites.setdefault(key, set()).update(kept)
    return {key: sorted(refs, key=report._site_sort_key) for key, refs in sites.items()}


def locale_stats(catalog: dict, keys: list[str], locale: str) -> dict:
    strings = catalog.get("strings", {})
    missing = [k for k in keys if locale_issues(strings[k], locale, key=k)]
    missing_set = set(missing)
    needs_review = sum(
        1
        for k in keys
        if k not in missing_set
        and any(u.get("state") == "needs_review" for u in iter_string_units(strings[k], locale))
    )
    return {
        "translated": len(keys) - len(missing),
        "missing": missing,
        "needs_review": needs_review,
    }


def infoplist_missing(catalog: dict, locale: str) -> tuple[int, int]:
    live = {
        k: e
        for k, e in catalog.get("strings", {}).items()
        if k.strip() and e.get("extractionState") != "stale" and e.get("shouldTranslate") is not False
    }
    missing = sum(1 for k, e in live.items() if locale_issues(e, locale, key=k))
    return missing, len(live)


def render_section(catalog: dict, refs: dict[str, list[str]], infoplist: dict | None, swift_root: Path) -> str:
    report = _load("report-untranslated-referenced")
    keys = sorted(refs)
    total = len(keys) or 1
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [
        f"_Last generated {stamp} by `scripts/i18n/coverage.py`, over the {len(keys):,} UI strings "
        "the app's code references._",
        "",
        "| Language | Code | Status | Translated | Awaiting native review | Still in English |",
        "| -------- | ---- | ------ | ---------: | ---------------------: | ---------------: |",
    ]
    stats = {}
    for code, name, status in LOCALES:
        s = locale_stats(catalog, keys, code)
        stats[code] = s
        pct = 100.0 * s["translated"] / total
        lines.append(
            f"| {name} | `{code}` | {status} | {pct:.0f}% | {s['needs_review']:,} | {len(s['missing']):,} |"
        )

    gap = set.union(*(set(stats[c]["missing"]) for c in REQUIRED_LOCALES))
    if gap:
        surfaces = Counter(report.surface_for(refs[k][0], swift_root) for k in gap)
        lines += [
            "",
            f"Where the maintained languages fall back to English ({len(gap):,} strings, largest areas first):",
            "",
            "| App area (`Packages/OsaurusCore/…`) | Strings |",
            "| ----------------------------------- | ------: |",
        ]
        for surface, count in surfaces.most_common(TOP_SURFACES):
            lines.append(f"| `{surface}` | {count:,} |")
        rest = sum(surfaces.values()) - sum(n for _, n in surfaces.most_common(TOP_SURFACES))
        if rest:
            lines.append(f"| Everything else | {rest:,} |")

    if infoplist is not None:
        parts = []
        for code, _name, _status in LOCALES:
            missing, live = infoplist_missing(infoplist, code)
            if missing:
                parts.append(f"`{code}` {missing}/{live}")
        if parts:
            lines += [
                "",
                "macOS permission prompts (`App/osaurus/InfoPlist.xcstrings`) still in English: "
                + ", ".join(parts)
                + ".",
            ]
    return "\n".join(lines) + "\n"


def inject(doc: str, section: str) -> str:
    start = doc.find(START_MARKER)
    end = doc.find(END_MARKER)
    if start == -1 or end == -1 or end < start:
        raise ValueError("coverage markers not found in target document")
    return f"{doc[: start + len(START_MARKER)]}\n\n{section}\n{doc[end:]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", type=Path, default=REPO_ROOT / "docs" / "TRANSLATORS.md")
    parser.add_argument("--stdout", action="store_true", help="Print the section instead of writing --target")
    args = parser.parse_args()

    catalog = load_catalog(CATALOG)
    infoplist = load_catalog(INFOPLIST_CATALOG) if INFOPLIST_CATALOG.exists() else None
    section = render_section(catalog, referenced_keys(catalog, SWIFT_ROOT), infoplist, SWIFT_ROOT)

    if args.stdout:
        print(section)
        return 0
    try:
        updated = inject(args.target.read_text(encoding="utf-8"), section)
    except (OSError, ValueError) as exc:
        sys.exit(f"error: {args.target}: {exc}")
    args.target.write_text(updated, encoding="utf-8")
    print(f"{args.target}: updated coverage table")
    return 0


if __name__ == "__main__":
    sys.exit(main())
