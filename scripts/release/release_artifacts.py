"""Record immutable qualified build files before contacting external services."""
import argparse
import hashlib
import json
from pathlib import Path


def checkpoint(root, version, source):
    root = Path(root)
    names = ["Osaurus-app.zip", f"Osaurus-{version}.dmg", "Osaurus.dmg", f"Osaurus-{version}-dSYMs.zip"]
    files = []
    for name in names:
        path = root / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Required qualified artifact is missing or empty: {name}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        files.append({"name": name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()})
    receipt = {"version": version, "source": source, "files": files,
               "stage": "after signing, launch verification and light-DMG notarization; before Sentry/publication"}
    (root / "release-artifacts.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def verify(root, version, source):
    root = Path(root)
    receipt = json.loads((root / "release-artifacts.json").read_text())
    if receipt["version"] != version or receipt["source"] != source:
        raise ValueError("Checkpoint does not match the requested release source")
    names = ["Osaurus-app.zip", f"Osaurus-{version}.dmg", "Osaurus.dmg", f"Osaurus-{version}-dSYMs.zip"]
    rows = receipt["files"]
    if len(rows) != len(names) or {row["name"] for row in rows} != set(names):
        raise ValueError("Checkpoint artifact set is incomplete or unexpected")
    for row in rows:
        path = root / row["name"]
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if path.stat().st_size != row["bytes"] or digest.hexdigest() != row["sha256"]:
            raise ValueError(f"Checkpoint artifact changed: {row['name']}")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="build_output")
    parser.add_argument("--version", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--verify", action="store_true")
    arguments = parser.parse_args()
    if arguments.verify:
        verify(arguments.root, arguments.version, arguments.source)
    else:
        checkpoint(arguments.root, arguments.version, arguments.source)
