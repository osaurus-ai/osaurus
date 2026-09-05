#!/usr/bin/env python3
"""Ensure literals handed to parameters that get localized are in the catalog.

`check-swift-catalog-keys.py` recognises five literal markers (`L("`,
`Text(localized: "`, ...). It therefore cannot see a literal that is localized
one call frame later:

    struct SettingsToggle: View {
        let title: String
        var body: some View { Text(LocalizedStringKey(title), bundle: .module) }
    }
    SettingsToggle(title: "Group Thinking & Tool Activity")   // <- a catalog key

    private func policyRow(label: String, value: String, detail: String) -> some View {
        Text(LocalizedStringKey(label), bundle: .module)
        Text(LocalizedStringKey(detail), bundle: .module)
    }
    policyRow(label: "Usable conversation budget", ...)       // <- a catalog key

Both forms look up the literal at runtime, both are invisible to the marker
scan, and Xcode's automatic extraction misses them for the same reason, so the
string silently falls back to English in every locale. #2213 fixed 22 of these
and #2224 another 16; this check keeps the next one from shipping.

Two passes:

  1. collect declarations that localize one of their own parameters -- a
     `struct X: View` whose stored property reaches `LocalizedStringKey(...)`,
     or a `func f(...)` that does the same with an argument;
  2. walk every call site of those declarations and look each literal argument
     up in the catalog.

Only literals reaching a parameter proven to be localized in pass 1 are
reported, so log messages, SF Symbol names and telemetry fields never enter the
result.
"""

from __future__ import annotations

import argparse
import bisect
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from xcstrings_util import load_catalog  # noqa: E402


TYPE_DECL = re.compile(
    r"^(?:public |internal |private |fileprivate )?struct\s+(\w+)\s*:\s*[^{]*\bView\b[^{]*\{",
    re.MULTILINE,
)
FUNC_DECL = re.compile(
    r"(?:public |internal |private |fileprivate |static |final )*func\s+(\w+)\s*\(([^)]*)\)"
)
# `let title: String` / `var badge: String?` inside a type body
STORED_PROP = re.compile(r"^\s*(?:let|var)\s+(\w+)\s*:\s*String\b", re.MULTILINE)
LOCALIZED_USE = re.compile(r"LocalizedStringKey\(\s*(?:self\.)?(\w+)")

# A literal that is not a UI string even though it reaches a localized
# parameter: code samples, format fragments, and anything the catalog should
# not carry. Kept beside the other i18n allowlist for the same reason.
DEFAULT_ALLOWLIST = Path(__file__).resolve().parent / "localizing-params-allowlist.txt"

MAX_BODY = 8000  # a View body or helper longer than this is not what we are looking for


def source_files(root: Path):
    """Shipping Swift sources: no build products, no test targets."""
    for path in root.rglob("*.swift"):
        parts = set(path.parts)
        if ".build" in parts or "Tests" in parts:
            continue
        if path.name.endswith("Tests.swift"):
            continue
        yield path


def strip_comments(text: str) -> str:
    """Blank out // and /* */ so commented-out call sites are not scanned."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def brace_body(text: str, open_index: int) -> str:
    depth, j = 0, open_index
    limit = min(len(text), open_index + MAX_BODY)
    while j < limit:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[open_index : j + 1]
        j += 1
    return text[open_index:limit]


def param_labels(params: str) -> list[tuple[str, str]]:
    """[(call-site label, internal name)] for each String parameter.

    `_ title: String` is positional, so its call-site label is "" and a literal
    may appear as the first argument with no label.
    """
    out = []
    for chunk in params.split(","):
        chunk = chunk.strip()
        if ":" not in chunk:
            continue
        head, _, _type = chunk.partition(":")
        names = head.split()
        if not names:
            continue
        if len(names) >= 2:
            label, internal = names[0], names[1]
            out.append(("" if label == "_" else label, internal))
        else:
            out.append((names[0], names[0]))
    return out


def localizing_decls(root: Path) -> dict[str, set[str]]:
    """name -> set of call-site labels whose literal becomes a catalog key.

    "" in the set means the first positional argument is localized.
    """
    decls: dict[str, set[str]] = {}
    for path in sorted(source_files(root)):
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))

        for match in TYPE_DECL.finditer(text):
            body = brace_body(text, text.index("{", match.end() - 1))
            localized = set(LOCALIZED_USE.findall(body))
            props = set(STORED_PROP.findall(body))
            hit = localized & props
            if hit:
                decls.setdefault(match.group(1), set()).update(hit)

        for match in FUNC_DECL.finditer(text):
            open_index = text.find("{", match.end())
            if open_index == -1:
                continue
            body = brace_body(text, open_index)
            localized = set(LOCALIZED_USE.findall(body))
            labels = {
                label
                for label, internal in param_labels(match.group(2))
                if internal in localized
            }
            if labels:
                decls.setdefault(match.group(1), set()).update(labels)
    return decls


LITERAL = r'"((?:[^"\\]|\\.)*)"'

SIMPLE_SWIFT_ESCAPES = {
    "0": "\0",
    "\\": "\\",
    "t": "\t",
    "n": "\n",
    "r": "\r",
    '"': '"',
    "'": "'",
}


def decode_swift_literal(literal: str) -> str:
    """Return the runtime text for a conventional Swift string literal body."""
    out: list[str] = []
    index = 0
    while index < len(literal):
        if literal[index] != "\\" or index + 1 >= len(literal):
            out.append(literal[index])
            index += 1
            continue

        escape = literal[index + 1]
        if escape in SIMPLE_SWIFT_ESCAPES:
            out.append(SIMPLE_SWIFT_ESCAPES[escape])
            index += 2
            continue

        if escape == "u" and index + 2 < len(literal) and literal[index + 2] == "{":
            close = literal.find("}", index + 3)
            scalar = literal[index + 3 : close] if close != -1 else ""
            if re.fullmatch(r"[0-9A-Fa-f]{1,8}", scalar):
                value = int(scalar, 16)
                if value <= 0x10FFFF and not 0xD800 <= value <= 0xDFFF:
                    out.append(chr(value))
                    index = close + 1
                    continue

        # Keep interpolation and unknown escapes in source form. Interpolated
        # literals are filtered later because they are not fixed catalog keys.
        out.append("\\")
        index += 1

    return "".join(out)


def call_site_literals(root: Path, decls: dict[str, set[str]]) -> dict[str, list[str]]:
    """literal -> ["path:line", ...] for every literal reaching a localized label."""
    if not decls:
        return {}
    # One alternation over every declaration name, so each file is scanned once
    # instead of once per declaration.
    call = re.compile(r"\b(" + "|".join(map(re.escape, sorted(decls))) + r")\s*\(")
    decl_of = re.compile(r"(?:func|struct)\s+$")
    found: dict[str, list[str]] = {}
    for path in sorted(source_files(root)):
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        newlines = None
        for match in call.finditer(text):
            name = match.group(1)
            # a declaration is not a call site
            if decl_of.search(text[max(0, match.start() - 12) : match.start()]):
                continue
            window = text[match.end() : match.end() + 400]
            hits = []
            for label in decls[name]:
                if label == "":
                    first = re.match(r"\s*" + LITERAL, window)
                    if first:
                        hits.append(first.group(1))
                else:
                    labelled = re.search(re.escape(label) + r"\s*:\s*" + LITERAL, window)
                    if labelled:
                        hits.append(labelled.group(1))
            if not hits:
                continue
            if newlines is None:
                newlines = [i for i, c in enumerate(text) if c == "\n"]
            line = bisect.bisect_right(newlines, match.start()) + 1
            for literal in hits:
                literal = decode_swift_literal(literal)
                found.setdefault(literal, []).append(f"{path}:{line}")
    return found


# A placeholder field often shows an example value rather than a phrase. These
# are never translation targets -- an example URL, a sample number or a path
# fragment reads the same in every locale -- so they are skipped by shape
# instead of forcing an allowlist entry each time one is added.
EXAMPLE_VALUE = re.compile(
    r"""^(?:
        (?:https?://|www\.)\S*      # an example URL
      | [\d.,]+                     # a sample number
      | /[\w./-]*                   # a path or route fragment
    )$""",
    re.VERBOSE,
)

# A glob list such as `docs/**, *.md` shown as a field placeholder. Path
# characters and wildcards only; the caller also requires at least one wildcard,
# so an ordinary word like `Include` is never caught by this.
GLOB = re.compile(r"^[\w.*/-]+(?:,\s*[\w.*/-]+)*$")


def is_translatable(literal: str) -> bool:
    """False for literals that are not UI prose and never become catalog keys."""
    if "\\(" in literal or literal.startswith("%") or len(literal) < 3:
        return False
    if EXAMPLE_VALUE.match(literal):
        return False
    if "*" in literal and GLOB.match(literal):
        return False
    return True


def load_allowlist(path: Path) -> set[str]:
    if not path.exists():
        return set()
    out = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(decode_swift_literal(line))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--swift-root", type=Path, required=True)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    parser.add_argument("--max-report", type=int, default=30)
    args = parser.parse_args()

    catalog_keys = set(load_catalog(args.catalog).get("strings", {}))
    allowed = load_allowlist(args.allowlist)

    decls = localizing_decls(args.swift_root)
    literals = call_site_literals(args.swift_root, decls)

    missing = []
    for literal in sorted(literals):
        if literal in catalog_keys or literal in allowed:
            continue
        if not is_translatable(literal):
            continue
        missing.append(literal)

    if missing:
        print(
            f"{args.catalog}: {len(missing)} literal(s) passed to a localized "
            f"parameter but missing from the catalog",
            file=sys.stderr,
        )
        limit = len(missing) if args.max_report == 0 else args.max_report
        for literal in missing[:limit]:
            print(f"  - {literal} ({literals[literal][0]})", file=sys.stderr)
        if limit < len(missing):
            print(f"  ... and {len(missing) - limit} more", file=sys.stderr)
        print(
            "\nAdd the string to the catalog, or to "
            f"{args.allowlist.name} if it is not a UI string.",
            file=sys.stderr,
        )
        return 1

    print(
        f"{args.catalog}: OK ({len(decls)} localizing declarations, "
        f"{len(literals)} literal arguments checked)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
