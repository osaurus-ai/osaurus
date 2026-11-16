# Maintaining the Osaurus design system

## Open the optional Inspector

From the source checkout on a Mac with Xcode and Python 3.9 or later:

```sh
python3 scripts/design-handoff/run-inspector.py --build
```

The launcher builds a separate development app and starts it offline. Its data lives under `~/Library/Application Support/Osaurus Design Inspector/Profile` by default. The first run seeds its editable design from the bundled library. Subsequent launches keep that profile's edits. Use `--work-dir` for a fresh profile, `--port` for a separate local port, and `--signing-identity` if your team needs a specific Apple Development signature. Omit `--build` when reopening an existing prepared build.

The Inspector is for authoring and preview. Its local edits affect that running development app and autosave in that profile. Normal builds use only the bundled design. The launcher disables provider sign-in and uses a dedicated profile and a loopback-only network policy.

## Publish a style change

1. In the Inspector, make a snapshot before editing. Use **Primitives** for underlying values, **Tokens** for semantic aliases and recipes, and each component page for property assignments. Keep color mode choices independent. Adjust shared base controls on their own pages.
2. Open **Review export** and export the complete file ending in `-editable.json`. The smaller review export and the resolved reference files are for reading and reviewing changes.
3. Validate the complete editable file against the checkout. Then apply it and regenerate the engineering references.

```sh
python3 scripts/design-handoff/freeze-design.py /path/to/Reviewed-changes-editable.json
python3 scripts/design-handoff/freeze-design.py /path/to/Reviewed-changes-editable.json \
  --apply --references docs/design-handoff
```

4. Review the resulting Git diff, rebuild the ordinary Mac app and run `DesignLibraryTests`. Include any accompanying SwiftUI renderer changes in the same review. On a new app version, migrate and validate the snapshot against that version's token and assignment contract first.

The bundled snapshot keeps both modes, the primitive and semantic alias relationships, all component mappings and the record of explicit choices. Preserve those together. The static resource files beside it define the starting contract and imported seeds. The runtime loader is `DesignLibraryRuntime`. Shared controls and theme assignments are in `Views/DesignSystem` and `Models/Theme/DesignLibrary`. The editor and its previews are under `DevelopmentDesign`.

## Maintain the icon

The artwork masters are in the ZIP's Assets folder. To regenerate both outputs from a new 1024 × 1024 PNG, install Pillow in a Python environment and run:

```sh
python3 scripts/design-handoff/build-app-icons.py /path/to/lime-master.png \
  --mac-catalog App/osaurus/Assets.xcassets/AppIcon.appiconset \
  --ios-out /path/to/Osaurus-AppIcon-iOS-1024.png
```

The Mac generator follows the existing Xcode slot manifest. The iOS export preserves the artwork's embedded color profile and uses RGB PNG with an opaque, full-square background. Use it in the default iOS app-icon slot. Keep the mark and background editable separately in Paper if the iOS project uses Icon Composer. [Apple's app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)

## Integration boundaries

- Settings sidebar search follows semantic colors but retains its own input styling. It is the accepted shared Inputs assignment exception.
- Inputs support optional labels. The native date/time popup remains system-owned. The closed field is the styleable control.
- Context menus use click to open. Preserve the existing actions and visibility rules when merging.
- Keep the single blurred window base and opaque component surfaces. Figma-only preview adapters stay out of the native token model.
