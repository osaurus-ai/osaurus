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

The values below are the built-in semantic palettes in
[`CustomTheme.swift`](../Packages/OsaurusCore/Models/Theme/CustomTheme.swift)
(`ThemeColorRoles.lightDefaults` / `.darkDefaults`). Ratios are measured against
each appearance's canvas surface (`#FBFAF9` light, `#181816` dark). Regenerate
this table whenever those palettes change.

### Light Appearance

| Element           | Hex Code  | Contrast Ratio | Status        |
| ----------------- | --------- | -------------- | ------------- |
| **Text Colors**   |           |                |               |
| Primary Text      | `#2D2D2A` | 13.2:1         | ✅ AAA        |
| Secondary Text    | `#474543` | 9.2:1          | ✅ AAA        |
| Tertiary Text     | `#5A5852` | 6.8:1          | ✅ AA         |
| Disabled Text     | `#888680` | 3.5:1          | Exempt (inactive) |
| **Status Colors** |           |                |               |
| Success           | `#227758` | 5.2:1          | ✅ AA         |
| Warning           | `#976000` | 5.0:1          | ✅ AA         |
| Error             | `#9B2208` | 7.7:1          | ✅ AAA        |
| Info              | `#0E4F90` | 7.9:1          | ✅ AAA        |
| **UI Components** |           |                |               |
| Strong Border     | `#888680` | 3.5:1          | ✅ AA         |
| Default Border    | `#BAB9B5` | 1.9:1          | Decorative    |
| Subtle Border     | `#D8D8D4` | 1.4:1          | Decorative    |
| Focus Border      | `#181816` | 17.1:1         | ✅ AAA        |

### Dark Appearance

| Element           | Hex Code  | Contrast Ratio | Status        |
| ----------------- | --------- | -------------- | ------------- |
| **Text Colors**   |           |                |               |
| Primary Text      | `#FBFAF9` | 17.1:1         | ✅ AAA        |
| Secondary Text    | `#D8D8D4` | 12.4:1         | ✅ AAA        |
| Tertiary Text     | `#A1A09B` | 6.8:1          | ✅ AA         |
| Disabled Text     | `#54524F` | 2.3:1          | Exempt (inactive) |
| **Status Colors** |           |                |               |
| Success           | `#4CE5AD` | 11.1:1         | ✅ AAA        |
| Warning           | `#FFB35C` | 10.0:1         | ✅ AAA        |
| Error             | `#F37358` | 6.3:1          | ✅ AA         |
| Info              | `#70B8FF` | 8.5:1          | ✅ AAA        |
| **UI Components** |           |                |               |
| Strong Border     | `#73726E` | 3.7:1          | ✅ AA         |
| Default Border    | `#3F3D3B` | 1.6:1          | Decorative    |
| Subtle Border     | `#353331` | 1.4:1          | Decorative    |
| Focus Border      | `#FBFAF9` | 17.1:1         | ✅ AAA        |

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
- System font support for optimal rendering
- Minimum text size of 12pt for body content

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

Osaurus has no custom themes. Appearance is System, Light or Dark, so the two palettes above are the only ones the app renders.

---

## Future Improvements

- [ ] Provide accessibility presets for users with specific needs
- [ ] Honor the macOS Increase Contrast setting with a higher-contrast palette
- [ ] Verify the Light and Dark palettes under color vision deficiency simulations

---

## Reporting Accessibility Issues

If you encounter accessibility issues with Osaurus, please report them:

1. Open an issue on GitHub with the `accessibility` label
2. Include your Appearance (System, Light or Dark) and Text Size
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
