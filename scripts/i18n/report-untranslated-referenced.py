#!/usr/bin/env python3
"""Report UI strings the Swift code references that have no usable translation.

Non-blocking companion to ``check-swift-catalog-keys.py`` (which fails CI when
a referenced key is *absent* from the catalog). This script looks at the keys
that ARE referenced from Swift and reports, per required locale, the ones that
still fall back to English at runtime:

* the locale is missing from the entry (an ``en``-only stub Xcode injected),
* the locale's value is empty,
* the locale's state is neither ``translated`` nor ``needs_review``.

``check-localizations.py`` deliberately ignores these so the catalog can grow
without breaking CI (see docs/LOCALIZATION.md, "Validation"). The result is
that such strings silently ship in English. This report makes that backlog
visible without turning it into a gate: it ALWAYS exits 0.

Output is Markdown grouped by UI surface (the first two path components under
``--swift-root``, e.g. ``Views/Settings``), largest group first, with the
referencing ``file:line`` for each key. When ``GITHUB_STEP_SUMMARY`` is set the
Markdown is appended there (and a short plain-text summary goes to stdout);
otherwise the Markdown goes to stdout. ``--annotations N`` additionally emits
up to N ``::warning`` annotations so the worst offenders show up inline on the
pull request. ``--json FILE`` writes the raw findings for other tooling.

Usage (from the repo root):

    python3 scripts/i18n/report-untranslated-referenced.py \
        --catalog Packages/OsaurusCore/Resources/Localizable.xcstrings \
        --swift-root Packages/OsaurusCore
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from xcstrings_util import load_catalog, locale_issues  # noqa: E402


def _load_key_scanner():
    """Import ``check-swift-catalog-keys.py`` (hyphenated name) as a module."""
    spec = importlib.util.spec_from_file_location(
        "check_swift_catalog_keys", HERE / "check-swift-catalog-keys.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def surface_for(reference: str, swift_root: Path) -> str:
    """``Views/Settings`` for ``<root>/Views/Settings/Foo.swift:12``."""
    path_part = reference.rsplit(":", 1)[0]
    try:
        rel = Path(path_part).resolve().relative_to(swift_root.resolve())
    except ValueError:
        rel = Path(path_part)
    parts = rel.parts
    if len(parts) >= 3:
        return "/".join(parts[:2])
    if len(parts) == 2:
        return parts[0]
    return "(root)"


def resolve_catalog_key(key: str, catalog_keys: list[str], canonical_pattern) -> str | None:
    """Exact key, else the first (sorted) canonical-form catalog key for an interpolated literal.

    ``catalog_keys`` must be sorted so the mapping is deterministic across runs.
    """
    if key in catalog_keys:
        return key
    if "\\(" in key:
        pattern = canonical_pattern(key)
        for candidate in catalog_keys:
            if pattern.match(candidate):
                return candidate
    return None


def is_excluded(reference: str, swift_root: Path, excluded_dirs: set[str]) -> bool:
    """True when any path component under ``swift_root`` is in ``excluded_dirs`` (e.g. ``Tests``)."""
    path_part = reference.rsplit(":", 1)[0]
    try:
        rel = Path(path_part).resolve().relative_to(swift_root.resolve())
    except ValueError:
        rel = Path(path_part)
    return any(part in excluded_dirs for part in rel.parts[:-1])


def collect_findings(
    catalog: dict,
    refs: dict[str, list[str]],
    locales: list[str],
    swift_root: Path,
    canonical_pattern,
    excluded_dirs: set[str] | None = None,
) -> dict:
    """Return ``{surface: {catalog_key: {"refs": [...], "locales": {locale: reason}}}}``.

    Each catalog key appears at most once, under the surface of its first
    (sorted) reference, with every referencing site listed. Only keys with at
    least one untranslated locale appear. Keys that are missing from the
    catalog entirely are skipped: ``check-swift-catalog-keys.py`` already
    fails CI for those. References inside ``excluded_dirs`` (test sources by
    default) are dropped first, so a key referenced only from tests is not a
    translator backlog item.
    """
    excluded = {"Tests"} if excluded_dirs is None else excluded_dirs
    strings = catalog.get("strings", {})
    catalog_keys = sorted(strings)

    # 1. Fold every Swift literal onto its catalog key, collecting all sites.
    sites_by_key: dict[str, set[str]] = defaultdict(set)
    for literal, references in refs.items():
        kept = [ref for ref in references if not is_excluded(ref, swift_root, excluded)]
        if not kept:
            continue
        catalog_key = resolve_catalog_key(literal, catalog_keys, canonical_pattern)
        if catalog_key is None:
            continue
        sites_by_key[catalog_key].update(kept)

    # 2. Keep the keys that fall back to English somewhere; group by surface.
    findings: dict[str, dict[str, dict]] = defaultdict(dict)
    for catalog_key, sites in sites_by_key.items():
        entry = strings[catalog_key]
        if entry.get("shouldTranslate") is False:
            continue
        per_locale: dict[str, str] = {}
        for locale in locales:
            issues = locale_issues(entry, locale, key=catalog_key)
            if issues:
                per_locale[locale] = issues[0]
        if not per_locale:
            continue
        ordered_sites = sorted(sites, key=_site_sort_key)
        surface = surface_for(ordered_sites[0], swift_root)
        findings[surface][catalog_key] = {"refs": ordered_sites, "locales": per_locale}
    return findings


def _site_sort_key(reference: str) -> tuple[str, int]:
    path_part, _, line = reference.rpartition(":")
    return (path_part, int(line) if line.isdigit() else 0)


def relative_ref(reference: str, repo_root: Path) -> str:
    path_part, _, line = reference.rpartition(":")
    try:
        rel = Path(path_part).resolve().relative_to(repo_root.resolve())
    except ValueError:
        rel = Path(path_part)
    return f"{rel}:{line}" if line else str(rel)


def render_markdown(
    findings: dict,
    locales: list[str],
    total_referenced: int,
    repo_root: Path,
    max_keys_per_surface: int,
) -> str:
    keys_total = sum(len(keys) for keys in findings.values())
    per_locale = {locale: 0 for locale in locales}
    for keys in findings.values():
        for info in keys.values():
            for locale in info["locales"]:
                per_locale[locale] += 1

    lines = ["## Untranslated UI strings referenced from Swift", ""]
    if keys_total == 0:
        lines.append(
            f"All {total_referenced} referenced catalog keys have a usable translation "
            f"in {', '.join(locales)}."
        )
        return "\n".join(lines) + "\n"

    lines.append(
        f"{keys_total} of {total_referenced} referenced catalog keys fall back to English "
        "in at least one required locale. This report is informational and does not fail CI."
    )
    lines.append("")
    lines.append("| Locale | Keys falling back to English |")
    lines.append("| ------ | ---------------------------: |")
    for locale in locales:
        lines.append(f"| `{locale}` | {per_locale[locale]} |")
    lines.append("")
    lines.append("| UI surface | Keys |")
    lines.append("| ---------- | ---: |")
    ordered = sorted(findings.items(), key=lambda item: (-len(item[1]), item[0]))
    for surface, keys in ordered:
        lines.append(f"| `{surface}` | {len(keys)} |")
    lines.append("")

    for surface, keys in ordered:
        lines.append(f"<details><summary><code>{surface}</code> — {len(keys)} key(s)</summary>")
        lines.append("")
        shown = sorted(keys.items(), key=lambda item: item[0].lower())
        if max_keys_per_surface and len(shown) > max_keys_per_surface:
            hidden = len(shown) - max_keys_per_surface
            shown = shown[:max_keys_per_surface]
        else:
            hidden = 0
        for key, info in shown:
            missing = ", ".join(f"`{loc}`: {reason}" for loc, reason in sorted(info["locales"].items()))
            first_ref = relative_ref(info["refs"][0], repo_root)
            extra = f" (+{len(info['refs']) - 1} more site(s))" if len(info["refs"]) > 1 else ""
            lines.append(f"- `{key}` — {missing} — {first_ref}{extra}")
        if hidden:
            lines.append(f"- … and {hidden} more key(s) in this surface")
        lines.append("")
        lines.append("</details>")
        lines.append("")
    return "\n".join(lines) + "\n"


def render_annotations(findings: dict, repo_root: Path, limit: int) -> list[str]:
    """``::warning file=…,line=…::…`` lines for the largest surfaces first."""
    out: list[str] = []
    ordered = sorted(findings.items(), key=lambda item: (-len(item[1]), item[0]))
    for _surface, keys in ordered:
        for key, info in sorted(keys.items(), key=lambda item: item[0].lower()):
            if len(out) >= limit:
                return out
            ref = relative_ref(info["refs"][0], repo_root)
            file_part, _, line = ref.rpartition(":")
            locales = ", ".join(sorted(info["locales"]))
            message = f"Untranslated in {locales}: {key!r} falls back to English"
            location = f"file={file_part},line={line}" if line.isdigit() else f"file={ref}"
            out.append(f"::warning {location},title=i18n::{message}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--swift-root", type=Path, required=True)
    parser.add_argument(
        "--locales",
        default="de,zh-Hans,ko,ru",
        help="Comma-separated required locales (default matches scripts/i18n/check.sh)",
    )
    parser.add_argument(
        "--max-keys-per-surface",
        type=int,
        default=40,
        help="Cap the keys listed per UI surface in the Markdown (0 = no cap)",
    )
    parser.add_argument(
        "--annotations",
        type=int,
        default=0,
        help="Emit up to N GitHub ::warning annotations on stdout (0 = none)",
    )
    parser.add_argument(
        "--exclude-dirs",
        default="Tests",
        help="Comma-separated directory names under --swift-root whose references are ignored (default: Tests)",
    )
    parser.add_argument("--json", type=Path, help="Also write the raw findings to this file")
    parser.add_argument(
        "--summary",
        type=Path,
        help="Append the Markdown here instead of $GITHUB_STEP_SUMMARY / stdout",
    )
    args = parser.parse_args()

    locales = [loc.strip() for loc in args.locales.split(",") if loc.strip()]
    scanner = _load_key_scanner()
    catalog = load_catalog(args.catalog)
    refs = scanner.referenced_keys(args.swift_root)
    repo_root = HERE.parent.parent

    excluded_dirs = {d.strip() for d in args.exclude_dirs.split(",") if d.strip()}
    findings = collect_findings(
        catalog, refs, locales, args.swift_root, scanner.canonical_pattern, excluded_dirs
    )
    markdown = render_markdown(findings, locales, len(refs), repo_root, args.max_keys_per_surface)

    if args.json:
        args.json.write_text(json.dumps(findings, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    summary_path = args.summary or (Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None)
    keys_total = sum(len(keys) for keys in findings.values())
    if summary_path:
        with summary_path.open("a", encoding="utf-8") as handle:
            handle.write(markdown)
        print(
            f"{args.catalog}: {keys_total} referenced key(s) fall back to English in "
            f"{', '.join(locales)} (details in the job summary; non-blocking)"
        )
    else:
        sys.stdout.write(markdown)

    for annotation in render_annotations(findings, repo_root, args.annotations):
        print(annotation)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
