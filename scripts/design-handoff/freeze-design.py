#!/usr/bin/env python3
"""Validate an editable Inspector export and optionally install it as the app default."""

import argparse
import hashlib
import json
import re
import tempfile
from pathlib import Path


MODES = ("light", "dark")
LIBRARY = Path("Packages/OsaurusCore/Models/Theme/DesignLibrary/LibraryResources/design-library.json")


def read(path):
    return json.loads(path.read_text())


def check(condition, message):
    if not condition:
        raise ValueError(message)


def value_at(tokens, path, mode):
    parts = path.split(".")
    for end in range(len(parts), 0, -1):
        key = ".".join(parts[:end])
        if key in tokens:
            value = tokens[key][mode]
            for part in parts[end:]:
                value = value[int(part)] if isinstance(value, list) else value[part]
            return value
    raise ValueError(f"Unknown token path: {path}")


def validate(document, shipped):
    for key in ("schemaVersion", "sourceRevision", "baselineSHA256"):
        check(document[key] == shipped[key], f"{key} differs. Use an export for this source revision.")
    tokens = document["tokens"]
    mappings = document["mappings"]
    check(set(mappings) == set(shipped["mappings"]), "Assignment keys differ. Update the source contract before publishing.")
    check(set(document.get("explicitAssignments", [])) <= set(mappings), "An explicit assignment has no mapping.")
    for path, role in mappings.items():
        previous = shipped["mappings"][path]
        check(role in tokens, f"Unknown token for {path}: {role}")
        check(tokens[role]["type"] == shipped["tokens"][previous]["type"], f"Wrong token type for {path}: {role}")
    for name, previous in shipped["tokens"].items():
        check(name in tokens and tokens[name]["type"] == previous["type"], f"Missing token or incompatible type: {name}")
    for name, token in tokens.items():
        for mode in MODES:
            check(mode in token, f"Missing {mode} token value: {name}")
            if token["type"] == "color":
                check(re.fullmatch(r"#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?", token[mode]), f"Invalid color: {name} ({mode})")

    primitives = document["primitives"]
    aliases = document["colorAliases"]
    scalar_primitives = document["scalarPrimitives"]
    value_aliases = document["valueAliases"]
    for name, primitive in primitives.items():
        for mode in MODES:
            check(re.fullmatch(r"#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?", primitive[mode]), f"Invalid primitive: {name} ({mode})")

    def resolve_color(path, mode, visited=frozenset()):
        check(path not in visited, f"Color alias cycle at {path} ({mode})")
        target = aliases.get(path, {}).get(mode, "")
        if target.startswith("@"):
            return resolve_color(target[1:], mode, visited | {path})
        return primitives[target][mode] if target else value_at(tokens, path, mode)

    for path, alias in aliases.items():
        for mode in MODES:
            if alias.get(mode):
                check(resolve_color(path, mode) == value_at(tokens, path, mode), f"Stale resolved color: {path} ({mode})")
    for path, alias in value_aliases.items():
        for mode in MODES:
            if alias.get(mode):
                check(scalar_primitives[alias[mode]][mode] == value_at(tokens, path, mode), f"Stale resolved value: {path} ({mode})")


def write_json(path, value, compact=False):
    options = {"sort_keys": True, "ensure_ascii": False, "allow_nan": False}
    if compact:
        options["separators"] = (",", ":")
    else:
        options["indent"] = 2
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as temp:
        try:
            temp.write(json.dumps(value, **options) + "\n")
            temp.flush()
            output = Path(temp.name)
            output.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o644)
            output.replace(path)
        finally:
            Path(temp.name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--apply", action="store_true", help="Replace the bundled library after validation")
    parser.add_argument("--references", type=Path, help="Write engineering reference JSON to this folder")
    args = parser.parse_args()
    destination = args.repo / LIBRARY
    try:
        document = read(args.snapshot)
        validate(document, read(destination))
        if "explicitAssignments" in document:
            document["explicitAssignments"] = sorted(set(document["explicitAssignments"]))
        if args.apply:
            write_json(destination, document, compact=True)
        if args.references:
            write_json(args.references / "semantic-tokens.resolved.json", {"semanticTokens": document["tokens"]})
            write_json(args.references / "component-assignments.json", {"mappings": document["mappings"]})
            encoded = json.dumps(document, sort_keys=True, ensure_ascii=False,
                                 allow_nan=False, separators=(",", ":")) + "\n"
            write_json(args.references / "design-snapshot.json", {
                "sourceRevision": document["sourceRevision"],
                "baselineSHA256": document["baselineSHA256"],
                "savedDesignSHA256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
                "semanticTokenCount": len(document["tokens"]),
                "assignmentCount": len(document["mappings"]),
                "primitiveColorCount": len(document["primitives"]),
                "scalarPrimitiveCount": len(document["scalarPrimitives"]),
                "explicitAssignmentCount": len(document.get("explicitAssignments", [])),
            })
        print(f"Validated {len(document['tokens'])} tokens and {len(document['mappings'])} assignments.")
        if args.apply:
            print(f"Installed {destination}")
            print("Bundled SHA-256:", hashlib.sha256(destination.read_bytes()).hexdigest())
    except (OSError, ValueError, TypeError, KeyError, IndexError) as exc:
        parser.exit(1, f"Design snapshot rejected: {exc}\n")


if __name__ == "__main__":
    main()
