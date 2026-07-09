# Localization

Osaurus uses **String Catalogs** (`.xcstrings`) for translations. There are no legacy `.strings` files or `.lproj` folders.

## Where strings live

| Catalog | Path | Contents |
| ------- | ---- | -------- |
| **UI (all app screens)** | `Packages/OsaurusCore/Resources/Localizable.xcstrings` | Menus, settings, chat, agents, plugins, etc. |
| **Info.plist** | `App/osaurus/InfoPlist.xcstrings` | Privacy usage descriptions, bundle display name |

All SwiftUI and `String` UI text in **OsaurusCore** must resolve against the **package bundle**, not the main app bundle.

## Supported locales

| Locale | Code | Status |
| ------ | ---- | ------ |
| English | `en` | Source language |
| German | `de` | Required |
| Simplified Chinese | `zh-Hans` | Required |
| Korean | `ko` | Required |
| Russian | `ru` | Required |
| Spanish | `es` | Help wanted |
| Japanese | `ja` | Help wanted |
| Traditional Chinese | `zh-Hant` | Help wanted |

All of the above are listed in the Xcode project's `knownRegions`, so the
"help wanted" locales already have empty columns ready in the String Catalog
editor. We're actively seeking contributors for them -- see
**[TRANSLATORS.md](TRANSLATORS.md)** for the call to action and the contributor
leaderboard. Add any further locales to `knownRegions` when expanding support.

## Swift API

Helpers live in `Packages/OsaurusCore/Utils/`:

| API | Use for |
| --- | ------- |
| `L("…")` | `String` — menus, alerts, `String(format:)`, labels passed to AppKit |
| `Text(localized: "…")` | SwiftUI labels (uses package bundle) |
| `.localizedHelp("…")` | Tooltips |
| `ToastManager.shared.*Localized("…")` | Toasts with static title/message copy |

**Dynamic keys** (stored in a `String` variable):

```swift
Text(LocalizedStringKey(title), bundle: .module)
```

After adding a key in code, add **de**, **zh-Hans**, **ko**, and **ru** in `Localizable.xcstrings` (Xcode String Catalog editor).

Avoid raw `Text("…")`, `.help("…")`, `Button("…")`, `panel.title = "…"`, and `UNMutableNotificationContent.title = "…"` in `Packages/OsaurusCore`. CI flags these because they usually resolve against the wrong bundle.

## Adding a new language

1. Add the locale to `knownRegions` in `App/osaurus.xcodeproj/project.pbxproj`.
2. Add translations in `Packages/OsaurusCore/Resources/Localizable.xcstrings`.
3. Translate Info.plist strings in `App/osaurus/InfoPlist.xcstrings` when needed.
4. Run `bash scripts/i18n/check.sh`.
5. Smoke-test with the system language set to the new locale.

Import from another catalog:

```bash
python3 scripts/i18n/merge-locale.py \
  --target Packages/OsaurusCore/Resources/Localizable.xcstrings \
  --source path/to/other/Localizable.xcstrings \
  --locale <locale-code>
```

## Validation

```bash
bash scripts/i18n/check.sh
```

CI runs this on every pull request. It validates catalog coverage, checks that Swift localization literals exist in the catalog, and runs a Swift literal lint. Keys with **no** `de`/`zh-Hans` yet (including Xcode `en`-only auto-extractions and empty stubs the catalog editor injects for raw `Text("…")` literals) are ignored — the catalog is allowed to grow without breaking CI. Run the pruner manually when you want to clean it up (see `scripts/i18n/prune-catalog.py` below).

## Export for external translators

In Xcode: **Product → Export Localizations…** / **Import Localizations…** (XLIFF).

## Out of scope

- **OsaurusCLI** is English-only.
- **User-generated content** (chat, model output) is not localized.

## Maintainer scripts

| Script | Purpose |
| ------ | ------- |
| `scripts/i18n/check.sh` | Validate core + InfoPlist catalogs, lint risky Swift literals, and dry-run pruning |
| `scripts/i18n/check-swift-catalog-keys.py` | Ensure Swift localization references exist in the core catalog |
| `scripts/i18n/lint-swift-literals.py` | Flag Swift literals that bypass package-bundle localization |
| `scripts/i18n/merge-locale.py` | Copy one locale from another catalog (existing keys only) |
| `scripts/i18n/fill-zh-hans.py` | Optional machine-translation backfill (`pip install deep-translator`) |
| `scripts/i18n/export-untranslated.py` | Export keys missing a locale into batched JSON for (LLM/human) translators |
| `scripts/i18n/apply-ko.py` | Apply translated JSON maps back into a catalog with placeholder/coverage validation and Xcode-exact formatting (`--locale` is configurable) |
| `scripts/i18n/prune-catalog.py` | Remove en-only / empty Xcode auto-extraction stubs and stale keys |
| `scripts/i18n/leaderboard.py` | Generate the translator leaderboard in `TRANSLATORS.md` from merged PRs (needs `gh`) |

Shared logic: `scripts/i18n/xcstrings_util.py`.

Xcode's indexer will occasionally inject empty stubs into the catalog for raw `Text("…")` literals (emoji, single-char UI elements, interpolations the indexer canonicalizes). This is harmless — empty stubs resolve to English fallback at runtime exactly as if they weren't in the catalog — and CI no longer fails on them. Run the pruner manually when you want to drop them:

```bash
python3 scripts/i18n/prune-catalog.py \
  Packages/OsaurusCore/Resources/Localizable.xcstrings \
  --remove-stale
```
