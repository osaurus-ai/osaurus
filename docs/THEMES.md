# Theme JSON Reference

This document describes the JSON schema for Osaurus custom themes. Themes can be imported and exported as `.json` files through the Themes view.

## General Notes

- **Colors** are hex strings: `"#RRGGBB"` for opaque, `"#AARRGGBB"` for colors with alpha (e.g. `"#80FF0000"` is 50% transparent red).
- **Dates** use ISO 8601 format: `"2026-01-15T00:00:00Z"`.
- **`metadata.id`** is ignored on import -- a new UUID is always generated.
- **`isBuiltIn`** is forced to `false` on import.
- All top-level sections are required unless noted otherwise.

## Top-Level Structure

```json
{
  "metadata": { ... },
  "colors": { ... },
  "background": { ... },
  "glass": { ... },
  "typography": { ... },
  "animationConfig": { ... },
  "shadows": { ... },
  "messages": { ... },
  "borders": { ... },
  "isBuiltIn": false,
  "isDark": true
}
```

| Field | Type | Description |
|---|---|---|
| `isBuiltIn` | Bool | Always set to `false` for custom themes. Forced to `false` on import. |
| `isDark` | Bool | Whether this is a dark theme. Affects system appearance matching. |

`messages` and `borders` are optional -- they fall back to defaults if omitted.

---

## metadata

| Field | Type | Default | Description |
|---|---|---|---|
| `id` | String | *(ignored)* | Ignored on import; a new UUID is generated automatically. |
| `name` | String | `"Custom Theme"` | Display name shown in the theme gallery. |
| `version` | String | `"1.0"` | Version string for the theme. |
| `author` | String | `"User"` | Author name shown below the theme name. |
| `createdAt` | String (ISO 8601) | *(now)* | Creation timestamp. Overwritten on import. |
| `updatedAt` | String (ISO 8601) | *(now)* | Last update timestamp. Overwritten on import. |

---

## colors

All values are hex color strings.

| Field | Default (Dark) | Description |
|---|---|---|
| `primaryText` | `"#f9fafb"` | Main text color. |
| `secondaryText` | `"#a1a1aa"` | Secondary/muted text. |
| `tertiaryText` | `"#8b8b94"` | Tertiary/hint text. |
| `primaryBackground` | `"#0f0f10"` | Main window background. |
| `secondaryBackground` | `"#18181b"` | Elevated surface background. |
| `tertiaryBackground` | `"#27272a"` | Highest elevation background. |
| `sidebarBackground` | `"#141416"` | Sidebar background. |
| `sidebarSelectedBackground` | `"#2a2a2e"` | Selected sidebar item background. |
| `accentColor` | `"#60a5fa"` | Primary accent color (links, buttons, highlights). |
| `accentColorLight` | `"#93c5fd"` | Lighter accent variant for hover/active states. |
| `primaryBorder` | `"#3f3f46"` | Primary border color. |
| `secondaryBorder` | `"#52525b"` | Secondary/decorative border color. |
| `focusBorder` | `"#60a5fa"` | Border color for focused elements. |
| `successColor` | `"#22c55e"` | Success/positive state color. |
| `warningColor` | `"#fbbf24"` | Warning state color. |
| `errorColor` | `"#f87171"` | Error/destructive state color. |
| `infoColor` | `"#60a5fa"` | Informational state color. |
| `cardBackground` | `"#18181b"` | Card/panel background. |
| `cardBorder` | `"#3f3f46"` | Card/panel border. |
| `buttonBackground` | `"#18181b"` | Button background. |
| `buttonBorder` | `"#3f3f46"` | Button border. |
| `inputBackground` | `"#18181b"` | Text input background. |
| `inputBorder` | `"#52525b"` | Text input border. |
| `glassTintOverlay` | `"#00000030"` | Glass tint overlay color (with alpha). |
| `codeBlockBackground` | `"#00000059"` | Code block background (with alpha). |
| `shadowColor` | `"#000000"` | Shadow base color. |
| `selectionColor` | `"#3b82f680"` | Text selection highlight (with alpha). |
| `cursorColor` | `"#3b82f6"` | Text cursor color. |
| `placeholderText` | `"#a1a1aa"` | *(optional)* Placeholder text color. |

---

## background

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | String | `"solid"` | **Required.** One of: `"solid"`, `"gradient"`, `"image"`. |
| `solidColor` | String? | `nil` | Hex color for solid backgrounds. Falls back to `colors.primaryBackground` if `nil`. |
| `gradientColors` | [String]? | `nil` | Array of hex colors for gradient backgrounds. |
| `gradientAngle` | Double? | `nil` | Gradient angle in degrees. |
| `imageData` | String? | `nil` | Base64-encoded image data for image backgrounds. |
| `imageFit` | String? | `nil` | One of: `"fill"`, `"fit"`, `"stretch"`, `"tile"`. |
| `imageOpacity` | Double? | `nil` | Image opacity (0.0 - 1.0). |
| `overlayColor` | String? | `nil` | Hex color overlaid on top of the background. |
| `overlayOpacity` | Double? | `nil` | Overlay opacity (0.0 - 1.0). |

---

## glass

Controls the macOS glass/vibrancy effect.

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | Bool | `true` | Whether the glass effect is active. Set to `false` for solid backgrounds. |
| `material` | String | `"hudWindow"` | macOS material type. See valid values below. |
| `blurRadius` | Double | `30` | Blur intensity. |
| `opacityPrimary` | Double | `0.10` | Opacity for primary glass surfaces. |
| `opacitySecondary` | Double | `0.08` | Opacity for secondary glass surfaces. |
| `opacityTertiary` | Double | `0.05` | Opacity for tertiary glass surfaces. |
| `tintColor` | String? | `nil` | Optional hex tint color applied over glass. |
| `tintOpacity` | Double? | `nil` | Tint strength (0.0 - 1.0). |
| `edgeLight` | String | `"#ffffff33"` | Edge highlight color (hex with alpha). |
| `edgeLightWidth` | Double? | `nil` | Edge highlight width in points. |
| `windowBackingOpacity` | Double | `0.55` | Window backing opacity (0.0 - 1.0). |

### Valid `glass.material` values

These correspond to macOS `NSVisualEffectView.Material`:

| Value | Description |
|---|---|
| `"titlebar"` | Title bar material. |
| `"selection"` | Selection material. |
| `"menu"` | Menu material. |
| `"popover"` | Popover material. |
| `"sidebar"` | Sidebar material. |
| `"headerView"` | Header view material. |
| `"sheet"` | Sheet material. |
| `"windowBackground"` | Window background material. |
| `"hudWindow"` | HUD window material (default). |
| `"fullScreenUI"` | Full screen UI material. |
| `"toolTip"` | Tooltip material. |
| `"contentBackground"` | Content background material. |
| `"underWindowBackground"` | Under-window background material. |
| `"underPageBackground"` | Under-page background material. |

---

## typography

| Field | Type | Default | Description |
|---|---|---|---|
| `primaryFont` | String | `"SF Pro"` | Primary UI font family. |
| `monoFont` | String | `"SF Mono"` | Monospace font for code. |
| `titleSize` | Double | `28` | Title text size in points. |
| `headingSize` | Double | `18` | Heading text size. |
| `bodySize` | Double | `14` | Body text size. |
| `captionSize` | Double | `12` | Caption text size. |
| `codeSize` | Double | `13` | Code/monospace text size. |

---

## animationConfig

| Field | Type | Default | Description |
|---|---|---|---|
| `durationQuick` | Double | `0.2` | Quick animation duration (seconds). |
| `durationMedium` | Double | `0.3` | Medium animation duration. |
| `durationSlow` | Double | `0.4` | Slow animation duration. |
| `springResponse` | Double | `0.4` | Spring animation response time. |
| `springDamping` | Double | `0.8` | Spring animation damping fraction (0.0 - 1.0). |

---

## shadows

| Field | Type | Default | Description |
|---|---|---|---|
| `shadowOpacity` | Double | `0.3` | Base shadow opacity. |
| `cardShadowRadius` | Double | `12` | Card shadow blur radius. |
| `cardShadowRadiusHover` | Double | `20` | Card shadow blur radius on hover. |
| `cardShadowY` | Double | `4` | Card shadow vertical offset. |
| `cardShadowYHover` | Double | `8` | Card shadow vertical offset on hover. |

---

## messages

Optional section -- defaults are used if omitted.

| Field | Type | Default | Description |
|---|---|---|---|
| `bubbleCornerRadius` | Double | `20` | Message bubble corner radius. |
| `userBubbleOpacity` | Double | `0.3` | User message bubble background opacity. |
| `assistantBubbleOpacity` | Double | `0.85` | Assistant message bubble background opacity. |
| `userBubbleColor` | String? | `nil` | Override hex color for user bubbles. Uses `accentColor` if `nil`. |
| `assistantBubbleColor` | String? | `nil` | Override hex color for assistant bubbles. Uses `secondaryBackground` if `nil`. |
| `borderWidth` | Double | `0.5` | Message bubble border width. |
| `showEdgeLight` | Bool | `true` | Whether to show edge light effect on bubbles. |

---

## borders

Optional section -- defaults are used if omitted.

| Field | Type | Default | Description |
|---|---|---|---|
| `defaultWidth` | Double | `1.0` | Default border width for UI elements. |
| `cardCornerRadius` | Double | `12` | Corner radius for card-style elements. |
| `inputCornerRadius` | Double | `8` | Corner radius for input fields. |
| `borderOpacity` | Double | `0.3` | Default border opacity applied to border colors. |

---

## Minimal Example

A minimal dark theme with just the required fields:

```json
{
  "metadata": {
    "id": "anything",
    "name": "My Theme",
    "version": "1.0",
    "author": "Your Name",
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": "2026-01-01T00:00:00Z"
  },
  "colors": {
    "primaryText": "#f9fafb",
    "secondaryText": "#a1a1aa",
    "tertiaryText": "#8b8b94",
    "primaryBackground": "#0f0f10",
    "secondaryBackground": "#18181b",
    "tertiaryBackground": "#27272a",
    "sidebarBackground": "#141416",
    "sidebarSelectedBackground": "#2a2a2e",
    "accentColor": "#60a5fa",
    "accentColorLight": "#93c5fd",
    "primaryBorder": "#3f3f46",
    "secondaryBorder": "#52525b",
    "focusBorder": "#60a5fa",
    "successColor": "#22c55e",
    "warningColor": "#fbbf24",
    "errorColor": "#f87171",
    "infoColor": "#60a5fa",
    "cardBackground": "#18181b",
    "cardBorder": "#3f3f46",
    "buttonBackground": "#18181b",
    "buttonBorder": "#3f3f46",
    "inputBackground": "#18181b",
    "inputBorder": "#52525b",
    "glassTintOverlay": "#00000030",
    "codeBlockBackground": "#00000059",
    "shadowColor": "#000000",
    "selectionColor": "#3b82f680",
    "cursorColor": "#3b82f6"
  },
  "background": {
    "type": "solid"
  },
  "glass": {
    "enabled": true,
    "material": "hudWindow",
    "blurRadius": 30,
    "opacityPrimary": 0.10,
    "opacitySecondary": 0.08,
    "opacityTertiary": 0.05,
    "edgeLight": "#ffffff33",
    "windowBackingOpacity": 0.55
  },
  "typography": {
    "primaryFont": "SF Pro",
    "monoFont": "SF Mono",
    "titleSize": 28,
    "headingSize": 18,
    "bodySize": 14,
    "captionSize": 12,
    "codeSize": 13
  },
  "animationConfig": {
    "durationQuick": 0.2,
    "durationMedium": 0.3,
    "durationSlow": 0.4,
    "springResponse": 0.4,
    "springDamping": 0.8
  },
  "shadows": {
    "shadowOpacity": 0.3,
    "cardShadowRadius": 12,
    "cardShadowRadiusHover": 20,
    "cardShadowY": 4,
    "cardShadowYHover": 8
  },
  "isBuiltIn": false,
  "isDark": true
}
```
