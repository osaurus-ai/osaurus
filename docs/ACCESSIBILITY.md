# Accessibility Compliance Summary

**Document Version:** 1.0
**Last Updated:** December 2025
**Standard:** WCAG 2.1 Level AA

---

## Overview

Osaurus is committed to providing an accessible experience for all users. This document outlines our compliance with the Web Content Accessibility Guidelines (WCAG) 2.1 Level AA standards, specifically focusing on color contrast requirements.

---

## WCAG 2.1 Color Contrast Requirements

| Criterion                                         | Requirement | Our Target |
| ------------------------------------------------- | ----------- | ---------- |
| **1.4.3 Contrast (Minimum)** - Normal text        | 4.5:1       | ≥5:1       |
| **1.4.3 Contrast (Minimum)** - Large text (18pt+) | 3:1         | ≥4:1       |
| **1.4.11 Non-text Contrast** - UI components      | 3:1         | ≥3:1       |

---

## Color Palette Compliance

The values below are the default **Osaurus** theme's semantic palettes in
[`CustomTheme.swift`](../Packages/OsaurusCore/Models/Theme/CustomTheme.swift)
(`ThemeColorRoles.lightDefaults` / `.darkDefaults`), generated from the
bundled design library: cream neutrals, teal for links and focus, and teal
(light) or lime (dark) for primary actions. Ratios are measured against each
appearance's canvas surface (`#FBFAF7` light, `#121211` dark). Regenerate this
table whenever those palettes change.

### Light Appearance

| Element           | Hex Code  | Contrast Ratio | Status        |
| ----------------- | --------- | -------------- | ------------- |
| **Text Colors**   |           |                |               |
| Primary Text      | `#2F2C29` | 13.3:1         | ✅ AAA        |
| Secondary Text    | `#494540` | 9.1:1          | ✅ AAA        |
| Tertiary Text     | `#5B5753` | 6.9:1          | ✅ AA         |
| Link              | `#076869` | 6.3:1          | ✅ AA         |
| Disabled Text     | `#898681` | 3.5:1          | Exempt (inactive) |
| **Status Colors** |           |                |               |
| Success           | `#227758` | 5.2:1          | ✅ AA         |
| Warning           | `#976000` | 5.0:1          | ✅ AA         |
| Error             | `#9B2208` | 7.7:1          | ✅ AAA        |
| Info              | `#0E4F90` | 7.9:1          | ✅ AAA        |
| **UI Components** |           |                |               |
| Primary Action    | `#065456` | 8.3:1 (label 8.5:1) | ✅ AAA   |
| Strong Border     | `#898681` | 3.5:1          | ✅ AA         |
| Default Border    | `#BAB9B1` | 1.9:1          | Decorative    |
| Subtle Border     | `#D9D9CD` | 1.4:1          | Decorative    |
| Focus Border      | `#076869` | 6.3:1          | ✅ AA         |

### Dark Appearance

| Element           | Hex Code  | Contrast Ratio | Status        |
| ----------------- | --------- | -------------- | ------------- |
| **Text Colors**   |           |                |               |
| Primary Text      | `#FBFAF7` | 18.0:1         | ✅ AAA        |
| Secondary Text    | `#D9D9CD` | 13.2:1         | ✅ AAA        |
| Tertiary Text     | `#A2A09A` | 7.2:1          | ✅ AAA        |
| Link              | `#0DB1B5` | 7.1:1          | ✅ AAA        |
| Disabled Text     | `#56524D` | 2.4:1          | Exempt (inactive) |
| **Status Colors** |           |                |               |
| Success           | `#4CE5AD` | 11.7:1         | ✅ AAA        |
| Warning           | `#FFB35C` | 10.6:1         | ✅ AAA        |
| Error             | `#F37358` | 6.6:1          | ✅ AA         |
| Info              | `#70B8FF` | 8.9:1          | ✅ AAA        |
| **UI Components** |           |                |               |
| Primary Action    | `#C0EC51` | 13.7:1 (label 13.7:1) | ✅ AAA |
| Strong Border     | `#75716D` | 3.9:1          | ✅ AA         |
| Default Border    | `#3E3B37` | 1.7:1          | Decorative    |
| Subtle Border     | `#312E2B` | 1.4:1          | Decorative    |
| Focus Border      | `#0DB1B5` | 7.1:1          | ✅ AA         |

Default and subtle borders separate surfaces that already differ in fill, so they
are decorative under 1.4.11. A control whose boundary is its only visual cue must
use the strong or focus border.

---

## Color Change Guidelines

When changing the light or dark palette, ensure:

1. **Primary text** maintains at least **7:1** contrast for optimal readability
2. **Secondary text** maintains at least **4.5:1** contrast
3. **Tertiary text** maintains at least **4.5:1** contrast (used for help text, captions)
4. **UI components** (borders, icons, controls) maintain at least **3:1** contrast
5. **Focus indicators** are clearly visible with at least **3:1** contrast

### Contrast Calculation Formula

```
Contrast Ratio = (L1 + 0.05) / (L2 + 0.05)

Where L1 = lighter color luminance, L2 = darker color luminance
Luminance = 0.2126 × R + 0.7152 × G + 0.0722 × B
```

---

## Additional Accessibility Features

### Keyboard Navigation

- Full keyboard navigation support throughout the application
- Visible focus indicators on all interactive elements
- Logical tab order following visual layout

### Screen Reader Support

- Semantic markup for all UI components
- Descriptive labels for icons and buttons
- Status announcements for dynamic content

### Motion & Animation

- Respects system "Reduce Motion" preferences
- Animations can be disabled via system settings
- No content relies solely on animation to convey information

### Typography

- Text Size (Settings → General → Appearance, or View → Zoom In / Zoom Out) scales text everywhere from 70% to 160%
- A theme's **Reading Size** (Large, Larger) enlarges chat and body text on top of Text Size, and **Line Spacing → Relaxed** opens up line height
- A theme's **Interface Font** and **Code Font** can use installed readable families (Atkinson Hyperlegible, Lexend, OpenDyslexic, Inter, IBM Plex)
- System font support for optimal rendering
- Minimum text size of 12pt for body content; theme JSON cannot set body text below it

---

## Testing Methodology

Our accessibility testing includes:

1. **Automated Testing**

   - Contrast ratio calculations for all color combinations
   - Verification against WCAG 2.1 AA thresholds

2. **Manual Testing**

   - VoiceOver compatibility testing on macOS
   - Keyboard-only navigation testing
   - High contrast mode verification

3. **User Testing**
   - Feedback from users with visual impairments
   - Testing with various color vision deficiency simulations

---

## Known Limitations

1. **Decorative Borders**: Some decorative borders (e.g., card borders, subtle dividers) may not meet the 3:1 contrast requirement, as they are purely decorative and do not convey information.

## Themes

Themes (Settings → General → Appearance → Theme) are generated, not hand-painted,
so every theme keeps the contrast contract above:

- Accent colors, built-in or custom, are solved per appearance so text links and
  focus rings reach 4.5:1 and filled buttons reach 4.5:1 for their labels (7:1
  under High contrast). A custom color keeps its hue; chroma is capped so
  extreme picks stay calm.
- **Contrast → High** raises text to 7:1 and control borders to 4.5:1, and
  **Stronger Outlines** / **Larger Controls** thicken borders and enlarge hit
  targets. macOS **Increase Contrast** switches every theme to its high-contrast
  colors automatically.
- Hand-edited JSON is kept within safe ranges (minimum text sizes, line height,
  stroke widths, control heights). A theme whose overrides fall below the
  contrast targets still loads, but its card shows a **Low contrast** badge and
  the editor lists each failing pair.

---

## Future Improvements

- [x] Provide accessibility controls for users with specific needs (theme Readability options)
- [x] Honor the macOS Increase Contrast setting with a higher-contrast palette
- [ ] Verify the Light and Dark palettes under color vision deficiency simulations

---

## Reporting Accessibility Issues

If you encounter accessibility issues with Osaurus, please report them:

1. Open an issue on GitHub with the `accessibility` label
2. Include your theme, Appearance (System, Light or Dark) and Text Size
3. Describe the specific accessibility barrier
4. If possible, include a screenshot

---

## References

- [WCAG 2.1 Guidelines](https://www.w3.org/WAI/WCAG21/quickref/)
- [Understanding WCAG 2.1](https://www.w3.org/WAI/WCAG21/Understanding/)
- [Contrast Checker Tool](https://webaim.org/resources/contrastchecker/)
- [Apple Accessibility Guidelines](https://developer.apple.com/accessibility/)

---

_This document is updated with each release that includes accessibility improvements._
