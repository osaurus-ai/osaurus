# Help Translate Osaurus

Osaurus is built by the community, and so are its translations. If you speak a
language we don't ship yet, you can make Osaurus feel native to thousands of
people on your machine and theirs.

We are actively looking for help with these languages:

| Language | Code | Status |
| -------- | ---- | ------ |
| Spanish | `es` | **Help wanted** |
| Japanese | `ja` | **Help wanted** |
| German | `de` | Maintained |
| Simplified Chinese | `zh-Hans` | Maintained |
| Korean | `ko` | Maintained |
| Russian | `ru` | Maintained |
| Traditional Chinese | `zh-Hant` | Maintained (community) |
| English | `en` | Source language |

Both "help wanted" locales are already enabled in the Xcode project, so you can
open the String Catalog editor and start translating immediately -- no setup
required. Traditional Chinese is nearly complete thanks to community
contributions; help closing the last gap is welcome too.

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

_Last generated 2026-07-10 17:58 UTC by `scripts/i18n/leaderboard.py`. Coverage is the share of the app's translatable strings a contributor has translated; a language is listed at ≥10% coverage._

| Contributor | Languages (coverage) | PRs |
| ----------- | -------------------- | --- |
| [@ftzahao](https://github.com/ftzahao) (师梦豪) | Simplified Chinese (`zh-Hans`) 94%, Traditional Chinese (`zh-Hant`) 92%, German (`de`) 67% | [#1354](https://github.com/osaurus-ai/osaurus/pull/1354) [#1373](https://github.com/osaurus-ai/osaurus/pull/1373) [#1380](https://github.com/osaurus-ai/osaurus/pull/1380) [#1414](https://github.com/osaurus-ai/osaurus/pull/1414) [#1437](https://github.com/osaurus-ai/osaurus/pull/1437) [#1466](https://github.com/osaurus-ai/osaurus/pull/1466) [#1470](https://github.com/osaurus-ai/osaurus/pull/1470) [#1491](https://github.com/osaurus-ai/osaurus/pull/1491) [#1520](https://github.com/osaurus-ai/osaurus/pull/1520) [#1553](https://github.com/osaurus-ai/osaurus/pull/1553) [#1579](https://github.com/osaurus-ai/osaurus/pull/1579) [#1596](https://github.com/osaurus-ai/osaurus/pull/1596) [#1607](https://github.com/osaurus-ai/osaurus/pull/1607) [#1633](https://github.com/osaurus-ai/osaurus/pull/1633) [#1659](https://github.com/osaurus-ai/osaurus/pull/1659) [#1720](https://github.com/osaurus-ai/osaurus/pull/1720) [#1762](https://github.com/osaurus-ai/osaurus/pull/1762) [#1820](https://github.com/osaurus-ai/osaurus/pull/1820) [#1858](https://github.com/osaurus-ai/osaurus/pull/1858) [#1909](https://github.com/osaurus-ai/osaurus/pull/1909) [#1947](https://github.com/osaurus-ai/osaurus/pull/1947) |
| [@DrMaks22](https://github.com/DrMaks22) | Russian (`ru`) 86% | [#1782](https://github.com/osaurus-ai/osaurus/pull/1782) [#1822](https://github.com/osaurus-ai/osaurus/pull/1822) |
| [@mimeding](https://github.com/mimeding) (Michael Meding) | Simplified Chinese (`zh-Hans`) 83%, Korean (`ko`) 81%, German (`de`) 67% | [#1304](https://github.com/osaurus-ai/osaurus/pull/1304) [#1372](https://github.com/osaurus-ai/osaurus/pull/1372) [#1477](https://github.com/osaurus-ai/osaurus/pull/1477) [#1518](https://github.com/osaurus-ai/osaurus/pull/1518) [#1529](https://github.com/osaurus-ai/osaurus/pull/1529) [#1531](https://github.com/osaurus-ai/osaurus/pull/1531) [#1559](https://github.com/osaurus-ai/osaurus/pull/1559) [#1565](https://github.com/osaurus-ai/osaurus/pull/1565) [#1570](https://github.com/osaurus-ai/osaurus/pull/1570) [#1572](https://github.com/osaurus-ai/osaurus/pull/1572) [#1586](https://github.com/osaurus-ai/osaurus/pull/1586) [#1588](https://github.com/osaurus-ai/osaurus/pull/1588) [#1616](https://github.com/osaurus-ai/osaurus/pull/1616) [#1739](https://github.com/osaurus-ai/osaurus/pull/1739) [#1743](https://github.com/osaurus-ai/osaurus/pull/1743) [#1931](https://github.com/osaurus-ai/osaurus/pull/1931) |
| [@jiajun-dev](https://github.com/jiajun-dev) (zhuangjiajun) | Simplified Chinese (`zh-Hans`) 20% | [#857](https://github.com/osaurus-ai/osaurus/pull/857) [#1612](https://github.com/osaurus-ai/osaurus/pull/1612) |
| [@HolliOnRoad](https://github.com/HolliOnRoad) | German (`de`) 17% | [#785](https://github.com/osaurus-ai/osaurus/pull/785) [#837](https://github.com/osaurus-ai/osaurus/pull/837) |

<!-- LEADERBOARD:END -->
