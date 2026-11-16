# Help Translate Osaurus

Osaurus is built by the community, and so are its translations. Most of the
app has been translated by volunteers, and we need more of you: every language
we ship still has untranslated screens, a lot of existing translations are
machine-assisted and waiting for a native speaker to check them, and Spanish
and Japanese haven't been started yet.

You don't need to know Swift. If you can read English and write your language
well, you can help, starting with a single string.

## Where each language stands

<!-- COVERAGE:START -->

_Last generated 2026-11-15 by `scripts/i18n/coverage.py`, over the 7,814 UI strings the app's code references._

| Language | Code | Status | Translated | Awaiting native review | Still in English |
| -------- | ---- | ------ | ---------: | ---------------------: | ---------------: |
| German | `de` | Maintained | 73% | 1,992 | 2,132 |
| Simplified Chinese | `zh-Hans` | Maintained | 73% | 355 | 2,132 |
| Korean | `ko` | Maintained | 73% | 1,209 | 2,132 |
| Russian | `ru` | Maintained | 73% | 1,127 | 2,132 |
| Traditional Chinese | `zh-Hant` | Community-maintained | 52% | 236 | 3,739 |
| Spanish | `es` | **Help wanted** | 0% | 0 | 7,814 |
| Japanese | `ja` | **Help wanted** | 0% | 0 | 7,814 |

Where the maintained languages fall back to English (2,132 strings, largest areas first):

| App area (`Packages/OsaurusCore/…`) | Strings |
| ----------------------------------- | ------: |
| `Views/Workflow` | 490 |
| `Services/Workflow` | 244 |
| `Views/Agent` | 171 |
| `Views/Template` | 163 |
| `Services/Template` | 132 |
| `Views/Settings` | 132 |
| `Views/Chat` | 110 |
| `Views/Insights` | 94 |
| `Views/Credentials` | 83 |
| `Models/Workflow` | 58 |
| Everything else | 455 |

macOS permission prompts (`App/osaurus/InfoPlist.xcstrings`) still in English: `de` 3/14, `zh-Hans` 3/14, `ko` 3/14, `ru` 3/14, `zh-Hant` 3/14, `es` 14/14, `ja` 14/14.

<!-- COVERAGE:END -->

"Awaiting native review" counts strings marked **Needs Review**: they are
translated, often with machine or AI help, but nobody fluent has confirmed
them yet. "Still in English" strings show up in English inside the
translated app.

## Ways to help

Pick whichever fits the time you have.

1. **Review existing translations.** This is the most valuable thing a
   native speaker can do. Open the catalog, filter your language to
   **Needs Review**, fix what reads wrong, and mark the rest as reviewed.
   Even 50 strings in one PR helps.
2. **Fill the gaps in a maintained language.** Newer features (Workflows,
   Templates, Agents, Insights, Credentials) shipped after the last big
   translation pass. Choose an area from the table above and translate it.
3. **Start Spanish or Japanese.** Both are already set up in the Xcode
   project with empty columns. The first few hundred strings (menus,
   Settings, Chat) do the most good.
4. **Finish Traditional Chinese.** It is community-maintained and about half
   done.
5. **Propose a new language.** Open an issue saying which language and that
   you (or a group) plan to keep it up. We enable a new locale once someone
   commits to it, so it doesn't ship as a nearly empty column.

## How to contribute

1. Say what you're taking on (see [Claiming work](#claiming-work)) so two
   people don't translate the same area.
2. Create a branch, e.g. `i18n/es-settings` or `i18n/de-review-chat`.
3. Edit the translations in one of the two ways below.
4. Validate locally:

   ```bash
   bash scripts/i18n/check.sh
   ```

5. Open a pull request. Partial work is welcome. CI won't block an
   incomplete language, and small PRs (one language, one area) get reviewed
   fastest.

### Option A: Xcode String Catalog editor (Mac)

Open `Packages/OsaurusCore/Resources/Localizable.xcstrings` (and
`App/osaurus/InfoPlist.xcstrings` for the macOS permission prompts) in Xcode,
pick your language in the sidebar, and translate. Your language's column
already exists.

- Use the filter at the bottom to show only **New** (untranslated) or
  **Needs Review** strings.
- Right-click a row for **Mark for Review** / **Mark as Reviewed**.
- The **Comment** column often says where a string appears in the app.

### Option B: JSON batches (any OS, no Xcode)

Export untranslated strings into batches of JSON, translate them, and apply
them back. The apply step checks placeholders and writes Xcode's exact
format, so your diff contains only your new strings.

```bash
# 1. Export (writes es-batch-01.json, es-batch-02.json, ... plus a manifest)
python3 scripts/i18n/export-untranslated.py \
  Packages/OsaurusCore/Resources/Localizable.xcstrings \
  --locale es --out-dir /tmp/i18n-es --tag es

# 2. Translate one batch into a map file: {"<key>": "<translation>"}
#    For plural entries, map the key to {"one": "...", "other": "..."}.

# 3. Apply just that batch (use --state needs_review for machine/AI-assisted work)
python3 scripts/i18n/apply-ko.py \
  Packages/OsaurusCore/Resources/Localizable.xcstrings \
  --locale es --partial --maps /tmp/i18n-es/es-batch-01.translated.json
```

The export covers strings that German and Simplified Chinese already have,
which is the right starting set for a new language. To find the exact
strings a maintained language is missing, with the Swift file and line
where each appears:

```bash
python3 scripts/i18n/report-untranslated-referenced.py \
  --catalog Packages/OsaurusCore/Resources/Localizable.xcstrings \
  --swift-root Packages/OsaurusCore \
  --locales de --json /tmp/de-missing.json
```

Then translate them in Xcode, or apply a map with
`apply-ko.py --locale de --reference-locales "" --partial --maps …`.

## Translation guidelines

- **Be honest about review state.** If a machine translator or an AI
  produced or substantially shaped a translation, mark it **Needs Review**
  (`--state needs_review` in the JSON flow) and say so in the PR
  description. Only mark a string **Translated** after a fluent speaker has
  read it in context. This is how reviewers find what still needs a human.
- **Keep placeholders intact.** `%@`, `%lld`, `%1$@`, and line breaks must
  survive. You may reorder positional placeholders (`%2$@ … %1$@`) when your
  grammar needs it.
- **Don't copy English into your language.** An untranslated string already
  falls back to English. Copying it in hides it from the backlog. Product
  and brand names (Osaurus, MLX, Hugging Face, model names) stay as they
  are.
- **Match existing terminology.** Search the catalog for how terms like
  *agent*, *workflow*, *model*, *tool*, and *sandbox* are already translated
  in your language, and keep them consistent. If an existing term is wrong,
  fix it everywhere in a separate PR.
- **Don't change English source strings or keys** in a translation PR. If
  the English is unclear or wrong, open an issue.
- Prefer the tone of macOS itself in your language: concise, and formal or
  informal as your language's Apple software is.

## Claiming work

Check the [open localization issues and PRs](https://github.com/osaurus-ai/osaurus/issues?q=is%3Aopen+label%3Ai18n)
to see what's already in progress, then comment there (or open a draft PR)
with your language and area, e.g. "Taking German review for Chat" or
"Starting Japanese: Settings + menus". Several people can share a language.
The leaderboard credits everyone whose translations land.

## Leaderboard

This table is generated from merged pull requests that touched the string
catalogs. Attribution is content-based: a string counts only when it is genuinely
translated (the value differs from English and isn't just punctuation or a format
specifier), so reformatting and auto-added stubs don't earn credit. Each
language shows the contributor's **coverage** -- the share of the app's
translatable strings they've translated -- and a language is listed once coverage
reaches **10%**.

Maintainers regenerate both generated sections with:

```bash
python3 scripts/i18n/coverage.py               # language status table
python3 scripts/i18n/leaderboard.py            # leaderboard (needs gh), default 10% threshold
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
