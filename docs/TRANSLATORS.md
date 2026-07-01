# Help Translate Osaurus

Osaurus is built by the community, and so are its translations. If you speak a
language we don't ship yet, you can make Osaurus feel native to thousands of
people on your machine and theirs.

We are actively looking for help with these languages:

| Language | Code | Status |
| -------- | ---- | ------ |
| Spanish | `es` | **Help wanted** |
| Japanese | `ja` | **Help wanted** |
| Traditional Chinese | `zh-Hant` | **Help wanted** |
| German | `de` | Maintained |
| Simplified Chinese | `zh-Hans` | Maintained |
| Korean | `ko` | Maintained |
| Russian | `ru` | Maintained |
| English | `en` | Source language |

All three "help wanted" locales are already enabled in the Xcode project, so you
can open the String Catalog editor and start translating immediately -- no setup
required.

## How to contribute a translation

1. Read **[LOCALIZATION.md](LOCALIZATION.md)** for where strings live and the
   tooling overview.
2. Create a branch (e.g. `i18n/es` or `l10n/ko`).
3. Add your translations in
   `Packages/OsaurusCore/Resources/Localizable.xcstrings` (and
   `App/osaurus/InfoPlist.xcstrings` for system permission strings) using the
   Xcode String Catalog editor. Your locale column already exists.
4. Validate locally:

   ```bash
   bash scripts/i18n/check.sh
   ```

5. Open a pull request. Partial translations are welcome -- you don't have to
   finish a whole language in one PR, and CI will not block incomplete locales.

## How to claim a language

To avoid duplicate effort, comment on the localization tracking issue (or open a
draft PR) saying which language you're taking. Multiple contributors can share a
language -- the leaderboard below credits everyone who lands translation work.

## Leaderboard

This table is generated from merged pull requests that touched the string
catalogs. Attribution is content-based: a string counts only when it is genuinely
translated (the value differs from English and isn't just punctuation or a format
specifier), so reformatting and auto-added stubs don't earn credit. Each
language shows the contributor's **coverage** -- the share of the app's
translatable strings they've translated -- and a language is listed once coverage
reaches **10%**.

Regenerate it with:

```bash
python3 scripts/i18n/leaderboard.py            # default 10% threshold
python3 scripts/i18n/leaderboard.py --min-coverage 15
```

<!-- LEADERBOARD:START -->

_Last generated 2026-06-08 13:18 UTC by `scripts/i18n/leaderboard.py`. Coverage is the share of the app's translatable strings a contributor has translated; a language is listed at ≥10% coverage._

| Contributor | Languages (coverage) | PRs |
| ----------- | -------------------- | --- |
| [@jiajun-dev](https://github.com/jiajun-dev) (zhuangjiajun) | Simplified Chinese (`zh-Hans`) 30% | [#857](https://github.com/osaurus-ai/osaurus/pull/857) |
| [@HolliOnRoad](https://github.com/HolliOnRoad) | German (`de`) 27% | [#785](https://github.com/osaurus-ai/osaurus/pull/785) [#837](https://github.com/osaurus-ai/osaurus/pull/837) |
| [@ftzahao](https://github.com/ftzahao) (师梦豪) | Simplified Chinese (`zh-Hans`) 26%, German (`de`) 11% | [#1354](https://github.com/osaurus-ai/osaurus/pull/1354) [#1373](https://github.com/osaurus-ai/osaurus/pull/1373) [#1380](https://github.com/osaurus-ai/osaurus/pull/1380) [#1414](https://github.com/osaurus-ai/osaurus/pull/1414) |

<!-- LEADERBOARD:END -->
