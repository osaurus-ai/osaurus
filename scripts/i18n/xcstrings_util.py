"""Shared helpers for Osaurus .xcstrings tooling."""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path

ALLOW_EMPTY_KEYS = frozenset()


def load_catalog(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_catalog(path: Path, catalog: dict) -> None:
    path.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def iter_string_units(entry: dict, locale: str):
    loc = entry.get("localizations", {}).get(locale)
    if not loc:
        return
    if "stringUnit" in loc:
        yield loc["stringUnit"]
    for plural_entry in loc.get("variations", {}).get("plural", {}).values():
        if "stringUnit" in plural_entry:
            yield plural_entry["stringUnit"]


def locale_issues(entry: dict, locale: str, *, key: str) -> list[str]:
    issues: list[str] = []
    loc = entry.get("localizations", {}).get(locale)
    if not loc:
        return [f"missing {locale} localization"]

    units = list(iter_string_units(entry, locale))
    if not units:
        if loc.get("variations"):
            return [f"missing {locale} plural forms"]
        return [f"missing {locale} string units"]

    for unit in units:
        state = unit.get("state", "")
        value = unit.get("value", "")
        if state not in ("translated", "needs_review"):
            issues.append(f"{locale} state is {state!r}")
        if not value.strip() and key not in ALLOW_EMPTY_KEYS:
            issues.append(f"{locale} value is empty")
        if (
            value.strip()
            and locale == "zh-Hans"
            and key not in ALLOW_EMPTY_KEYS
            and value == key
            and state == "translated"
            and "%" not in key
            and len(key) > 8
            and key.isascii()
        ):
            issues.append(f"{locale} value equals English key (likely untranslated)")
    return issues


def is_maintained_entry(key: str, entry: dict, required_locales: list[str]) -> bool:
    """Only keys with at least one required locale are enforced (skips en-only Xcode stubs)."""
    if not key.strip() or key in ALLOW_EMPTY_KEYS:
        return False
    locs = entry.get("localizations") or {}
    if not locs:
        return False
    return bool(set(locs) & set(required_locales))


def is_stale_entry(entry: dict) -> bool:
    return entry.get("extractionState") == "stale"


def stale_keys(catalog: dict) -> list[str]:
    return sorted(
        key
        for key, entry in catalog.get("strings", {}).items()
        if is_stale_entry(entry)
    )


def check_catalog(catalog: dict, required_locales: list[str]) -> list[str]:
    errors: list[str] = []
    for key, entry in sorted(catalog.get("strings", {}).items()):
        if not is_maintained_entry(key, entry, required_locales):
            continue
        for locale in required_locales:
            for issue in locale_issues(entry, locale, key=key):
                errors.append(f"{key}: {issue}")
    return errors


def merge_locale(
    target: dict,
    source: dict,
    locale: str,
    *,
    overwrite: bool = False,
) -> tuple[int, int]:
    """Copy *locale* from *source* into *target* for keys that already exist. Returns (merged, skipped)."""
    merged = 0
    skipped = 0
    target_strings = target.setdefault("strings", {})
    source_strings = source.get("strings", {})

    for key, source_entry in source_strings.items():
        if key not in target_strings:
            continue
        source_loc = source_entry.get("localizations", {}).get(locale)
        if not source_loc:
            continue

        target_locs = target_strings[key].setdefault("localizations", {})
        if locale in target_locs and not overwrite:
            skipped += 1
            continue

        target_locs[locale] = deepcopy(source_loc)
        merged += 1

    return merged, skipped
