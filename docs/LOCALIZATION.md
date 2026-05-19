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
| `ToastManager.shared.*Localized("…")` | Toasts with static title/message copy |

**Dynamic keys** (stored in a `String` variable):

```swift
Text(LocalizedStringKey(title), bundle: .module)
```

After adding a key in code, add **de** and **zh-Hans** in `Localizable.xcstrings` (Xcode String Catalog editor).

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

CI runs this on every pull request. It validates catalog coverage, checks that Swift localization literals exist in the catalog, runs a Swift literal lint, and dry-runs the catalog pruner. Keys with **no** `de`/`zh-Hans` yet (including Xcode `en`-only auto-extractions) are ignored by the coverage check until you add a required locale, but the pruner check fails if those generated stubs are committed.

## Export for external translators

In Xcode: **Product → Export Localizations…** / **Import Localizations…** (XLIFF).

## Out of scope

- **OsaurusCLI** is English-only.
- **User-generated content** (chat, model output) is not localized.

## First-time setup

Opt in to the repo-tracked git hooks so committing a `.xcstrings` change automatically re-prunes Xcode's auto-extracted stubs before they're staged:

```bash
git config core.hooksPath .githooks
```

The hook is idempotent — it's a no-op when nothing needs pruning. The pruner also skips the write entirely when the catalog content is byte-identical to disk, so Xcode's String Catalog editor doesn't see spurious file changes.

## Maintainer scripts

| Script | Purpose |
| ------ | ------- |
| `scripts/i18n/check.sh` | Validate core + InfoPlist catalogs, lint risky Swift literals, and dry-run pruning. On failure, prints a remediation hint pointing at `format.sh`. |
| `scripts/i18n/format.sh` | One-command write-mode prune of the core catalog. Run this if `check.sh` fails locally, or rely on the pre-commit hook to invoke it automatically. |
| `scripts/i18n/check-swift-catalog-keys.py` | Ensure Swift localization references exist in the core catalog |
| `scripts/i18n/lint-swift-literals.py` | Flag Swift literals that bypass package-bundle localization |
| `scripts/i18n/merge-locale.py` | Copy one locale from another catalog (existing keys only) |
| `scripts/i18n/fill-zh-hans.py` | Optional machine-translation backfill (`pip install deep-translator`) |
| `scripts/i18n/prune-catalog.py` | Remove en-only / empty Xcode auto-extraction stubs and stale keys. Pass `--swift-root` so keys still referenced from Swift source survive even if Xcode flagged them stale. |

Shared logic: `scripts/i18n/xcstrings_util.py`. Shared paths/locales for shell scripts: `scripts/i18n/_paths.sh`.

If you installed the pre-commit hook, committing an Xcode-modified `.xcstrings` re-prunes it automatically. Otherwise run the formatter manually before committing — it drops auto-extracted stubs and stale keys while keeping entries that still have `de`, `zh-Hans`, or a live Swift reference:

```bash
bash scripts/i18n/format.sh
```

On PRs from this repo (not forks), the `i18n autofix` workflow runs the same formatter and pushes a fixup commit if the catalog drifted, so contributors without the hook installed are still covered. Fork PRs see the actionable error from `scripts/i18n/check.sh` in the main CI job and need to run `format.sh` locally.

## Xcode build-setting contract

The `osaurus` app target sets `SWIFT_EMIT_LOC_STRINGS = NO` in **both Debug and Release**. Do **not** flip this back to `YES`. With `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` at the project level, every build (and every indexer pass that runs the Swift compiler) would otherwise emit `.stringsdata` and merge auto-extracted stubs back into `Localizable.xcstrings`. Symptoms:

- The catalog file gets mutated on disk during every build, fighting the pre-commit hook and the `i18n-autofix` workflow.
- Xcode's String Catalog editor re-renders the full 1000+ row × 3-locale grid on every change, retaining the previous view state. Memory grows unboundedly (we saw 228 GB resident on a single Xcode session before the system OOM-killed it).

Source of truth is the explicit `L("…")` / `Text(localized: "…")` markers — `scripts/i18n/check-swift-catalog-keys.py` enforces that every Swift reference exists in the catalog, so auto-extraction would be redundant even if it were safe.
