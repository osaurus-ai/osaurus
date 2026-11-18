# Themes

A theme paints every Osaurus window: colors, fonts and readability. Pick one in
**Settings → General → Appearance → Theme** or **View → Theme**.

Themes are generated, not hand-painted. A theme stores a few choices (accent,
tone, contrast, corners, transparency, readability) plus optional token overrides. Osaurus
layers them onto the bundled design library (`design-library.json`) and checks
the result for contrast. Every theme therefore keeps the same components,
spacing and states, and the default **Osaurus** theme is the bundled design
itself.

## Built-in themes

| Theme    | Tone    | Accent   | Notes                                             |
| -------- | ------- | -------- | ------------------------------------------------- |
| Osaurus  | Warm    | Teal     | The default: cream neutrals, teal actions and lime highlights in light; near-black with lime actions and teal links in dark (osaurus.ai brand) |
| Graphite | Neutral | Graphite | Monochrome, the pre-brand 1.0 look                |
| Nord     | Cool    | Blue     |                                                   |
| Paper    | Warm    | Amber    | Light only, subtle corners, solid window          |
| Terminal | Neutral | Green    | Dark only, SF Mono interface font                 |

Built-in themes are read-only. **Duplicate** one to make it your own.

## The editor

**New Theme**, **Edit…** and **Duplicate** open the editor. Changes preview
across Osaurus while it is open; **Cancel** puts the saved theme back.

- **Accent**: buttons, links and focus. Seven swatches, or any custom color.
  A custom color keeps its hue. Chroma is capped and lightness is solved
  separately for light and dark so links and focus rings reach 4.5:1 and
  filled buttons reach 4.5:1 for their labels.
- **Tone**: Warm, Neutral or Cool backgrounds and borders.
- **Appearance**: Light and Dark, Light only, or Dark only. A single-mode
  theme locks General → Appearance while it is active.
- **Contrast**: Standard, or High (7:1 text, 4.5:1 control borders). macOS
  **Increase Contrast** turns High on for every theme.
- **Corners**: Rounded, or Subtle for tighter radii.
- **Transparency**: how much of the desktop shows through the icon rail and
  title bar. **Frosted** (the default) tints the blur heavily, **Glass** lets
  more through, and **Solid** makes them opaque. The window keeps three tones
  at every level: content, the opaque sidebar, and the rail. macOS **Reduce
  Transparency** and **Increase Contrast** make every theme solid.
- **Readability**: **Reading Size** (Default, Large, Larger; stacks with
  Text Size), **Line Spacing** (Default, Relaxed), **Interface Font** and
  **Code Font**, **Stronger Outlines** and **Larger Controls**.

The font menus list System, then readable families that are installed:
Atkinson Hyperlegible, Lexend, OpenDyslexic, Inter and IBM Plex Sans for the
interface; Menlo, JetBrains Mono, IBM Plex Mono and Fira Code for code. A
family that is missing on this Mac falls back to the system font.

## Files

Themes live in `~/.osaurus/themes/library/<id>.json`. **Show Themes Folder**
opens it. Files edited in another app reload when Osaurus regains focus.
**Import Theme…** and **Export…** read and write the same format; an imported
theme whose id is already taken gets a new one.

```json
{
  "appearance": "both",
  "author": "",
  "createdAt": "2026-11-16T12:00:00Z",
  "id": "0E1C4B7A-5F3E-4D0B-9C51-2B7A0F6E8D21",
  "name": "Reading Room",
  "overrides": {
    "tokens": {
      "color.text.link": { "light": "#0B5F8A", "dark": "#6CC4F0" },
      "type.chatBody": { "light": { "size": 17, "lineHeight": 26 }, "dark": { "size": 17, "lineHeight": 26 } }
    }
  },
  "preferences": {
    "accent": { "swatch": "blue" },
    "contrast": "standard",
    "corners": "rounded",
    "readability": {
      "codeFont": "system",
      "largerControls": false,
      "lineSpacing": "relaxed",
      "readingSize": "large",
      "strongerOutlines": false,
      "uiFont": "Atkinson Hyperlegible"
    },
    "tone": "cool",
    "transparency": "frosted"
  },
  "schemaVersion": 1,
  "updatedAt": "2026-11-16T12:00:00Z"
}
```

- `preferences.accent` is `{ "swatch": "teal" | "blue" | "violet" | "rose" | "amber" | "green" | "graphite" }`
  or `{ "custom": "#RRGGBB" }`.
- `codeHighlightTheme` (optional) names the syntax highlighting theme for code
  blocks. `messages` (optional) has `showInlineAvatar` and `showAgentName`.
- Unknown keys are rejected so typos surface instead of silently doing
  nothing. A file with a newer `schemaVersion` is refused.

## JSON overrides

**Edit JSON…** opens the theme file in a validating editor. `overrides.tokens`
sets design-library tokens directly, per mode (`light`, `dark`, or both).
Overrides win over the editor choices; **Reset to Preferences** removes them.

| Tokens                                              | Values                                      |
| --------------------------------------------------- | ------------------------------------------- |
| `color.*` (except `color.status.*`, `color.data.*`) | `#RRGGBB` or `#RRGGBBAA`                    |
| `material.window.tint`, `.fallback`                 | color                                       |
| `material.window.tintOpacity`                       | 0 to 1                                      |
| `material.window.nativeMaterial`, `.blending`       | one of the library's choices                |
| `font.family.ui`, `font.family.code`                | a font family name, or `system`             |
| `type.*`                                            | `{ "size", "lineHeight", "weight" }`; size 11 to 32 (12 minimum for body and caption styles), line height 1.1 to 1.8 × size, weight 100 to 900 |
| `stroke.default`, `stroke.focus`                    | 0.5 to 4                                    |
| `radius.*`                                          | 0 to 20 (`radius.pill` keeps its shape)     |
| `size.control.defaultHeight`, `.compactHeight`      | 24 to 48                                    |
| `size.row.minimumHeight`                            | 24 to 56                                    |
| `size.chat.avatar`                                  | 16 to 40                                    |
| `motion.duration.*`                                 | 0 to 0.6 seconds                            |
| `motion.spring`                                     | response 0 to 0.6, damping 0.1 to 1         |
| `motion.easing`                                     | `linear`, `easeIn`, `easeOut`, `easeInOut`  |

Out-of-range numbers are clamped with a warning. Wrong types, unknown tokens
and malformed colors are errors, reported with their line number, and the file
is not saved until they are fixed. Status and data-visualization colors are
not overridable so warnings and charts read the same in every theme.

A theme whose overrides bring text or controls below the contrast targets
still loads, but its card shows a **Low contrast** badge and the editor lists
each failing pair.

## Upgrading from Classic

Classic custom themes convert once on upgrade (`ClassicThemeMigrator`), keeping
their ids. Tone and accent are matched from the theme's colors; fonts, text
sizes, corner roundness, border width, motion, code highlighting and message
avatar settings carry over. The theme that was active stays active. Classic's
built-in Light, Dark, Osaurus Light, Osaurus Dark and Neon map to the Osaurus
theme in the matching appearance; Nord, Paper and Terminal map to the presets of
the same name. The Classic files stay where they were.

## Where it lives in code

- `Models/Theme/ThemeDocument.swift`: the file format.
- `Models/Theme/ThemePresets.swift`: the built-in themes.
- `Models/Theme/ThemeLibraryStore.swift`: the library on disk.
- `Models/Theme/Generator/ThemeGenerator.swift`: tones, the accent solver,
  high contrast and readability.
- `Models/Theme/Generator/ThemeTokenPolicy.swift`: JSON validation and ranges.
- `Models/Theme/Generator/ThemeCompiler.swift`: document to design snapshot,
  plus the contrast report.
- `Models/Theme/ClassicThemeMigrator.swift`: Classic conversion.
- `Views/Settings/ThemesView.swift`, `ThemeEditorSheet.swift`: the UI.
- `Views/DesignSystem/SettingsThemeKit.swift`: the kit pieces it is built from.
