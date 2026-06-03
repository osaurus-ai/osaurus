#!/usr/bin/env python3
"""Generate the bundled Claude marketplace importability catalog.

Osaurus only imports four Claude-plugin component types: skills, agents,
commands, and MCP servers. Plugins that ship only hooks / output-styles /
monitors / lspServers / themes / bin have nothing Osaurus can install. The
official marketplace lists 200+ plugins and classifying them at runtime would
require ~160 GitHub requests per session (rate-limit blowup), so we precompute
the classification once here and commit the result as a bundle resource.

The classification mirrors `buildManifest` in GitHubSkillService.swift: a
plugin is importable if, under its base path, it has a skill (`*/SKILL.md` or
a top-level `SKILL.md`), an `agents/*.md`, a `commands/*.md`, or a `.mcp.json`.

Usage:
    gh auth login              # 5000 req/hr authenticated; required
    python3 scripts/claude-marketplace/generate-importability-catalog.py

Writes:
    Packages/OsaurusCore/Resources/ClaudePlugins/claude-marketplace-importability.json
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

MARKETPLACE_OWNER = "anthropics"
MARKETPLACE_REPO = "claude-plugins-official"
MARKETPLACE_URL = (
    f"https://raw.githubusercontent.com/{MARKETPLACE_OWNER}/{MARKETPLACE_REPO}"
    "/main/.claude-plugin/marketplace.json"
)

REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_PATH = (
    REPO_ROOT
    / "Packages/OsaurusCore/Resources/ClaudePlugins/claude-marketplace-importability.json"
)


def gh_api(path: str) -> dict | list:
    """Call the authenticated GitHub REST API via `gh`."""
    result = subprocess.run(
        ["gh", "api", path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def fetch_marketplace() -> dict:
    result = subprocess.run(
        ["curl", "-sL", MARKETPLACE_URL], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"failed to fetch marketplace.json: {result.stderr}")
    return json.loads(result.stdout)


def parse_repo_slug(url_or_slug: str) -> tuple[str, str] | None:
    """Extract (owner, repo) from a GitHub URL or a bare owner/repo slug."""
    s = url_or_slug.strip()
    if s.startswith("http"):
        # https://github.com/owner/repo(.git)(/...)
        parts = s.split("github.com/", 1)
        if len(parts) != 2:
            return None
        s = parts[1]
    s = s.rstrip("/")
    if s.endswith(".git"):
        s = s[:-4]
    comps = [c for c in s.split("/") if c]
    if len(comps) < 2:
        return None
    return comps[0], comps[1]


def normalize_path(p: str) -> str:
    p = (p or "").strip().strip("/")
    if p.startswith("./"):
        p = p[2:]
    return p.strip("/")


def resolve_source(plugin: dict) -> tuple[str, str, str] | None:
    """Return (owner, repo, base_path) for a plugin, mirroring resolveSource.

    Returns None when we cannot determine a source (treated as unknown ->
    importable / visible)."""
    source = plugin.get("source")
    name = plugin.get("name", "")

    # String source == local directory inside the marketplace repo.
    if source is None or isinstance(source, str):
        base = normalize_path(source) if isinstance(source, str) else name
        return MARKETPLACE_OWNER, MARKETPLACE_REPO, base

    kind = source.get("source", "url")
    url_or_slug = source.get("url") or source.get("repo")
    path = normalize_path(source.get("path", ""))

    if kind in ("url", "github", ""):
        if not url_or_slug:
            return None
        slug = parse_repo_slug(url_or_slug)
        if slug is None:
            return None
        return slug[0], slug[1], path  # path usually empty for url/github
    if kind == "git-subdir":
        if not url_or_slug:
            return None
        slug = parse_repo_slug(url_or_slug)
        if slug is None:
            return None
        return slug[0], slug[1], path
    # Unknown shape.
    return None


# Cache of repo -> {path: git-tree-type} (or None when the tree couldn't be
# fetched). git-tree types: "tree" (dir), "blob" (file or symlink), "commit"
# (submodule). The GitHub contents API that Osaurus uses reports symlinks as
# "symlink" and submodules as "submodule" — neither is "dir" — so only "tree"
# entries count as directories here, matching Osaurus's behavior.
_tree_cache: dict[tuple[str, str], dict[str, str] | None] = {}


def repo_tree(owner: str, repo: str) -> dict[str, str] | None:
    key = (owner, repo)
    if key in _tree_cache:
        return _tree_cache[key]

    # Determine default branch, then fetch its recursive tree in one request.
    try:
        info = gh_api(f"repos/{owner}/{repo}")
        branch = info.get("default_branch", "main")
    except RuntimeError as exc:
        print(f"  ! repo {owner}/{repo}: {exc}", file=sys.stderr)
        _tree_cache[key] = None
        return None

    try:
        tree = gh_api(f"repos/{owner}/{repo}/git/trees/{branch}?recursive=1")
    except RuntimeError as exc:
        print(f"  ! tree {owner}/{repo}@{branch}: {exc}", file=sys.stderr)
        _tree_cache[key] = None
        return None

    entries = {entry["path"]: entry["type"] for entry in tree.get("tree", [])}
    if tree.get("truncated"):
        print(f"  ! tree {owner}/{repo} truncated; classification may be partial", file=sys.stderr)
    _tree_cache[key] = entries
    return entries


def is_importable(base: str, entries: dict[str, str]) -> bool:
    """Replicate buildManifest's component discovery exactly.

    Osaurus marks a plugin importable when, under its base path, it has:
      - a `skills/<dir>` subdirectory (ANY real directory — SKILL.md is not
        required; symlinks/submodules are NOT directories so they don't count),
      - an `agents/<file>.md` file,
      - a `commands/<file>.md` file, or
      - a `.mcp.json` file at the plugin root.
    """
    prefix = f"{base}/" if base else ""

    # MCP server config at the plugin root.
    if entries.get(f"{prefix}.mcp.json") is not None:
        return True

    skills_dir = f"{prefix}skills"
    agents_dir = f"{prefix}agents"
    commands_dir = f"{prefix}commands"

    for path, etype in entries.items():
        # Skill: a real directory directly under `<base>/skills/`.
        if (
            etype == "tree"
            and path.startswith(f"{skills_dir}/")
            and path[len(skills_dir) + 1:].count("/") == 0
        ):
            return True
        # Agent: `<base>/agents/<file>.md` (direct child file).
        if (
            etype == "blob"
            and path.startswith(f"{agents_dir}/")
            and path.endswith(".md")
            and path[len(agents_dir) + 1:].count("/") == 0
        ):
            return True
        # Command: `<base>/commands/<file>.md` (direct child file).
        if (
            etype == "blob"
            and path.startswith(f"{commands_dir}/")
            and path.endswith(".md")
            and path[len(commands_dir) + 1:].count("/") == 0
        ):
            return True
    return False


def main() -> int:
    print(f"Fetching marketplace.json from {MARKETPLACE_OWNER}/{MARKETPLACE_REPO} ...")
    marketplace = fetch_marketplace()
    plugins = marketplace.get("plugins", [])
    print(f"  {len(plugins)} plugins")

    non_importable: list[str] = []
    unresolved: list[str] = []

    for i, plugin in enumerate(plugins, 1):
        name = plugin.get("name")
        if not name:
            continue

        # Legacy plugins declaring explicit `skills: [..]` are always importable.
        if plugin.get("skills"):
            continue

        resolved = resolve_source(plugin)
        if resolved is None:
            unresolved.append(name)
            continue

        owner, repo, base = resolved
        paths = repo_tree(owner, repo)
        if paths is None:
            # Could not fetch tree -> leave visible (unknown).
            unresolved.append(name)
            continue

        if not is_importable(base, paths):
            non_importable.append(name)
            print(f"  [{i}/{len(plugins)}] {name}: NON-IMPORTABLE ({owner}/{repo}/{base})")

    non_importable.sort()

    catalog = {
        "version": 1,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "marketplace": f"{MARKETPLACE_OWNER}/{MARKETPLACE_REPO}",
        "pluginCount": len(plugins),
        "nonImportable": non_importable,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")

    print(f"\nWrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    print(f"  non-importable: {len(non_importable)}")
    if unresolved:
        print(f"  unresolved (left visible): {len(unresolved)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
