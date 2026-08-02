---
title: Themes and Appearance
summary: Light/dark/system appearance, the theme gallery, custom themes, and per-agent themes.
order: 140
---

# Themes and Appearance

Osaurus's look is fully customizable: appearance mode, built-in and custom themes, and per-agent themes.

## Appearance mode

System / Light / Dark. Pick it in the Themes tab (applying the built-in Light or Dark theme sets the mode) — or just ask the assistant to "turn on dark mode".

## Theme gallery

- Management (⌘⇧M) → Themes: browse built-in and installed themes, Apply Theme, Import, Export, Share, Delete.
- Themes customize chat colors, glass effects, fonts, animations, and message bubbles; backgrounds can be solid, gradient, or image.
- Create custom themes in the editor with live preview. Colors are `#RRGGBB` or `#AARRGGBB`; `followsSystemAccent` re-derives accent colors from the macOS accent.

## Sharing and importing

- Export/import as `.json` files, or Share to upload and get a share link; Import by ID pulls a shared theme.
- Imported themes always get a fresh id and are never treated as built-in.

## Per-agent themes

Each agent can carry its own theme — switching to that agent applies it, so different agents can feel like different spaces.

## Font size

A global UI font scale lives in settings (independent of the theme's own font sizing). Themes are stored under `~/.osaurus/themes/`.
