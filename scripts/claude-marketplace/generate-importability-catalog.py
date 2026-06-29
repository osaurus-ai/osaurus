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


def _title_case_dashes(leaf: str) -> str:
    """Mirror ClaudeSkillEntry/ClaudeAgentEntry.displayName: split on '-',
    uppercase only the first letter of each word, join with spaces."""
    return " ".join(w[:1].upper() + w[1:] for w in leaf.split("-") if w)


def classify_components(base: str, entries: dict[str, str]) -> dict:
    """Replicate buildManifest's component discovery exactly and return the
    importable component summary used by the detail view.

    Osaurus discovers, under the plugin's base path:
      - skills: ANY real directory directly under `skills/` (SKILL.md is not
        required; symlinks/submodules are NOT directories so they don't count),
      - agents: `agents/<file>.md` files,
      - commands: `commands/<file>.md` files,
      - mcp: a `.mcp.json` file at the plugin root.
      - hooks / unsupportedComponents: directory-level signals when visible in
        the tree. `plugin.json`-only declarations are still detected live at
        manifest resolution time, not by this no-content tree pass.

    Display names match the Swift `displayName` derivations: skills + agents
    title-case the dash-separated leaf; commands keep the bare file stem.
    """
    prefix = f"{base}/" if base else ""
    skills_dir = f"{prefix}skills"
    agents_dir = f"{prefix}agents"
    commands_dir = f"{prefix}commands"

    skills: list[str] = []
    agents: list[str] = []
    commands: list[str] = []

    for path, etype in entries.items():
        # Skill: a real directory directly under `<base>/skills/`.
        if (
            etype == "tree"
            and path.startswith(f"{skills_dir}/")
            and path[len(skills_dir) + 1:].count("/") == 0
        ):
            skills.append(_title_case_dashes(path.rsplit("/", 1)[-1]))
        # Agent: `<base>/agents/<file>.md` (direct child file).
        elif (
            etype == "blob"
            and path.startswith(f"{agents_dir}/")
            and path.endswith(".md")
            and path[len(agents_dir) + 1:].count("/") == 0
        ):
            stem = path.rsplit("/", 1)[-1][:-3]  # strip ".md"
            agents.append(_title_case_dashes(stem))
        # Command: `<base>/commands/<file>.md` (direct child file).
        elif (
            etype == "blob"
            and path.startswith(f"{commands_dir}/")
            and path.endswith(".md")
            and path[len(commands_dir) + 1:].count("/") == 0
        ):
            commands.append(path.rsplit("/", 1)[-1][:-3])  # bare stem

    mcp = entries.get(f"{prefix}.mcp.json") is not None
    hooks = any(
        path == f"{prefix}hooks" or path.startswith(f"{prefix}hooks/")
        for path in entries
    )

    unsupported_components: list[str] = []
    for component in ("lspServers", "outputStyles", "themes", "monitors", "bin"):
        if any(
            path == f"{prefix}{component}" or path.startswith(f"{prefix}{component}/")
            for path in entries
        ):
            unsupported_components.append(component)

    # Match the Swift sort order (displayName ascending) for stable output.
    skills.sort()
    agents.sort()
    commands.sort()

    return {
        "skills": skills,
        "agents": agents,
        "commands": commands,
        "mcp": mcp,
        "hooks": hooks,
        "unsupportedComponents": unsupported_components,
    }


def main() -> int:
    print(f"Fetching marketplace.json from {MARKETPLACE_OWNER}/{MARKETPLACE_REPO} ...")
    marketplace = fetch_marketplace()
    plugins = marketplace.get("plugins", [])
    print(f"  {len(plugins)} plugins")

    components: dict[str, dict] = {}
    non_importable: list[str] = []
    unresolved: list[str] = []

    for i, plugin in enumerate(plugins, 1):
        name = plugin.get("name")
        if not name:
            continue

        # Legacy plugins declaring explicit `skills: [..]` are always
        # importable; record the declared skill names as components.
        legacy_skills = plugin.get("skills")
        if legacy_skills:
            skills = sorted(
                _title_case_dashes(str(s).rstrip("/").rsplit("/", 1)[-1])
                for s in legacy_skills
            )
            components[name] = {
                "skills": skills,
                "agents": [],
                "commands": [],
                "mcp": False,
                "hooks": False,
                "unsupportedComponents": [],
            }
            continue

        resolved = resolve_source(plugin)
        if resolved is None:
            unresolved.append(name)
            continue

        owner, repo, base = resolved
        paths = repo_tree(owner, repo)
        if paths is None:
            # Could not fetch tree -> omit (treated as unknown / visible).
            unresolved.append(name)
            continue

        summary = classify_components(base, paths)
        components[name] = summary
        importable = bool(
            summary["skills"] or summary["agents"] or summary["commands"] or summary["mcp"]
        )
        if not importable:
            non_importable.append(name)
            print(f"  [{i}/{len(plugins)}] {name}: NON-IMPORTABLE ({owner}/{repo}/{base})")

    non_importable.sort()
    # Emit plugins sorted by name for a stable, reviewable diff.
    components = dict(sorted(components.items()))

    catalog = {
        "version": 3,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "marketplace": f"{MARKETPLACE_OWNER}/{MARKETPLACE_REPO}",
        "pluginCount": len(plugins),
        "nonImportable": non_importable,
        "plugins": components,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")

    print(f"\nWrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    print(f"  classified: {len(components)}")
    print(f"  non-importable: {len(non_importable)}")
    if unresolved:
        print(f"  unresolved (left visible, no detail): {len(unresolved)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
