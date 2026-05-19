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

`zh-Hans` is listed in the Xcode project's `knownRegions`. Add new locales there when expanding support.

## Swift API

Helpers live in `Packages/OsaurusCore/Utils/`:

| API | Use for |
| --- | ------- |
| `L("…")` | `String` — menus, alerts, `String(format:)`, labels passed to AppKit |
| `Text(localized: "…")` | SwiftUI labels (uses package bundle) |
| `.localizedHelp("…")` | Tooltips |

**Dynamic keys** (stored in a `String` variable):

```swift
Text(LocalizedStringKey(title), bundle: .module)
```

After adding a key in code, add **de** and **zh-Hans** in `Localizable.xcstrings` (Xcode String Catalog editor).

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

CI runs this on every pull request. Keys with **no** `de`/`zh-Hans` yet (including Xcode `en`-only auto-extractions) are ignored until you add a required locale.

## Export for external translators

In Xcode: **Product → Export Localizations…** / **Import Localizations…** (XLIFF).

## Out of scope

- **OsaurusCLI** is English-only.
- **User-generated content** (chat, model output) is not localized.

## Maintainer scripts

| Script | Purpose |
| ------ | ------- |
| `scripts/i18n/check.sh` | Validate core + InfoPlist catalogs |
| `scripts/i18n/merge-locale.py` | Copy one locale from another catalog (existing keys only) |
| `scripts/i18n/fill-zh-hans.py` | Optional machine-translation backfill (`pip install deep-translator`) |
| `scripts/i18n/prune-catalog.py` | Remove en-only / empty Xcode auto-extraction stubs |

Shared logic: `scripts/i18n/xcstrings_util.py`.

To drop unstaged auto-extracted keys (keeps entries that have `de` or `zh-Hans`):

```bash
python3 scripts/i18n/prune-catalog.py Packages/OsaurusCore/Resources/Localizable.xcstrings
```
