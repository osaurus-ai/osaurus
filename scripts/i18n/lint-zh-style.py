#!/usr/bin/env python3
"""Style linter for Chinese locales in Localizable.xcstrings.

Rules (zh-Hans by default):
  spacing  - insert a space between CJK and Latin/digit/placeholder runs
  quotes   - ASCII "straight" quote pairs around text -> curly “ ” (‘ ’)
  colon    - halfwidth colon after a CJK character -> fullwidth ：

Values inside backtick spans and URLs are left untouched. Only stringUnit
values are rewritten; state fields are never modified. The catalog is written
back byte-exactly (indent=2, separators=(',', ' : '), no trailing newline) so
diffs contain only the changed value lines.

Usage:
  python3 scripts/i18n/lint-zh-style.py --check            # report, exit 1 if dirty
  python3 scripts/i18n/lint-zh-style.py --fix              # apply fixes in place
  python3 scripts/i18n/lint-zh-style.py --fix --locale zh-Hant
  python3 scripts/i18n/lint-zh-style.py --check --exclude-keys keys.txt
"""
import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_CATALOG = Path(__file__).resolve().parents[2] / "Packages/OsaurusCore/Resources/Localizable.xcstrings"

CJK = r"㐀-䶿一-鿿"
LATIN = r"A-Za-z0-9"
# spans we must never touch or space-pad inside
PROTECTED = re.compile(r"`[^`]*`|https?://\S+|www\.\S+")
PLACEHOLDER = re.compile(r"%(\d+\$)?[#0\- +']*\d*(\.\d+)?(hh|h|ll|l|q|z|t|L)?[@dDuUxXoOfeEgGaAcCsSpF]|%%")

def protect(value):
    """Replace protected spans with sentinels; return (masked, spans)."""
    spans = []
    def repl(m):
        spans.append(m.group(0))
        return f"\x00{len(spans)-1}\x00"
    return PROTECTED.sub(repl, value), spans

def unprotect(value, spans):
    for i, s in enumerate(spans):
        value = value.replace(f"\x00{i}\x00", s)
    return value

def fix_spacing(value):
    # treat each placeholder as an opaque Latin-like token
    masked = PLACEHOLDER.sub(lambda m: f"\x01{m.group(0)}\x01", value)
    masked = re.sub(rf"([{CJK}])([\x01{LATIN}%])", r"\1 \2", masked)
    masked = re.sub(rf"([\x01{LATIN}%@])([{CJK}])", r"\1 \2", masked)
    return masked.replace("\x01", "")

def fix_quotes(value):
    if value.count('"') and value.count('"') % 2 == 0:
        value = re.sub(r'"([^"]*)"', "“\\1”", value)
    if re.search(rf"'[^']*[{CJK}][^']*'", value):
        value = re.sub(rf"'([^']*[{CJK}][^']*)'", "‘\\1’", value)
    return value

def fix_colon(value):
    return re.sub(rf"([{CJK}]):(?!//)\s?", "\\1：", value)

def apply_rules(value, rules):
    masked, spans = protect(value)
    if "quotes" in rules:
        masked = fix_quotes(masked)
    if "colon" in rules:
        masked = fix_colon(masked)
    if "spacing" in rules:
        masked = fix_spacing(masked)
    return unprotect(masked, spans)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report violations, exit 1 if any")
    mode.add_argument("--fix", action="store_true", help="rewrite the catalog in place")
    ap.add_argument("--locale", default="zh-Hans")
    ap.add_argument("--rules", default="spacing,quotes,colon", help="comma-separated subset of rules")
    ap.add_argument("--exclude-keys", type=Path, help="file with one key per line (JSON-encoded or raw) to skip")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    args = ap.parse_args()

    rules = set(args.rules.split(","))
    excluded = set()
    if args.exclude_keys:
        for line in args.exclude_keys.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                excluded.add(json.loads(line))
            except ValueError:
                excluded.add(line)

    raw = args.catalog.read_bytes()
    catalog = json.loads(raw)
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")).encode()
    if rendered != raw:
        sys.exit("refusing to run: catalog does not round-trip byte-exactly; check serialization recipe")

    changed = []
    for key, entry in catalog["strings"].items():
        if key in excluded or entry.get("shouldTranslate") is False:
            continue
        unit = entry.get("localizations", {}).get(args.locale, {}).get("stringUnit")
        if not unit or "value" not in unit:
            continue
        new = apply_rules(unit["value"], rules)
        if new != unit["value"]:
            changed.append((key, unit["value"], new))
            if args.fix:
                unit["value"] = new

    for key, old, new in changed:
        print(f"[{args.locale}] {key[:60]!r}\n  - {old}\n  + {new}")
    print(f"\n{len(changed)} value(s) {'fixed' if args.fix else 'need fixing'}")

    if args.fix and changed:
        args.catalog.write_bytes(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")).encode())
    if args.check and changed:
        sys.exit(1)

if __name__ == "__main__":
    main()
