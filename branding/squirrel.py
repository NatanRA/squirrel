"""Squirrel's mascot: a chestnut squirrel sitting up, eyes shut in a smile, holding an acorn.

This file is the only place its shapes live, on a 240-unit grid. Running it writes:

- branding/icon.svg and branding/mark.svg (render_icons.py turns icon.svg into the app icons)
- Android's adaptive icon, themed-icon and notification drawables
- SquirrelArt.swift (iOS, Mac) and SquirrelArt.kt (Android, Windows): the same shapes for
  the launch animation, which moves them as five groups: tail, body, head, ear and hands

    python3 branding/squirrel.py && python3 branding/render_icons.py
"""
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Colours (see README.md)
FUR = "#C0582C"
BELLY = "#FFE2CC"
INNER_EAR = "#F2A488"
PAW = "#FFD9C2"
LINE = "#A8461F"
EYE = "#2E0F04"
BLUSH = "#FF8E73"
NUT = "#8A3515"
CAP = "#4E1C0A"
BACKGROUND = ("#FFF7F0", "#F7DCC8")  # icon gradient, top left to bottom right
OUTLINE_WIDTH = 10  # the gap, in background colour, that separates head and body from the tail

# The drawing is made facing left, then shifted to sit centred on the grid
SHIFT_X = -10

TAIL_PUFFS = [(162, 194, 20), (178, 176, 22), (188, 152, 23), (188, 126, 22), (180, 102, 20), (166, 84, 18), (150, 74, 15)]
BODY = "M84 138 C78 160 80 190 92 206 L150 206 C164 196 168 174 160 154 C152 136 132 128 112 130 C98 131 88 134 84 138 Z"
HEAD = "M64 100 C64 76 84 58 108 58 C132 58 146 76 146 98 C146 120 130 136 106 136 C90 136 78 130 70 122 C62 120 56 114 57 107 C58 102 61 100 64 100 Z"
EAR = "M108 70 C108 58 111 48 117 40 C119 36 123 33 128 31 C126 36 126 40 128 44 C131 52 131 60 129 72 Z"
EAR_INSIDE = "M115 66 C115 58 117 51 121 46 C123 52 124 59 122 67 Z"
ACORN_NUT = "M-10 -1 L10 -1 C10 8 6 14 0 17 C-6 14 -10 8 -10 -1 Z"
ACORN_CAP = "M-13 -2 C-13 -9 -7 -13 0 -13 C7 -13 13 -9 13 -2 C13 0 12 1 10 1 L-10 1 C-12 1 -13 0 -13 -2 Z"
ACORN_STEM = "M-1 -13 C-1 -17 1 -19 4 -21 L5.5 -19 C3 -18 2.5 -16 2.5 -13 Z"


# region Geometry: everything ends up as absolute M/L/Q/C/Z paths

def parse(d):
    tokens = re.findall(r"[MLQCZ]|-?\d*\.?\d+", d)
    arity = {"M": 1, "L": 1, "Q": 2, "C": 3, "Z": 0}
    commands, i = [], 0
    while i < len(tokens):
        command = tokens[i]
        points = [(float(tokens[i + 1 + 2 * k]), float(tokens[i + 2 + 2 * k])) for k in range(arity[command])]
        commands.append((command, points))
        i += 1 + 2 * arity[command]
    return commands


def num(value):
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if text == "-0" else text


def render(commands):
    return " ".join(command + (" " + " ".join(f"{num(x)} {num(y)}" for x, y in points) if points else "")
                    for command, points in commands)


def transform(d, fn):
    return render([(command, [fn(p) for p in points]) for command, points in parse(d)])


def ellipse(cx, cy, rx, ry, angle=0):
    """Four cubic arcs, rotated `angle` degrees about the centre."""
    k = 0.5523
    d = (f"M{cx + rx} {cy} C{cx + rx} {cy + k * ry} {cx + k * rx} {cy + ry} {cx} {cy + ry} "
         f"C{cx - k * rx} {cy + ry} {cx - rx} {cy + k * ry} {cx - rx} {cy} "
         f"C{cx - rx} {cy - k * ry} {cx - k * rx} {cy - ry} {cx} {cy - ry} "
         f"C{cx + k * rx} {cy - ry} {cx + rx} {cy - k * ry} {cx + rx} {cy} Z")
    return transform(d, rotation(angle, cx, cy))


def rotation(angle, cx=0, cy=0):
    a = math.radians(angle)

    def fn(p):
        x, y = p[0] - cx, p[1] - cy
        return cx + x * math.cos(a) - y * math.sin(a), cy + x * math.sin(a) + y * math.cos(a)
    return fn


def acorn_part(d, x, y, scale, angle):
    rotate = rotation(angle)
    return transform(d, lambda p: tuple(c + o for c, o in zip(rotate((p[0] * scale, p[1] * scale)), (x, y))))


def points(d):
    """Enough points along a path for a bounding box."""
    out, current = [], (0, 0)
    for command, pts in parse(d):
        if command in "ML":
            current = pts[0]
            out.append(current)
        elif command in "QC":
            controls = [current] + pts
            for step in range(1, 21):
                u = step / 20
                n = len(controls) - 1
                out.append(tuple(sum(math.comb(n, i) * (1 - u) ** (n - i) * u ** i * c[axis] for i, c in enumerate(controls))
                                 for axis in (0, 1)))
            current = pts[-1]
    return out


def bbox(paths):
    pts = [p for d in paths for p in points(d)]
    return min(x for x, _ in pts), min(y for _, y in pts), max(x for x, _ in pts), max(y for _, y in pts)

# endregion


def shape(d, fill=None, alpha=1.0, stroke=None, width=0.0):
    return {"d": transform(d, lambda p: (p[0] + SHIFT_X, p[1])), "fill": fill, "alpha": alpha, "stroke": stroke, "width": width}


TAIL = [shape(ellipse(x, y, r, r), FUR) for x, y, r in TAIL_PUFFS]
BODY_SHAPES = [shape(BODY, FUR), shape(ellipse(140, 186, 22, 22), FUR), shape(ellipse(100, 205, 20, 7), FUR)]
BODY_PARTS = BODY_SHAPES + [
    shape(ellipse(102, 168, 16, 24), BELLY),
    shape("M126 176 C130 168 142 164 152 170", stroke=LINE, width=3),
]
EAR_PARTS = [shape(EAR, FUR), shape(EAR_INSIDE, INNER_EAR)]
HEAD_PARTS = [
    shape(HEAD, FUR),
    shape("M80 97 Q88 86 96 97", stroke=EYE, width=4),  # closed, smiling eye
    shape("M63 114 Q67 119 72 115", stroke=EYE, width=2.5),  # mouth
    shape(ellipse(99, 114, 9, 5.5), BLUSH, alpha=0.55),
    shape(ellipse(60, 106, 4, 3.2), EYE),  # nose
]
HANDS = [
    shape(acorn_part(ACORN_NUT, 92, 172, 1.25, 6), NUT),
    shape(acorn_part(ACORN_CAP, 92, 172, 1.25, 6), CAP),
    shape(acorn_part(ACORN_STEM, 92, 172, 1.25, 6), CAP),
    shape(ellipse(84, 162, 8, 6.5, -10), PAW),
    shape(ellipse(102, 164, 8, 6.5, 20), PAW),
]
# The outline behind head and body (not the tail) keeps them readable against the tail
BODY_OUTLINE = [s["d"] for s in BODY_SHAPES]
HEAD_OUTLINE = [shape(HEAD)["d"], shape(EAR)["d"]]
SILHOUETTE = [s["d"] for s in TAIL + BODY_SHAPES] + HEAD_OUTLINE

ALL_PATHS = [s["d"] for s in TAIL + BODY_PARTS + EAR_PARTS + HEAD_PARTS + HANDS]


def pivot(paths, fx, fy):
    x0, y0, x1, y1 = bbox(paths)
    return round(x0 + fx * (x1 - x0), 1), round(y0 + fy * (y1 - y0), 1)


PIVOTS = {
    "all": pivot(ALL_PATHS, 0.5, 1.0),  # squash on landing
    "tail": pivot([s["d"] for s in TAIL], 0.1, 1.0),  # fluffs out from its base
    "head": pivot([s["d"] for s in EAR_PARTS + HEAD_PARTS], 0.6, 1.0),  # tilts at the neck
    "ear": pivot([EAR_PARTS[0]["d"]], 0.3, 1.0),  # twitches at its base
}


# region Writers

def write(relative, text):
    path = os.path.join(REPO, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    print("wrote", relative)


def svg_shapes(shapes, indent="  "):
    lines = []
    for s in shapes:
        if s["stroke"]:
            lines.append(f'{indent}<path d="{s["d"]}" fill="none" stroke="{s["stroke"]}" stroke-width="{num(s["width"])}" stroke-linecap="round"/>')
        else:
            opacity = f' opacity="{num(s["alpha"])}"' if s["alpha"] < 1 else ""
            lines.append(f'{indent}<path d="{s["d"]}" fill="{s["fill"]}"{opacity}/>')
    return "\n".join(lines)


def svg_outline(paths, paint, indent="  "):
    body = "".join(f'<path d="{d}"/>' for d in paths)
    return f'{indent}<g fill="{paint}" stroke="{paint}" stroke-width="{OUTLINE_WIDTH}" stroke-linejoin="round">{body}</g>'


def svg_squirrel(paint):
    return "\n".join([
        svg_shapes(TAIL),
        svg_outline(BODY_OUTLINE, paint),
        svg_shapes(BODY_PARTS),
        svg_outline(HEAD_OUTLINE, paint),
        svg_shapes(EAR_PARTS + HEAD_PARTS + HANDS),
    ])


def write_svgs():
    gradient = (f'<linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="240" y2="240">'
                f'<stop offset="0" stop-color="{BACKGROUND[0]}"/><stop offset="1" stop-color="{BACKGROUND[1]}"/></linearGradient>')
    write("branding/icon.svg", f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<!-- Generated by branding/squirrel.py -->
<g transform="scale({1024 / 240:.6f})">
  <defs>{gradient}</defs>
  <rect width="240" height="240" fill="url(#bg)"/>
{svg_squirrel("url(#bg)")}
</g>
</svg>
""")
    write("branding/mark.svg", f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240">
<!-- Generated by branding/squirrel.py. The squirrel alone; icon.svg adds the background. -->
{svg_squirrel(BACKGROUND[0])}
</svg>
""")


def vector(paths_xml, size, scale, tx, ty, extra_ns=""):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by branding/squirrel.py -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"{extra_ns}
    android:width="{size}dp" android:height="{size}dp"
    android:viewportWidth="{size}" android:viewportHeight="{size}">
    <group android:scaleX="{scale:.4f}" android:scaleY="{scale:.4f}"
        android:translateX="{tx:.2f}" android:translateY="{ty:.2f}">
{paths_xml}
    </group>
</vector>
"""


def fitted(size, height):
    """Scale and offset that give the squirrel `height` dp, centred in a `size` dp square."""
    x0, y0, x1, y1 = bbox(ALL_PATHS)
    scale = height / (y1 - y0)
    return scale, size / 2 - scale * (x0 + x1) / 2, size / 2 - scale * (y0 + y1) / 2


def write_android():
    res = "android/app/src/main/res/drawable/"
    indent = "        "

    def paths(shapes):
        out = []
        for s in shapes:
            if s["stroke"]:
                out.append(f'{indent}<path android:pathData="{s["d"]}" android:strokeColor="{s["stroke"]}" '
                           f'android:strokeWidth="{num(s["width"])}" android:strokeLineCap="round" />')
            else:
                alpha = f' android:fillAlpha="{num(s["alpha"])}"' if s["alpha"] < 1 else ""
                out.append(f'{indent}<path android:pathData="{s["d"]}" android:fillColor="{s["fill"]}"{alpha} />')
        return out

    def outline(ds):
        # Solid mid-tone of the background gradient
        return [f'{indent}<path android:pathData="{d}" android:fillColor="#FCEBDD" android:strokeColor="#FCEBDD" '
                f'android:strokeWidth="{OUTLINE_WIDTH}" android:strokeLineJoin="round" />' for d in ds]

    full = "\n".join(paths(TAIL) + outline(BODY_OUTLINE) + paths(BODY_PARTS) + outline(HEAD_OUTLINE)
                     + paths(EAR_PARTS + HEAD_PARTS + HANDS))
    silhouette = "\n".join(f'{indent}<path android:pathData="{d}" android:fillColor="#FFFFFF" />' for d in SILHOUETTE)

    # Adaptive icons show a 72 dp circle of the 108 dp layer at most; 64 dp tall keeps the ear tip and feet inside it
    write(res + "ic_launcher_foreground.xml", vector(full, 108, *fitted(108, 64)))
    write(res + "ic_launcher_monochrome.xml", vector(silhouette, 108, *fitted(108, 64)))
    write(res + "ic_notification.xml", vector(silhouette, 24, *fitted(24, 22)))
    write(res + "ic_launcher_background.xml", f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by branding/squirrel.py -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient android:type="linear" android:startX="0" android:startY="0"
                android:endX="108" android:endY="108"
                android:startColor="{BACKGROUND[0]}" android:endColor="{BACKGROUND[1]}" />
        </aapt:attr>
    </path>
</vector>
""")


def write_menu_bar_icon():
    """A one-colour squirrel for the Mac menu bar, as branding/menubar.svg; render_icons.py turns it
    into the template images macOS tints to match the menu bar."""
    x0, y0, x1, y1 = bbox(SILHOUETTE)
    pad = 4
    side = max(x1 - x0, y1 - y0) + 2 * pad
    ox, oy = (x0 + x1 - side) / 2, (y0 + y1 - side) / 2
    body = "".join(f'<path d="{d}"/>' for d in BODY_OUTLINE + HEAD_OUTLINE)
    tail = "".join(f'<path d="{s["d"]}"/>' for s in TAIL)
    eye = shape("M80 97 Q88 86 96 97")["d"]
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="{num(ox)} {num(oy)} {num(side)} {num(side)}" width="18" height="18">
<!-- Generated by branding/squirrel.py -->
<defs>
  <mask id="tail" maskUnits="userSpaceOnUse" x="-50" y="-50" width="340" height="340">
    <rect x="-50" y="-50" width="340" height="340" fill="#fff"/>
    <g fill="#000" stroke="#000" stroke-width="{OUTLINE_WIDTH * 2.2}" stroke-linejoin="round">{body}</g>
  </mask>
  <mask id="face" maskUnits="userSpaceOnUse" x="-50" y="-50" width="340" height="340">
    <rect x="-50" y="-50" width="340" height="340" fill="#fff"/>
    <path d="{eye}" fill="none" stroke="#000" stroke-width="9" stroke-linecap="round"/>
  </mask>
</defs>
<g mask="url(#tail)">{tail}</g>
<g mask="url(#face)">{body}</g>
</svg>
"""
    write("branding/menubar.svg", svg)


def hex_int(color):
    return "0xFF" + color.lstrip("#").upper()


def write_code():
    groups = [("tail", TAIL), ("body", BODY_PARTS), ("ear", EAR_PARTS), ("head", HEAD_PARTS), ("hands", HANDS)]
    outlines = [("bodyOutline", BODY_OUTLINE), ("headOutline", HEAD_OUTLINE)]
    doc = "The launch-screen squirrel on its 240-unit grid. Generated by branding/squirrel.py: edit that, not this file."

    def swift_shape(s):
        if s["stroke"]:
            return f'.init("{s["d"]}", stroke: {hex_int(s["stroke"])}, width: {num(s["width"])})'
        alpha = f', alpha: {num(s["alpha"])}' if s["alpha"] < 1 else ""
        return f'.init("{s["d"]}", fill: {hex_int(s["fill"])}{alpha})'

    swift = [f"// {doc}", "", "enum SquirrelArt {"]
    for name, shapes in groups:
        swift.append(f"    static let {name}: [SquirrelShape] = [")
        swift += [f"        {swift_shape(s)}," for s in shapes]
        swift.append("    ]")
    for name, ds in outlines:
        swift.append(f"    static let {name}: [String] = [")
        swift += [f'        "{d}",' for d in ds]
        swift.append("    ]")
    swift.append(f"    static let outlineWidth = {num(OUTLINE_WIDTH)}.0")
    for name, (x, y) in PIVOTS.items():
        swift.append(f"    static let {name}Pivot = CGPoint(x: {num(x)}, y: {num(y)})")
    swift.append("}")
    swift_text = "import CoreGraphics\n\n" + "\n".join(swift) + "\n"
    write("ios/App/Sources/SquirrelArt.swift", swift_text)
    write("desktop/macos/App/Sources/SquirrelArt.swift", swift_text)

    def kotlin_shape(s):
        if s["stroke"]:
            return f'SquirrelShape("{s["d"]}", stroke = {hex_int(s["stroke"])}, width = {num(s["width"])}f)'
        alpha = f', alpha = {num(s["alpha"])}f' if s["alpha"] < 1 else ""
        return f'SquirrelShape("{s["d"]}", fill = {hex_int(s["fill"])}{alpha})'

    kotlin = [f"/** {doc} */", "internal object SquirrelArt {"]
    for name, shapes in groups:
        kotlin.append(f"    val {name} = listOf(")
        kotlin += [f"        {kotlin_shape(s)}," for s in shapes]
        kotlin.append("    )")
    for name, ds in outlines:
        kotlin.append(f"    val {name} = listOf(")
        kotlin += [f'        "{d}",' for d in ds]
        kotlin.append("    )")
    kotlin.append(f"    const val OUTLINE_WIDTH = {num(OUTLINE_WIDTH)}f")
    for name, (x, y) in PIVOTS.items():
        kotlin.append(f"    val {name}Pivot = Offset({num(x)}f, {num(y)}f)")
    kotlin.append("}")
    for package, path in [("app.squirrel.ui", "android/app/src/main/java/app/squirrel/ui/SquirrelArt.kt"),
                          ("app.squirrel.ui", "desktop/windows/src/main/kotlin/app/squirrel/ui/SquirrelArt.kt")]:
        write(path, f"package {package}\n\nimport androidx.compose.ui.geometry.Offset\n\n" + "\n".join(kotlin) + "\n")

# endregion


if __name__ == "__main__":
    write_svgs()
    write_android()
    write_menu_bar_icon()
    write_code()
