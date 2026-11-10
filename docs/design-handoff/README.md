# Osaurus UX and design library handoff

For the current package, start with the [final Beta 40 handoff](FINAL-BETA40.md). The notes below describe the October 28 handoff.

Prepared for Terrence on 28 October 2026. This is a review and integration branch, not a production release.

## What is delivered

- The current main-chat and Workflows UX, including workflow-specific authoring chats, homepage/starter routes, existing run/setup/share/history routes, and shared menu behavior.
- The shared component implementations and their semantic-token assignments, including the current attachment, input, button, selection, messaging and activity styles.
- Neesh's saved design frozen in `Packages/OsaurusCore/Models/Theme/DesignLibrary/LibraryResources/design-library.json`. This includes both appearances, primitive values, aliases, typography, effects and component assignments.
- The design inspector source as optional development tooling. The normal app uses the saved design without opening the inspector or loading Neesh's settings folder.

The nine-minute walkthrough is supplied separately. Paper remains the design reference; this snapshot captures the saved implementation at packaging time.

## Start here

The source ZIP is a self-contained checkout. Open `osaurus.xcworkspace` and select the `osaurus` scheme. Use your existing Xcode signing/team setup. Build normally with `OSAURUS_DESIGN_INSPECTOR_BUILD` unset. Run on macOS with the supported Xcode toolchain and normal app dependencies.

The Git bundle is preferable for integration into the existing repository:

```sh
git bundle verify /path/to/osaurus-ux-design-oct28.bundle
git fetch /path/to/osaurus-ux-design-oct28.bundle design/ux-library-handoff-oct28:design/ux-library-handoff-oct28
git switch design/ux-library-handoff-oct28
```

The bundle requires the existing beta baseline commit `834c7a437ef31626115545794bf3583296542640`, which is in the upstream history. It includes the commits since that baseline. The source ZIP is available if you only need to open/build the delivered version.

## Integrating into the newer app

Read [UPSTREAM.md](UPSTREAM.md) first. Upstream advanced while this work was in progress; this is not a conflict-free drop-in merge. Keep the working handoff branch intact and resolve overlaps in a separate branch.

The last packaging commit separates shared rendering from editor-only tools:

- `OSAURUS_DESIGN_SYSTEM` enables the shared styling in normal and inspector builds.
- `OSAURUS_DESIGN_INSPECTOR` still controls the editor, its persistence, preview fixtures and isolated development-account behavior.
- Runtime style code lives under `Models/Theme/DesignLibrary`. Existing source names containing `Inspector` are retained to avoid a needless rename sweep; these files provide actual shared renderers.
- `DesignLibraryRuntime` loads the bundled saved design. The normal build does not read or modify Neesh's live inspector settings.

The shared token values and assignments are part of the app and should merge with it. The playground window itself is optional. Keep its source available for future component work; it is not a requirement for normal app startup and is not opened by a normal build. An editor build still requires its isolated identity/profile launcher setup; no preconfigured personal profile or signed playground app is distributed here.

## Updating the design later

Use an approved export of the complete editable inspector document to replace `LibraryResources/design-library.json`; retain primitives, aliases and assignments together. `semantic-tokens.resolved.json` in this folder is the corresponding resolved engineering reference, not the editable source. `component-assignments.json` contains the full mapping export. Do not copy an entire local app profile.

Existing upstream theme-import/custom-theme behavior and all account-dependent flows need regression review before release; the bundled design overlay now applies to the delivered UI in normal builds. Do not assume this package certifies those combinations.

## Verification and remaining work

See [STATUS.md](STATUS.md) for the actual checks completed for this package, and [REMAINING.md](REMAINING.md) for outstanding design and testing boundaries. No credentials, sign-in tokens, conversations, downloaded models or user workflow data are included. No external workflow was run or published for packaging.
