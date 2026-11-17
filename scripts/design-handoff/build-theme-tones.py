#!/usr/bin/env python3
"""Build the theme tone ramps and the brand defaults.

Every tone shares the Graphite lightness ladder (the 1.0 neutral ramp), so
surface hierarchy and text contrast match in every tone; the brand tones
only drop their dark surfaces lower. Warm takes the hue and chroma of the
osaurus.ai cream scale, Cool a muted slate. The values are
baked into `ThemeTones.swift`; nothing is computed at runtime.

    python3 scripts/design-handoff/build-theme-tones.py            # report only
    python3 scripts/design-handoff/build-theme-tones.py --write    # rewrite Swift + library

`--write` also installs the Osaurus default (Warm tone, teal accent, lime
highlight) into design-library.json; run sync-theme-seeds.py afterwards.
"""

import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "Packages/OsaurusCore/Models/Theme/DesignLibrary/LibraryResources/design-library.json"
TONES_SWIFT = ROOT / "Packages/OsaurusCore/Models/Theme/Generator/ThemeTones.swift"

STEPS = ["0", "50", "100", "200", "300", "400", "500", "600", "700", "800", "900"]
WASHES = {"alpha/contrast-8": 0x14, "alpha/contrast-15": 0x26, "alpha/contrast-20": 0x33}
WASHES_DARK = {"alpha/contrast-8": 0x1A, "alpha/contrast-15": 0x26, "alpha/contrast-20": 0x40}

# The 1.0 palette, captured before the brand remap. Graphite reproduces it.
GRAPHITE = {
    "neutral/0": ("#FBFAF9", "#181816"),
    "neutral/50": ("#F0EFED", "#201F1D"),
    "neutral/100": ("#ECEBE8", "#2A2928"),
    "neutral/200": ("#E5E5E1", "#353331"),
    "neutral/300": ("#D8D8D4", "#3F3D3B"),
    "neutral/400": ("#BAB9B5", "#54524F"),
    "neutral/500": ("#888680", "#73726E"),
    "neutral/600": ("#5A5852", "#A1A09B"),
    "neutral/700": ("#474543", "#D8D8D4"),
    "neutral/800": ("#2D2D2A", "#EEEEEC"),
    "neutral/900": ("#181816", "#FBFAF9"),
}
GRAPHITE_WASH = ("#453d36", "#A1A09B")

# The brand tones' dark surfaces sit lower than Graphite's, on the site's
# darkest cream, with wider steps between canvas, panels and borders. Text
# steps (500 and up) keep the Graphite ladder.
BRAND_DARK_SURFACES = {
    "neutral/0": "#121211",
    "neutral/50": "#1A1918",
    "neutral/100": "#252422",
    "neutral/200": "#302E2C",
    "neutral/300": "#3D3B39",
}

# osaurus.ai design system (light only on the site).
CREAM = ["#fdfcfa", "#f1f0e9", "#e8e8de", "#d7d7cb", "#acaba5", "#77736f",
         "#514d48", "#312e2b", "#211e1c", "#1a1919", "#121211"]
SLATE = ["#f6f8fa", "#eef1f5", "#e3e8ee", "#cfd6df", "#a3adba", "#6f7a88",
         "#4b5563", "#343c48", "#232a33", "#1a1f26", "#13171c"]


def hex_rgb(h):
    h = h.lstrip("#")[:6]
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rgb_hex(rgb):
    return "#" + "".join(f"{max(0, min(255, round(c * 255))):02X}" for c in rgb)


def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def delin(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def to_oklch(h):
    r, g, b = (lin(c) for c in hex_rgb(h))
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def from_oklch(L, C, H):
    a, b = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return rgb_hex(tuple(delin(max(0.0, min(1.0, c))) for c in (r, g, bl)))


def luminance(h):
    r, g, b = (lin(c) for c in hex_rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def tint_curve(reference):
    """(L, C, H) samples of a reference scale, sorted by lightness."""
    return sorted(to_oklch(h) for h in reference)


def sample(curve, L):
    if L <= curve[0][0]:
        return curve[0][1], curve[0][2]
    for (l0, c0, h0), (l1, c1, h1) in zip(curve, curve[1:]):
        if l0 <= L <= l1:
            t = (L - l0) / (l1 - l0) if l1 > l0 else 0
            dh = ((h1 - h0 + 180) % 360) - 180
            return c0 + (c1 - c0) * t, (h0 + dh * t) % 360
    return curve[-1][1], curve[-1][2]


def retint(graphite_hex, curve, chroma_cap):
    L, _, _ = to_oklch(graphite_hex)
    C, H = sample(curve, L)
    return from_oklch(L, min(C, chroma_cap), H)


def build_tone(reference, chroma_cap):
    curve = tint_curve(reference)
    ramp = {name: (retint(light, curve, chroma_cap), retint(BRAND_DARK_SURFACES.get(name, dark), curve, chroma_cap))
            for name, (light, dark) in GRAPHITE.items()}
    wash_light, wash_dark = (retint(GRAPHITE_WASH[0], curve, chroma_cap),
                             retint(GRAPHITE_WASH[1], curve, chroma_cap))
    for name in WASHES:
        ramp[name] = (wash_light + f"{WASHES[name]:02X}", wash_dark + f"{WASHES_DARK[name]:02X}")
    return ramp


def graphite_tone():
    ramp = dict(GRAPHITE)
    for name in WASHES:
        ramp[name] = (GRAPHITE_WASH[0].upper() + f"{WASHES[name]:02X}", GRAPHITE_WASH[1] + f"{WASHES_DARK[name]:02X}")
    return ramp


TONES = {
    "warm": build_tone(CREAM, 0.016),
    "neutral": graphite_tone(),
    "cool": build_tone(SLATE, 0.022),
}

# Accent and highlight primitives for the two fixed swatches. Every other
# swatch and every custom accent is solved at runtime by ThemeGenerator.
ACCENT_FIELDS = ["background", "backgroundHover", "backgroundPressed", "foreground",
                 "border", "link", "linkHover", "focus"]
HIGHLIGHT_FIELDS = ["background", "backgroundHover", "backgroundPressed", "foreground",
                    "foregroundHover", "border", "borderHover", "borderPressed"]
FIXED_ACCENTS = {
    # Brand teal: primary #065456 on the site. Dark mode leads with the site's
    # lime for primary actions and keeps the bright teal for links and focus.
    "teal": {
        "background": ("#065456", "#C0EC51"),
        "backgroundHover": ("#013334", "#CFF07A"),
        "backgroundPressed": ("#076869", "#A7DA2F"),
        "foreground": ("#FDFCFA", "#121211"),
        "border": ("#013334", "#FFFFFF"),
        "link": ("#076869", "#0DB1B5"),
        "linkHover": ("#065456", "#5ED3D5"),
        "focus": ("#076869", "#0DB1B5"),
    },
    # Graphite: exactly the 1.0 monochrome actions.
    "graphite": {
        "background": ("#2D2D2A", "#EEEEEC"),
        "backgroundHover": ("#181816", "#A1A09B"),
        "backgroundPressed": ("#474543", "#EEEEEC"),
        "foreground": ("#FBFAF9", "#181816"),
        "border": ("#181816", "#FFFFFF"),
        "link": ("#181816", "#FBFAF9"),
        "linkHover": ("#2D2D2A", "#EEEEEC"),
        "focus": ("#181816", "#FBFAF9"),
    },
}
FIXED_HIGHLIGHTS = {
    # Dark mode trades places with the teal accent so the two stay distinct.
    "lime": {
        "background": ("#CFF07A", "#0DB1B5"),
        "backgroundHover": ("#C0EC51", "#3FC5C8"),
        "backgroundPressed": ("#A7DA2F", "#0A9EA2"),
        "foreground": ("#1A1919", "#121211"),
        "foregroundHover": ("#1A1919", "#121211"),
        "border": ("#8DC115", "#FFFFFF"),
        "borderHover": ("#7FB10A", "#FFFFFF"),
        "borderPressed": ("#A7DA2F", "#FFFFFF"),
    },
    # Graphite keeps the 1.0 sky brand button.
    "silver": {
        "background": ("#4E7881", "#336170"),
        "backgroundHover": ("#336170", "#517C85"),
        "backgroundPressed": ("#4E7881", "#336170"),
        "foreground": ("#FBFAF9", "#FBFAF9"),
        "foregroundHover": ("#FBFAF9", "#FFFFFF"),
        "border": ("#336170", "#FFFFFF"),
        "borderHover": ("#1E3E48", "#FFFFFF"),
        "borderPressed": ("#4E7881", "#FFFFFF"),
    },
}

# Token aliases that move onto the accent / highlight families.
ALIASES = {
    "color.action.primary.default.background": ("accent/background", "accent/background"),
    "color.action.primary.hover.background": ("accent/backgroundHover", "accent/backgroundHover"),
    "color.action.primary.pressed.background": ("accent/backgroundPressed", "accent/backgroundPressed"),
    "color.action.primary.default.foreground": ("accent/foreground", "accent/foreground"),
    "color.action.primary.hover.foreground": ("accent/foreground", "accent/foreground"),
    "color.action.primary.pressed.foreground": ("accent/foreground", "accent/foreground"),
    "color.action.primary.default.border": ("accent/border", "literal/color.action.primary.default.border"),
    "color.text.link": ("accent/link", "accent/link"),
    "color.text.linkHover": ("accent/linkHover", "accent/linkHover"),
    "color.border.focus": ("accent/focus", "accent/focus"),
    "color.cursor": ("accent/focus", "accent/focus"),
    "color.action.brand.default.background": ("highlight/background", "highlight/background"),
    "color.action.brand.hover.background": ("highlight/backgroundHover", "highlight/backgroundHover"),
    "color.action.brand.pressed.background": ("highlight/backgroundPressed", "highlight/backgroundPressed"),
    "color.action.brand.default.foreground": ("highlight/foreground", "highlight/foreground"),
    "color.action.brand.hover.foreground": ("highlight/foregroundHover", "highlight/foregroundHover"),
    "color.action.brand.pressed.foreground": ("highlight/foreground", "highlight/foreground"),
    "color.action.brand.default.border": ("highlight/border", "literal/color.action.brand.default.border"),
    "color.action.brand.hover.border": ("highlight/borderHover", "literal/color.action.brand.hover.border"),
    "color.action.brand.pressed.border": ("highlight/borderPressed", "literal/color.action.brand.pressed.border"),
    # Three tones in both modes: content, the opaque sidebar, and the frosted
    # icon rail and title band. Dark's pale native material already lifts the
    # rail above the sidebar; light tints it a step darker than the sidebar.
    "material.window.tint": ("neutral/300", "neutral/50"),
    "material.window.fallback": ("neutral/300", "neutral/300"),
}

# Frosted, the default Transparency.
WINDOW_TINT_OPACITY = {"light": 0.7, "dark": 0.55}


def report():
    for tone, ramp in TONES.items():
        print(f"== {tone}")
        for name in [f"neutral/{s}" for s in STEPS] + list(WASHES):
            light, dark = ramp[name]
            print(f"  {name:20} {light}  {dark}")
        for mode, i in (("light", 0), ("dark", 1)):
            canvas = ramp["neutral/0"][i]
            primary = ramp["neutral/800" if i == 0 else "neutral/900"][i]
            tertiary = ramp["neutral/600"][i]
            print(f"  {mode}: primary {contrast(primary, canvas):.2f}  tertiary {contrast(tertiary, canvas):.2f}"
                  f"  tertiary/subtle {contrast(tertiary, ramp['neutral/100'][i]):.2f}")
    for name, accent in FIXED_ACCENTS.items():
        for mode, i in (("light", 0), ("dark", 1)):
            canvas = TONES["warm"]["neutral/0"][i]
            print(f"  {name} {mode}: on-accent {contrast(accent['foreground'][i], accent['background'][i]):.2f}"
                  f" accent/canvas {contrast(accent['background'][i], canvas):.2f}"
                  f" link/canvas {contrast(accent['link'][i], canvas):.2f}"
                  f" hover {contrast(accent['foreground'][i], accent['backgroundHover'][i]):.2f}"
                  f" pressed {contrast(accent['foreground'][i], accent['backgroundPressed'][i]):.2f}")
    for name, hl in FIXED_HIGHLIGHTS.items():
        for mode, i in (("light", 0), ("dark", 1)):
            print(f"  {name} {mode}: on-highlight {contrast(hl['foreground'][i], hl['background'][i]):.2f}"
                  f" hover {contrast(hl['foregroundHover'][i], hl['backgroundHover'][i]):.2f}")


def full(h):
    return h.upper() if len(h) == 9 else h.upper() + "FF"


def swift_pairs(mapping, indent):
    pad = " " * indent
    return "\n".join(
        f'{pad}"{k}": .init(light: "{full(v[0])}", dark: "{full(v[1])}"),' for k, v in sorted(mapping.items()))


def write_swift():
    tones = "\n".join(
        f"        case .{tone}:\n            return [\n{swift_pairs(ramp, 16)}\n            ]" for tone, ramp in TONES.items())
    accents = "\n".join(
        f"        case .{name}:\n            return [\n{swift_pairs({f'accent/{k}': v for k, v in a.items()}, 16)}\n            ]"
        for name, a in FIXED_ACCENTS.items())
    highlights = "\n".join(
        f"        case .{name}:\n            return [\n{swift_pairs({f'highlight/{k}': v for k, v in h.items()}, 16)}\n            ]"
        for name, h in FIXED_HIGHLIGHTS.items())
    body = f"""//
//  ThemeTones.swift
//  osaurus
//
//  Generated by scripts/design-handoff/build-theme-tones.py. Do not edit by
//  hand: change the script and re-run it with --write.
//

import Foundation

extension ThemeTone {{
    /// The tone's `neutral/*` ramp and hover washes, light and dark.
    var primitives: [String: DesignPrimitiveColor] {{
        switch self {{
{tones}
        }}
    }}
}}

enum ThemeFixedAccent: String, CaseIterable, Sendable {{
    case teal, graphite

    var primitives: [String: DesignPrimitiveColor] {{
        switch self {{
{accents}
        }}
    }}
}}

enum ThemeFixedHighlight: String, CaseIterable, Sendable {{
    case lime, silver

    var primitives: [String: DesignPrimitiveColor] {{
        switch self {{
{highlights}
        }}
    }}
}}
"""
    TONES_SWIFT.parent.mkdir(parents=True, exist_ok=True)
    TONES_SWIFT.write_text(body)


def resolve_color_tokens(library):
    """Mirror `DesignWorkingDocument.resolvingColors()` for the stored token values."""
    prims, aliases, tokens = library["primitives"], library["colorAliases"], library["tokens"]

    def color(path, mode, seen=()):
        ref = aliases.get(path, {}).get(mode, "")
        if ref.startswith("@"):
            return color(ref[1:], mode, seen + (path,))
        return prims[ref][mode]

    for path, alias in aliases.items():
        if path not in tokens:
            continue
        for mode in ("light", "dark"):
            if alias.get(mode):
                tokens[path][mode] = color(path, mode)


def write_library():
    library = json.loads(LIBRARY.read_text())
    prims = library["primitives"]
    for name, (light, dark) in TONES["warm"].items():
        prims[name] = {"light": full(light), "dark": full(dark)}
    for name, (light, dark) in FIXED_ACCENTS["teal"].items():
        prims[f"accent/{name}"] = {"light": full(light), "dark": full(dark)}
    for name, (light, dark) in FIXED_HIGHLIGHTS["lime"].items():
        prims[f"highlight/{name}"] = {"light": full(light), "dark": full(dark)}
    for token, (light, dark) in ALIASES.items():
        library["colorAliases"][token] = {"light": light, "dark": dark}
    library["scalarPrimitives"]["values/material/window/tintOpacity"].update(WINDOW_TINT_OPACITY)
    library["tokens"]["material.window.tintOpacity"].update(WINDOW_TINT_OPACITY)
    resolve_color_tokens(library)
    LIBRARY.write_text(json.dumps(library, separators=(",", ":"), sort_keys=True, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    report()
    if "--write" in sys.argv:
        write_swift()
        write_library()
        print("Wrote", TONES_SWIFT.relative_to(ROOT), "and", LIBRARY.relative_to(ROOT))
