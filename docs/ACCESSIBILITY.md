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

### Light Theme

| Element           | Hex Code  | Contrast Ratio | Status        |
| ----------------- | --------- | -------------- | ------------- |
| **Text Colors**   |           |                |               |
| Primary Text      | `#1a1a18` | ~17:1          | ✅ AAA        |
| Secondary Text    | `#555550` | ~7:1           | ✅ AA         |
| Tertiary Text     | `#717168` | ~5.5:1         | ✅ AA         |
| **Status Colors** |           |                |               |
| Success           | `#15803d` | ~4.5:1         | ✅ AA         |
| Warning           | `#a16207` | ~4.5:1         | ✅ AA         |
| Error             | `#dc2626` | ~4.5:1         | ✅ AA         |
| Info              | `#555550` | ~7:1           | ✅ AA         |
| **UI Components** |           |                |               |
| Input Border      | `#a8a8a3` | ~3.5:1         | ✅ AA         |
| Primary Border    | `#d0d0cc` | ~2.2:1         | ✅ Decorative |
| Focus Border      | `#4a4a46` | ~8:1           | ✅ AAA        |

### Dark Theme

| Element           | Hex Code  | Contrast Ratio | Status        |
| ----------------- | --------- | -------------- | ------------- |
| **Text Colors**   |           |                |               |
| Primary Text      | `#f5f5f2` | ~17:1          | ✅ AAA        |
| Secondary Text    | `#a8a8a3` | ~8.5:1         | ✅ AAA        |
| Tertiary Text     | `#8a8a85` | ~5.5:1         | ✅ AA         |
| **Status Colors** |           |                |               |
| Success           | `#22c55e` | ~8:1           | ✅ AAA        |
| Warning           | `#fbbf24` | ~11:1          | ✅ AAA        |
| Error             | `#f87171` | ~6:1           | ✅ AA         |
| Info              | `#60a5fa` | ~6:1           | ✅ AA         |
| **UI Components** |           |                |               |
| Input Border      | `#52525b` | ~3:1           | ✅ AA         |
| Primary Border    | `#3f3f46` | ~2.5:1         | ✅ Decorative |
| Focus Border      | `#8a8a85` | ~5.5:1         | ✅ AA         |

---

## Theme Presets Compliance

### Neon Theme (Dark)

| Element          | Hex Code  | Contrast Ratio | Status |
| ---------------- | --------- | -------------- | ------ |
| Primary Text     | `#f0f0f0` | ~18:1          | ✅ AAA |
| Secondary Text   | `#b0b0b0` | ~9:1           | ✅ AAA |
| Tertiary Text    | `#909090` | ~5.5:1         | ✅ AA  |
| Accent (Magenta) | `#ff00ff` | ~6:1           | ✅ AA  |

### Nord Theme (Dark)

| Element        | Hex Code  | Contrast Ratio | Status |
| -------------- | --------- | -------------- | ------ |
| Primary Text   | `#eceff4` | ~10:1          | ✅ AAA |
| Secondary Text | `#d8dee9` | ~7:1           | ✅ AA  |
| Tertiary Text  | `#b8c4d4` | ~5:1           | ✅ AA  |
| Accent (Frost) | `#88c0d0` | ~7:1           | ✅ AA  |

### Paper Theme (Light)

| Element        | Hex Code  | Contrast Ratio | Status |
| -------------- | --------- | -------------- | ------ |
| Primary Text   | `#3d3d3d` | ~9:1           | ✅ AAA |
| Secondary Text | `#555555` | ~7:1           | ✅ AA  |
| Tertiary Text  | `#737373` | ~5:1           | ✅ AA  |
| Accent (Gold)  | `#9a7b30` | ~4.5:1         | ✅ AA  |

---

## Custom Theme Guidelines

When creating custom themes, users should ensure:

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

- Configurable font sizes via theme settings
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

2. **Custom Themes**: User-created custom themes may not meet accessibility standards. The theme editor does not currently enforce minimum contrast ratios.

---

## Future Improvements

- [ ] Add contrast ratio warnings in the theme editor
- [ ] Provide accessibility presets for users with specific needs
- [ ] Implement automatic contrast adjustment suggestions
- [ ] Add colorblind-friendly theme presets

---

## Reporting Accessibility Issues

If you encounter accessibility issues with Osaurus, please report them:

1. Open an issue on GitHub with the `accessibility` label
2. Include the theme you're using
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
