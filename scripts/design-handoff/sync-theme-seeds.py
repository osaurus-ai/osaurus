#!/usr/bin/env python3
"""Rewrite the Swift theme seeds from the bundled design library.

`CustomTheme.lightDefault/darkDefault` are the shape the library resolves onto.
Their values must equal the library so a theme built before (or without) the
overlay paints the same colors. Run after installing a new library:

    python3 scripts/design-handoff/sync-theme-seeds.py
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "Packages/OsaurusCore/Models/Theme/DesignLibrary/LibraryResources/design-library.json"
CUSTOM_THEME = ROOT / "Packages/OsaurusCore/Models/Theme/CustomTheme.swift"
TOKENS_SWIFT = ROOT / "Packages/OsaurusCore/Models/Theme/ThemeTokens.swift"

ACTIONS = ("primary", "secondary", "tertiary", "destructive")
STATES = ("default", "hover", "pressed", "disabled")
STATUSES = ("success", "warning", "error", "info")


def palette(tokens, mode):
    def c(name):
        return f'"{tokens["color." + name][mode]}"'

    def action(kind):
        rows = ",\n".join(
            f"                    {state}: ThemeActionState(background: {c(f'action.{kind}.{state}.background')}, "
            f"foreground: {c(f'action.{kind}.{state}.foreground')})"
            for state in STATES
        )
        return f"                {kind}: ThemeActionVariant(\n{rows}\n                )"

    def status(kind):
        return (
            f"                {kind}: ThemeStatusSet(foreground: {c(f'status.{kind}.foreground')}, "
            f"background: {c(f'status.{kind}.background')}, border: {c(f'status.{kind}.border')}, "
            f"ink: {c(f'status.{kind}.ink')})"
        )

    def data_series():
        slots = sorted({int(name.split(".")[2]) for name in tokens if name.startswith("color.data.")})
        return ",\n".join(
            f'                "{n}": ThemeDataSwatch(ink: {c(f"data.{n}.ink")}, wash: {c(f"data.{n}.wash")})'
            for n in slots
        )

    def fields(group, names):
        items = [f"{name}: {c(group + '.' + name)}" for name in names]
        return ",\n                ".join(", ".join(items[i:i + 4]) for i in range(0, len(items), 4))

    surface = fields("surface", ("canvas", "subtle", "raised", "overlay", "sidebar", "code", "hover", "pressed", "selected", "disabled"))
    text = fields("text", ("primary", "secondary", "tertiary", "placeholder", "disabled", "inverse", "onDanger", "link", "linkHover"))
    border = ", ".join(f"{name}: {c('border.' + name)}" for name in ("subtle", "default", "strong", "focus", "error"))
    return f"""        ThemeSemanticColors(
            surface: ThemeSurfaceRoles(
                {surface}
            ),
            text: ThemeTextRoles(
                {text}
            ),
            chat: ThemeChatRoles(userBackground: {c('chat.user.background')}, assistantBackground: {c('chat.assistant.background')}),
            action: ThemeActionRoles(
{",\n".join(action(kind) for kind in ACTIONS)},
                border: {c('action.border')}
            ),
            border: ThemeBorderRoles(
                {border}),
            selection: ThemeSelectionRoles(background: {c('selection.background')}, foreground: {c('selection.foreground')}),
            cursor: {c('cursor')},
            status: ThemeStatusRoles(
{",\n".join(status(kind) for kind in STATUSES)}
            ),
            danger: ThemeDangerRoles(default: {c('danger.default')}, hover: {c('danger.hover')}, pressed: {c('danger.pressed')}),
            scrim: {c('scrim')},
            shadow: {c('shadow')},
            data: [
{data_series()}
            ]
        )"""


def replace_body(source, name, body):
    pattern = re.compile(
        rf"(public static var {name}: ThemeSemanticColors \{{\n)(.*?)(\n    \}})", re.S
    )
    updated, count = pattern.subn(lambda m: m.group(1) + body + m.group(3), source)
    if count != 1:
        raise SystemExit(f"could not find {name} in {CUSTOM_THEME}")
    return updated


def number(value):
    return str(int(value)) if float(value).is_integer() else str(value)


def sync_typography(source, library):
    """One seed serves both modes, so styles take the light recipe."""
    tokens, aliases, scalars = library["tokens"], library.get("valueAliases", {}), library.get("scalarPrimitives", {})

    def field(name, key):
        ref = aliases.get(f"type.{name}.{key}", {}).get("light")
        return scalars[ref]["light"] if ref else tokens[f"type.{name}"]["light"][key]

    def style(match):
        name, family = match.group(1), match.group(2) or ""
        if f"type.{name}" not in tokens:
            return match.group(0)
        recipe = {key: field(name, key) for key in ("size", "weight", "lineHeight")}
        return (
            f"        {name}: ThemeTextStyle = ThemeTextStyle({family}size: {number(recipe['size'])}, "
            f"weight: {number(recipe['weight'])}, lineHeight: {number(recipe['lineHeight'])})"
        )
    return re.sub(
        r"^        (\w+): ThemeTextStyle = ThemeTextStyle\((family: \.\w+, )?size: [\d.]+, weight: [\d.]+, lineHeight: [\d.]+\)",
        style, source, flags=re.M,
    )


def main():
    library = json.loads(LIBRARY.read_text())
    tokens = library["tokens"]
    source = CUSTOM_THEME.read_text()
    source = replace_body(source, "lightDefaults", palette(tokens, "light"))
    source = replace_body(source, "darkDefaults", palette(tokens, "dark"))
    CUSTOM_THEME.write_text(source)

    material = TOKENS_SWIFT.read_text()
    for mode, name in (("light", "lightDefaults"), ("dark", "darkDefaults")):
        tint = tokens["material.window.tint"][mode]
        opacity = tokens["material.window.tintOpacity"][mode]
        fallback = tokens["material.window.fallback"][mode]
        material, count = re.subn(
            rf"public static var {name}: ThemeWindowMaterial \{{\n?.*?\n?\s*\}}\n",
            f"public static var {name}: ThemeWindowMaterial {{\n"
            f'        ThemeWindowMaterial(tint: "{tint}", tintOpacity: {opacity}, fallback: "{fallback}")\n'
            f"    }}\n",
            material,
            count=1,
            flags=re.S,
        )
        if count != 1:
            raise SystemExit(f"could not find ThemeWindowMaterial.{name}")
    material = sync_typography(material, library)
    TOKENS_SWIFT.write_text(material)
    print("Theme seeds synced from", LIBRARY.relative_to(ROOT))


if __name__ == "__main__":
    main()
