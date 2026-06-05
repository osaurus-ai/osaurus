#!/usr/bin/env python3
"""Generate a translation-contributor leaderboard from merged GitHub PRs.

Maintainer-run. Requires the GitHub CLI (`gh`) to be installed and authed.

The script enumerates merged PRs, keeps the ones that touched a string catalog
(`Localizable.xcstrings` / `InfoPlist.xcstrings`), and compares each catalog at
the PR base vs head to find the strings that were genuinely translated.

Attribution is content-based and noise-resistant. A key counts as a *real*
translation for a locale only when the head value differs from the base value,
differs from the English source string, and contains an actual letter -- this
ignores whitespace reformatting, format-specifier rewrites (`%@` -> `%1$@`), and
auto-added passthrough stubs that the catalog editor injects.

Per contributor, the translated keys are unioned across their PRs and measured
as a percentage of the app's current translatable strings (coverage). A language
is shown only when coverage meets the minimum threshold (default 10%), and the
coverage is displayed in the table to keep credit fair.

Usage:
    python3 scripts/i18n/leaderboard.py                    # update docs/TRANSLATORS.md
    python3 scripts/i18n/leaderboard.py --stdout           # print, do not write
    python3 scripts/i18n/leaderboard.py --exclude alice    # drop specific authors
    python3 scripts/i18n/leaderboard.py --min-coverage 15  # require >=15% coverage
    python3 scripts/i18n/leaderboard.py --limit 1000       # scan more history
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = "osaurus-ai/osaurus"

CATALOG_BASENAMES = ("Localizable.xcstrings", "InfoPlist.xcstrings")

# Catalogs that define "the app localization" for the coverage denominator,
# resolved relative to the repo root (this file lives in scripts/i18n/).
REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATHS = (
    "Packages/OsaurusCore/Resources/Localizable.xcstrings",
    "App/osaurus/InfoPlist.xcstrings",
)

# A language is shown only when a contributor's coverage meets this share of the
# app's translatable strings. Overridable via --min-coverage.
DEFAULT_MIN_COVERAGE = 10.0

# Locale code -> display name. Keep the four "help wanted" languages and the
# maintained ones aligned with docs/LOCALIZATION.md; extras cover any other
# locales that may have landed historically so they are credited correctly.
LOCALE_NAMES: dict[str, str] = {
    "de": "German",
    "zh-Hans": "Simplified Chinese",
    "es": "Spanish",
    "ko": "Korean",
    "ja": "Japanese",
    "zh-Hant": "Traditional Chinese",
    "fr": "French",
    "it": "Italian",
    "pt": "Portuguese",
    "pt-BR": "Portuguese (Brazil)",
    "ru": "Russian",
    "ja-JP": "Japanese",
    "ko-KR": "Korean",
    "es-ES": "Spanish",
    "tr": "Turkish",
    "nl": "Dutch",
    "pl": "Polish",
    "uk": "Ukrainian",
    "ar": "Arabic",
    "hi": "Hindi",
    "th": "Thai",
    "vi": "Vietnamese",
    "id": "Indonesian",
    "cs": "Czech",
    "sv": "Swedish",
    "da": "Danish",
    "fi": "Finnish",
    "no": "Norwegian",
    "he": "Hebrew",
    "fa": "Persian",
}

# Recognized locale codes. Source language (en) is excluded so source-string
# edits never count as a translation contribution.
RECOGNIZED_LOCALES = frozenset(LOCALE_NAMES)


def run_gh(args: list[str], *, allow_failure: bool = False) -> str | None:
    try:
        result = subprocess.run(
            ["gh", *args],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        sys.exit("error: GitHub CLI (`gh`) not found. Install it and run `gh auth login`.")
    except subprocess.CalledProcessError as exc:
        if allow_failure:
            print(
                f"warning: `gh {' '.join(args)}` failed: {exc.stderr.strip()}",
                file=sys.stderr,
            )
            return None
        sys.exit(f"error: `gh {' '.join(args)}` failed:\n{exc.stderr.strip()}")
    return result.stdout


def list_merged_prs(limit: int) -> list[dict]:
    raw = run_gh(
        [
            "pr",
            "list",
            "--repo",
            REPO,
            "--state",
            "merged",
            "--limit",
            str(limit),
            "--json",
            "number,title,author,mergedAt,files",
        ]
    )
    return json.loads(raw)


def has_letter(value: str) -> bool:
    """True if the string contains a real letter (CJK included), so format- and
    punctuation-only values do not count as translation work."""
    return any(ch.isalpha() for ch in value)


def changed_catalog_paths(pr: dict) -> list[str]:
    return [
        entry.get("path", "")
        for entry in (pr.get("files") or [])
        if any(entry.get("path", "").endswith(name) for name in CATALOG_BASENAMES)
    ]


def locale_value_map(catalog: dict, path: str, locale: str) -> dict[str, tuple[str, str]]:
    """namespaced key -> (value, english source) for one locale in one catalog.

    Plural variations collapse to their base key so coverage is measured in
    distinct source strings.
    """
    out: dict[str, tuple[str, str]] = {}
    for key, entry in (catalog.get("strings") or {}).items():
        data = (entry.get("localizations") or {}).get(locale)
        if not data:
            continue
        nkey = f"{path}\u0000{key}"
        unit = data.get("stringUnit")
        if unit is not None:
            out[nkey] = (unit.get("value", ""), key)
            continue
        for variants in (data.get("variations") or {}).values():
            for vdata in (variants or {}).values():
                vunit = (vdata or {}).get("stringUnit")
                if vunit is not None:
                    out[nkey] = (vunit.get("value", ""), key)
                    break
            if nkey in out:
                break
    return out


def locales_present(catalog: dict) -> set[str]:
    locales: set[str] = set()
    for entry in (catalog.get("strings") or {}).values():
        locales.update((entry.get("localizations") or {}).keys())
    return locales & RECOGNIZED_LOCALES


_catalog_cache: dict[tuple[str, str], dict | None] = {}


def fetch_catalog_at(path: str, ref: str) -> dict | None:
    cache_key = (path, ref)
    if cache_key in _catalog_cache:
        return _catalog_cache[cache_key]
    raw = run_gh(
        [
            "api",
            f"repos/{REPO}/contents/{path}?ref={ref}",
            "-H",
            "Accept: application/vnd.github.raw",
        ],
        allow_failure=True,
    )
    catalog: dict | None = None
    if raw:
        try:
            catalog = json.loads(raw)
        except json.JSONDecodeError:
            catalog = None
    _catalog_cache[cache_key] = catalog
    return catalog


def resolve_base_sha(refs: dict) -> str | None:
    """Prefer the merge commit's first parent (always present) over the PR's
    recorded base SHA, which may have been garbage-collected after merge.
    """
    merge_sha = refs.get("merge")
    if merge_sha:
        parent = run_gh(
            [
                "api",
                f"repos/{REPO}/commits/{merge_sha}",
                "--jq",
                ".parents[0].sha",
            ],
            allow_failure=True,
        )
        if parent and parent.strip():
            return parent.strip()
    return refs.get("base")


def pr_refs(pr_number: int) -> tuple[str | None, str | None]:
    detail = run_gh(
        [
            "api",
            f"repos/{REPO}/pulls/{pr_number}",
            "--jq",
            "{base: .base.sha, head: .head.sha, merge: .merge_commit_sha}",
        ],
        allow_failure=True,
    )
    if not detail:
        return None, None
    try:
        refs = json.loads(detail)
    except json.JSONDecodeError:
        return None, None
    return resolve_base_sha(refs), refs.get("head")


def pr_translated_keys(pr: dict) -> dict[str, set[str]]:
    """locale -> set of namespaced source keys this PR genuinely translated.

    A key counts when its head value differs from base, differs from the English
    source string, and contains a real letter. Deletions and no-op reformatting
    are therefore ignored.
    """
    paths = changed_catalog_paths(pr)
    if not paths:
        return {}
    base_sha, head_sha = pr_refs(pr["number"])
    if not head_sha:
        return {}

    result: dict[str, set[str]] = {}
    for path in paths:
        head_cat = fetch_catalog_at(path, head_sha)
        if not head_cat:
            continue
        base_cat = fetch_catalog_at(path, base_sha) if base_sha else None
        for locale in locales_present(head_cat):
            head_map = locale_value_map(head_cat, path, locale)
            base_map = (
                locale_value_map(base_cat, path, locale) if base_cat else {}
            )
            for nkey, (value, english) in head_map.items():
                prev = base_map.get(nkey, (None, None))[0]
                if value != prev and value != english and has_letter(value):
                    result.setdefault(locale, set()).add(nkey)
    return result


def load_translatable_keys() -> set[str]:
    """Namespaced keys for every translatable source string currently in the app
    (the coverage denominator)."""
    keys: set[str] = set()
    for rel in CATALOG_PATHS:
        path = REPO_ROOT / rel
        if not path.exists():
            continue
        try:
            catalog = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        for key, entry in (catalog.get("strings") or {}).items():
            if not key.strip():
                continue
            if entry.get("shouldTranslate") is False:
                continue
            keys.add(f"{rel}\u0000{key}")
    return keys


def is_bot(author: dict) -> bool:
    if author.get("is_bot"):
        return True
    login = (author.get("login") or "").lower()
    return login.endswith("[bot]") or login.startswith("app/")


# Collaborator roles that count as "maintainer" and are kept off the leaderboard.
MAINTAINER_ROLES = frozenset({"admin", "maintain"})

# Logins always omitted from the community leaderboard (e.g. former team members
# who no longer appear as repo collaborators). Pass --include-maintainers to keep
# current maintainers; this list is excluded regardless.
ALWAYS_EXCLUDE = frozenset({"ritave"})


def fetch_maintainers() -> set[str]:
    """Logins of repo collaborators with admin/maintain access.

    Requires push access on the repo (the maintainer running this has it).
    Returns an empty set if the API is unavailable so the script still runs.
    """
    raw = run_gh(
        [
            "api",
            f"repos/{REPO}/collaborators",
            "--paginate",
            "--jq",
            ".[] | {login: .login, role: .role_name}",
        ],
        allow_failure=True,
    )
    if not raw:
        return set()
    maintainers: set[str] = set()
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (entry.get("role") or "").lower() in MAINTAINER_ROLES:
            login = entry.get("login")
            if login:
                maintainers.add(login)
    return maintainers


def build_leaderboard(prs: list[dict], exclude: set[str]) -> dict[str, dict]:
    """login -> {name, locales: {code: {"keys": set, "prs": set}}}"""
    contributors: dict[str, dict] = {}
    for pr in prs:
        author = pr.get("author") or {}
        login = author.get("login")
        if not login or is_bot(author) or login in exclude:
            continue
        if not changed_catalog_paths(pr):
            continue
        translated = pr_translated_keys(pr)
        if not translated:
            continue
        record = contributors.setdefault(
            login,
            {"name": author.get("name") or "", "locales": {}},
        )
        for code, keys in translated.items():
            bucket = record["locales"].setdefault(code, {"keys": set(), "prs": set()})
            bucket["keys"] |= keys
            bucket["prs"].add(pr["number"])
    return contributors


def qualified_contributors(
    contributors: dict[str, dict], total_keys: set[str], min_coverage: float
) -> list[dict]:
    """Keep only languages whose coverage meets the threshold; attach coverage."""
    total = len(total_keys) or 1
    rows: list[dict] = []
    for login, record in contributors.items():
        langs: list[dict] = []
        pr_numbers: set[int] = set()
        for code, bucket in record["locales"].items():
            covered = len(bucket["keys"] & total_keys)
            coverage = 100.0 * covered / total
            if coverage + 1e-9 < min_coverage:
                continue
            langs.append({"code": code, "coverage": coverage})
            pr_numbers |= bucket["prs"]
        if not langs:
            continue
        langs.sort(key=lambda l: (-l["coverage"], l["code"]))
        rows.append(
            {
                "login": login,
                "name": record["name"].strip(),
                "langs": langs,
                "prs": sorted(pr_numbers),
                "top": langs[0]["coverage"],
            }
        )
    rows.sort(key=lambda r: (-r["top"], r["login"].lower()))
    return rows


def render_table(rows: list[dict]) -> str:
    if not rows:
        return "_No qualifying translation contributions yet. Be the first!_"

    lines = [
        "| Contributor | Languages (coverage) | PRs |",
        "| ----------- | -------------------- | --- |",
    ]
    for row in rows:
        langs = ", ".join(
            f"{LOCALE_NAMES.get(l['code'], l['code'])} (`{l['code']}`) {l['coverage']:.0f}%"
            for l in row["langs"]
        )
        pr_links = " ".join(
            f"[#{num}](https://github.com/{REPO}/pull/{num})" for num in row["prs"]
        )
        who = f"[@{row['login']}](https://github.com/{row['login']})"
        if row["name"]:
            who = f"{who} ({row['name']})"
        lines.append(f"| {who} | {langs} | {pr_links} |")
    return "\n".join(lines)


def render_section(rows: list[dict], min_coverage: float) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    table = render_table(rows)
    return (
        f"_Last generated {stamp} by `scripts/i18n/leaderboard.py`. "
        f"Coverage is the share of the app's translatable strings a contributor "
        f"has translated; a language is listed at \u2265{min_coverage:.0f}% coverage._\n\n"
        f"{table}\n"
    )


START_MARKER = "<!-- LEADERBOARD:START -->"
END_MARKER = "<!-- LEADERBOARD:END -->"


def inject(doc: str, section: str) -> str:
    start = doc.find(START_MARKER)
    end = doc.find(END_MARKER)
    if start == -1 or end == -1 or end < start:
        raise ValueError("leaderboard markers not found in target document")
    head = doc[: start + len(START_MARKER)]
    tail = doc[end:]
    return f"{head}\n\n{section}\n{tail}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "docs" / "TRANSLATORS.md",
        help="Markdown file with LEADERBOARD markers to update.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=500,
        help="Max merged PRs to scan (most recent first).",
    )
    parser.add_argument(
        "--exclude",
        nargs="*",
        default=[],
        metavar="LOGIN",
        help="Additional GitHub logins to omit from the leaderboard.",
    )
    parser.add_argument(
        "--include-maintainers",
        action="store_true",
        help="Keep repo maintainers (admin/maintain collaborators) on the leaderboard.",
    )
    parser.add_argument(
        "--min-coverage",
        type=float,
        default=DEFAULT_MIN_COVERAGE,
        metavar="PERCENT",
        help=(
            "Minimum share of the app's translatable strings a contributor must "
            f"have translated for a language to be listed (default {DEFAULT_MIN_COVERAGE:.0f})."
        ),
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print the generated section instead of writing the target file.",
    )
    args = parser.parse_args()

    exclude = set(args.exclude) | set(ALWAYS_EXCLUDE)
    if not args.include_maintainers:
        maintainers = fetch_maintainers()
        if maintainers:
            print(
                f"excluding {len(maintainers)} maintainer(s): "
                f"{', '.join(sorted(maintainers))}",
                file=sys.stderr,
            )
        exclude |= maintainers

    total_keys = load_translatable_keys()
    if not total_keys:
        sys.exit(
            "error: no translatable strings found in the local catalogs; "
            "run from a checkout of the repo."
        )
    print(
        f"app has {len(total_keys)} translatable strings; "
        f"min coverage {args.min_coverage:.0f}%",
        file=sys.stderr,
    )

    prs = list_merged_prs(args.limit)
    contributors = build_leaderboard(prs, exclude)
    rows = qualified_contributors(contributors, total_keys, args.min_coverage)
    section = render_section(rows, args.min_coverage)

    if args.stdout:
        print(section)
        return 0

    if not args.target.exists():
        sys.exit(
            f"error: {args.target} not found. Create it with the "
            f"{START_MARKER} / {END_MARKER} markers first, or use --stdout."
        )
    doc = args.target.read_text(encoding="utf-8")
    try:
        updated = inject(doc, section)
    except ValueError as exc:
        sys.exit(f"error: {exc}")
    args.target.write_text(updated, encoding="utf-8")
    print(f"{args.target}: updated leaderboard ({len(rows)} contributor(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
