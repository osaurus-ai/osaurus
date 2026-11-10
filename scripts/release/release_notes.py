"""Read notes for the target tag without modifying any release or draft."""
import json
import os
from pathlib import Path
import subprocess
import uuid

from release_lane import CLASSIC_NOTICE, ReleaseLane


def api(*arguments):
    result = subprocess.run(["gh", "api", *arguments], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def repository_tags():
    result = subprocess.run(["git", "tag", "--list"], check=True, capture_output=True, text=True)
    return result.stdout.split()


def release_notes(repository, tag, source, tags=repository_tags):
    lane = ReleaseLane.for_version(tag)
    pages = api(f"/repos/{repository}/releases?per_page=100", "--paginate", "--slurp")
    matches = [release for page in pages for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError(f"More than one release matches {tag}")
    if matches and (matches[0].get("body") or "").strip():
        body = matches[0]["body"]
    else:
        # GitHub computes notes for this tag/commit; this endpoint creates no release.
        # Without previous_tag_name it diffs against the newest release by date,
        # which after a Classic patch is the other lane.
        request = ["--method", "POST", f"/repos/{repository}/releases/generate-notes",
                   "-f", f"tag_name={tag}", "-f", f"target_commitish={source}"]
        previous = lane.previous_tag(tags())
        if previous:
            request += ["-f", f"previous_tag_name={previous}"]
        body = api(*request).get("body")
        if not isinstance(body, str) or not body.strip():
            raise ValueError("GitHub returned empty release notes")
    if lane.is_classic and not body.lstrip().startswith(CLASSIC_NOTICE):
        body = f"{CLASSIC_NOTICE}\n\n{body}"
    return body


def write_output(path, body):
    delimiter = f"OSAURUS_CHANGELOG_{uuid.uuid4().hex}"
    while delimiter in body.splitlines():
        delimiter = f"OSAURUS_CHANGELOG_{uuid.uuid4().hex}"
    with Path(path).open("a", encoding="utf-8") as output:
        output.write(f"changelog<<{delimiter}\n{body}\n{delimiter}\n")


def main():
    for key in ("GH_TOKEN", "GITHUB_REPOSITORY", "VERSION", "GITHUB_SHA", "GITHUB_OUTPUT"):
        if not os.environ.get(key):
            raise ValueError(f"{key} is required")
    body = release_notes(os.environ["GITHUB_REPOSITORY"], os.environ["VERSION"], os.environ["GITHUB_SHA"])
    write_output(os.environ["GITHUB_OUTPUT"], body)


if __name__ == "__main__":
    main()
