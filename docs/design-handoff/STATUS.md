# Handoff verification status

The [final Beta 40 verification record](FINAL-BETA40-VERIFICATION.md) has the current results. This page records the October 28 handoff.

Updated 28 October 2026. Overall: ready for engineering review; not release-certified.

| Check | Result |
| --- | --- |
| Preserve original working source | Passed: all 4,506 source files match the pre-packaging snapshot; packaging edits are in a separate repository. |
| Preserve saved design | Passed: the bundled editable document is byte-identical to the saved inspector document (SHA-256 in design-snapshot.json). |
| Engineering export | Passed: all 170 resolved semantic values match the saved document; all 19,373 assignments are exported. |
| Normal app build, inspector disabled | Passed with Xcode 26.6 / macOS 26.5 SDK, arm64, Release configuration, incremental compilation and optimization disabled for this bounded check. Code signing disabled. |
| Normal app includes design, excludes editor | Passed: compiled app contains DesignLibraryRuntime/DesignThemeOverlay and the exact saved library resource; no DesignWorkingStore or DesignInspectorWindow symbols. |
| Focused automated tests | Passed: 4 tests covering saved assignment/primitive preservation, Light/Dark themes, shared-alias propagation with independent modes, and editor exclusion. |
| Optional editor build | Passed with the inspector enabled; editor and shared runtime compile together. No editor relaunch or persistence re-test performed during packaging. |
| Latest upstream merge | Preview performed; 23 conflicting files. Not merged. See UPSTREAM.md. |
| Fresh-install app launch / full end-to-end workflows | Not performed for packaging. |
| Production optimization, signing, notarization, distribution | Not performed. |
| Broad visual or manual catalog review | Not repeated. |

The test runner reported macOS Accounts/CoreData connection messages; all four selected Swift Testing tests completed successfully with zero test failures. No model requests or account sign-in were part of these tests.

## Re-run the focused library checks

```sh
env -u OSAURUS_DESIGN_INSPECTOR_BUILD OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
  xcodebuild test -workspace osaurus.xcworkspace -scheme DesignLibraryTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

These checks validate the bundled design/runtime separation; they do not replace regression testing after resolving upstream conflicts. In particular, review custom-theme switching/imports and account-dependent behavior before release.
