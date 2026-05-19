#!/usr/bin/env python3
"""Fill missing locale entries in an .xcstrings catalog via machine translation.

Requires: pip install deep-translator  (or use repo .venv-i18n — see docs/LOCALIZATION.md)
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog, save_catalog  # noqa: E402

try:
    from deep_translator import GoogleTranslator
except ImportError:
    print(
        "deep-translator is required. Install with:\n"
        "  python3 -m venv .venv-i18n && .venv-i18n/bin/pip install deep-translator",
        file=sys.stderr,
    )
    sys.exit(1)

BATCH_SIZE = 40
SLEEP_SEC = 0.5
PLACEHOLDER_RE = re.compile(r"(%[@lld]*|\%[0-9]*\$[@lld]*|\\\(|\\n|<#.*?#>)")


def protect_placeholders(text: str) -> tuple[str, list[str]]:
    tokens: list[str] = []

    def repl(m: re.Match[str]) -> str:
        tokens.append(m.group(0))
        return f"⟦{len(tokens) - 1}⟧"

    return PLACEHOLDER_RE.sub(repl, text), tokens


def restore_placeholders(text: str, tokens: list[str]) -> str:
    for i, tok in enumerate(tokens):
        text = text.replace(f"⟦{i}⟧", tok)
    return text


def translate_text(translator: GoogleTranslator, text: str) -> str:
    if not text.strip():
        return text
    protected, tokens = protect_placeholders(text)
    try:
        result = translator.translate(protected)
    except Exception as exc:  # noqa: BLE001
        print(f"  warn: translate failed for {text[:60]!r}: {exc}", file=sys.stderr)
        return text
    return restore_placeholders(result, tokens)


def make_string_unit(translator: GoogleTranslator, value: str) -> dict:
    return {
        "stringUnit": {
            "state": "translated",
            "value": translate_text(translator, value),
        }
    }


def translate_localization(translator: GoogleTranslator, loc: dict) -> dict:
    if "stringUnit" in loc:
        return make_string_unit(translator, loc["stringUnit"].get("value", ""))
    plural = loc.get("variations", {}).get("plural")
    if plural:
        return {
            "variations": {
                "plural": {
                    key: make_string_unit(translator, entry.get("stringUnit", {}).get("value", ""))
                    for key, entry in plural.items()
                }
            }
        }
    return loc


def english_source(key: str, entry: dict) -> str:
    en = entry.get("localizations", {}).get("en", {})
    if "stringUnit" in en:
        return en["stringUnit"].get("value") or key
    return key


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path, help="Path to Localizable.xcstrings")
    parser.add_argument("--locale", default="zh-Hans", help="Target locale code")
    parser.add_argument(
        "--translate-via",
        default="zh-CN",
        help="Google Translate language code (zh-CN for Simplified Chinese)",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int, default=0, help="Max keys (0 = all)")
    args = parser.parse_args()

    catalog = load_catalog(args.catalog)
    strings = catalog.get("strings", {})
    missing_keys = [
        k
        for k, e in strings.items()
        if k.strip() and args.locale not in e.get("localizations", {})
    ]

    print(f"Keys missing {args.locale}: {len(missing_keys)}")
    if args.dry_run:
        return 0

    translator = GoogleTranslator(source="en", target=args.translate_via)
    limit = args.limit or len(missing_keys)
    translated = 0

    for i in range(0, min(limit, len(missing_keys)), BATCH_SIZE):
        for key in missing_keys[i : i + BATCH_SIZE]:
            entry = strings[key]
            de_loc = entry.get("localizations", {}).get("de", {})
            if "variations" in de_loc:
                entry.setdefault("localizations", {})[args.locale] = translate_localization(
                    translator, de_loc
                )
            else:
                entry.setdefault("localizations", {})[args.locale] = make_string_unit(
                    translator, english_source(key, entry)
                )
            translated += 1
            if translated % 50 == 0:
                print(f"  translated {translated}/{limit}...")

        save_catalog(args.catalog, catalog)
        time.sleep(SLEEP_SEC)

    print(f"Done. Translated {translated} keys into {args.catalog}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
