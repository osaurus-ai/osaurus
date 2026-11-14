# Osaurus final design handoff

Prepared for Terrence on November 7, 2026. This supersedes the October 28 design handoff for Beta 40.

## What to integrate

The branch `design/final-beta40-handoff` starts from the `1.0.0-internal.40` tag in `osaurus-ai/osaurus-workflows`. The tag object is `4dc20d68917971f0ac666ab0fa49d0d766f5236e`. The commit it points to, and the actual merge base, is `06ad0fe860f3ddc1526666e950b4344d55dfbf52`.

- **App styling and shared components** — Light palette hierarchy, control borders and status treatments, keyboard focus behavior, shared inputs/selects/segments/steppers/chips, cards and spacing in Chat, Settings and Workflows, and corresponding Inspector cleanup.
- **Final editable design** — 177 semantic tokens, 98 color primitives, 108 scalar primitives and 19,381 component assignments. Both appearances, aliases, effects, typography and 76 explicit assignment choices are bundled in `Packages/OsaurusCore/Models/Theme/DesignLibrary/LibraryResources/design-library.json`.
- **Mac app icon** — The final lime Paper artwork is installed in all ten slots in `App/osaurus/Assets.xcassets/AppIcon.appiconset`. The package's Assets folder also provides an opaque 1024 × 1024 iOS PNG of the same artwork.
- **Engineering tools** — The optional Inspector launcher, design snapshot validator and icon generator live in `scripts/design-handoff/`. These can be used with a different checkout of the same contract.
- **Onboarding** — The packaged first-run views and services match the tagged Beta 40 source. The obsolete Inspector example was removed. The separate local first-run launcher was excluded.

The branch includes the app and Workflows work already present in Beta 40. Treat the October 28 merge and remaining-work reports as historical. The final handoff's Git branch contains the changes since Beta 40.

## Build and review

1. Open `osaurus.xcworkspace` in Xcode and select the `osaurus` scheme and the Mac destination. Resolve the checked-in package versions and use the team's normal signing and build setup.
2. Build with `OSAURUS_DESIGN_INSPECTOR_BUILD` unset. The normal app reads the bundled design when it starts. The Inspector, any local profile, Figma and Paper are unnecessary for that build.
3. Check the lime Mac icon, Light and Dark Settings controls, Chat composer and messages, and the Workflows form on the integrated branch. Run the focused tests in the [verification record](FINAL-BETA40-VERIFICATION.md).
4. Integrate the iOS PNG in the iOS project's default app icon. That project and its platform build are owned separately from this package.

## Reference and ownership

- [Paper — Osaurus 1.0 layouts](https://app.paper.design/file/01M5X5BNNKM9BDYN7NNZFCBCR6/p-1-0)
- [Paper — base components](https://app.paper.design/file/01M5X5BNNKM9BDYN7NNZFCBCR6/p-3-0)
- [Paper — app icon artwork](https://app.paper.design/file/01M5X5BNNKM9BDYN7NNZFCBCR6/p-4-0)
- [Figma — Osaurus 1.0](https://www.figma.com/design/2uNNo7HaZWWV153Y6FFQBN/Osaurus-1.0?node-id=62-1479)
- [Maintenance guide](FINAL-BETA40-MAINTENANCE.md) and [verification record](FINAL-BETA40-VERIFICATION.md)

Use the bundled JSON and the checked-in SwiftUI renderers to reproduce this release. Paper and Figma remain editable design references. The snapshot contains later choices from the Inspector, so a fresh sync from the design files can change the released values. Start any subsequent design work from the shipped snapshot.
