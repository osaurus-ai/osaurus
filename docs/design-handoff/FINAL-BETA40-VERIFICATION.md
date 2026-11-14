# Final Beta 40 verification

## Fresh checks for this package

| Check | Result |
| --- | --- |
| Baseline | Verified the annotated Beta 40 tag and its underlying commit against the Osaurus repository. The commits apply to that exact base. |
| Bundled design | The working Inspector snapshot, packaged editable JSON and the resource in the normal app match. The only serialization change from the saved file is stable key order and sorted explicit assignment keys. |
| Engineering references | All 177 tokens and 19,381 assignment records match the editable document. The package also lists the exact design-data changes relative to Beta 40. |
| Normal Mac build | Passed with Xcode 26.6, Release configuration, incremental compilation, optimization disabled and code signing disabled for the check. The Inspector flag was unset. |
| DesignLibraryTests | All four tests passed. They cover saved assignments and primitives, both appearances, propagation through shared aliases, and the optional editor boundary. |
| Optional Inspector | The portable launcher built a separate offline Inspector, seeded its new profile, signed the bundle, verified its signature and passed its executable launch check. This package check stopped before opening the editor window. |
| Lime icons | The Mac master matches the final Paper export byte for byte. All ten Xcode icon slots have the expected pixel size. The iOS 1024 px export is RGB, preserves the color profile and matches the Mac master's RGB pixels. |
| First-run code | The actual onboarding views and services match the tagged release. The change removes the Inspector example. |

## Previously checked in the local development app

- Light and Dark are independent. Representative changes to shared primitives and input assignments updated real Settings controls and persisted across relaunch.
- The Light color pass cleared the 104 measured contrast combinations. This was a scoped set of configured pairs and representative controls.
- Checked the actual select and segmented control in both appearances, numeric keyboard stepping, the Tools tab keyboard path, and the approved 24 pt and 28 pt chip minimum heights.
- Checked names and help text on the actual Workflows Preview Form. A developer notification stayed visible beyond the regular timeout and its action still worked. The blocking event's routing uses that same timer setting in source.

## Remaining release checks

- The Settings sidebar search follows semantic colors and keeps its own input implementation. It does not take shared Inputs component assignments. See `Packages/OsaurusCore/Views/Management/SidebarNavigation.swift`.
- Spoken VoiceOver output, a real blocking-event notification, submitted workflow runs, custom theme imports, provider/account-dependent states and all conditional catalog variants still need release-level verification where relevant.
- The iOS artwork has been validated as an asset. Integration and display in the iOS app are for the iOS project.
- Use the team's normal release optimization, signing and distribution checks. Run the relevant regression tests on the intended merge target, especially if it has advanced since Beta 40.

## Repeat the focused checks

```sh
env -u OSAURUS_DESIGN_INSPECTOR_BUILD OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
  xcodebuild test -workspace osaurus.xcworkspace -scheme DesignLibraryTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```
