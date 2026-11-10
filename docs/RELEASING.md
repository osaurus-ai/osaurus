# Releasing Osaurus

This repository ships two products. The version number in the tag decides
which one a release is, and `scripts/release/release_lane.py` applies that
decision to every release step.

| | Osaurus 1.x | Osaurus Classic 0.25.x |
| --- | --- | --- |
| Branch | `main` | `classic` |
| Tags | `1.Y.Z`, `1.Y.Z-beta.N` | `0.25.N` |
| Sparkle feed | `docs/appcast-next.xml` | `docs/appcast.xml` |
| GitHub Latest, website download, Homebrew cask | Stable releases | Never |
| Model-bundled ("full") DMG | Yes | No |
| Release notes | Release Drafter's draft from `main` | Written by hand |

Classic gets fixes only. New features go to `main`.

## Releasing 1.x

1. Merge to `main`.
2. Wait until CI on that `main` commit is green: `test-core`, `test-cli`,
   `swiftlint` and `shellcheck`. The release workflow refuses a commit
   without them.
3. Review the release draft. The pipeline publishes the draft's body as the
   notes.
4. Push the tag at that commit, for example `git tag 1.0.1 <sha> && git push
   origin 1.0.1`.

A stable 1.x release also updates the Classic upgrade offer (below). A beta
does not.

## Releasing a Classic patch

1. Branch from `classic`, fix, and merge the PR into `classic`. A hotfix
   branch cut from `classic` can be tagged directly.
2. Wait for green CI on the commit you will tag.
3. Create a draft release for the tag with hand-written notes. The pipeline
   publishes the draft and starts the notes with a fixed line saying this is a
   Classic maintenance release. Without a draft it generates notes from the
   previous 0.25 tag.
4. Push the `0.25.N` tag.

## Never

- Never tag a 0.x version on 1.x code or a 1.x version on Classic code. A 0.x
  tag on `main` would ship 1.0 to every Classic user as a normal update. The
  release workflow refuses both (`release_lane.py check-source`).
- Never edit `docs/appcast.xml` or `docs/appcast-next.xml` by hand. The
  pipeline writes them and refuses a feed holding the other product's items.
- Never mark a Classic release as Latest. `releases/latest/download/Osaurus.dmg`,
  the website and Homebrew must keep serving 1.x.

## Classic upgrade offer

Each stable 1.x release also writes its feed item into `appcast.xml` on the
`beta` channel, replacing the previous offer. Classic asks Sparkle for the
`beta` channel only when **Beta Updates** is on in Settings → General, so only
those users are offered 1.x, and Sparkle asks before installing it
(`minimumAutoupdateVersion` 1.0.0). Everyone else stays on Classic.

`appcast.xml` may hold exactly one 1.x item, and only on the beta channel.
Classic patches publish around it.

## End of Classic support

Moving every Classic user to 1.x means publishing a 1.x item to `appcast.xml`
on the release channel. The lane rules forbid that today, so it needs a
deliberate change to `release_lane.py` when the date comes. After that
release, `classic` is frozen.
