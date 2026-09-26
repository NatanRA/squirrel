"""Render every app icon from branding/icon.svg.

    pip install cairosvg pillow
    python3 branding/squirrel.py && python3 branding/render_icons.py

squirrel.py draws the squirrel and writes icon.svg, mark.svg and Android's vector icons
(which use mark.svg's paths directly); this script turns icon.svg into the bitmap icons.
"""
import io
import os
import re

import cairosvg
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ICON = open(os.path.join(HERE, 'icon.svg')).read()


def rounded(svg, radius, inset=0):
    """The square icon clipped to a rounded square, `inset` px in from each edge (1024 grid).
    A faint edge keeps the light background from fading into white windows and toolbars."""
    size = 1024 - 2 * inset
    scale = size / 1024
    body = svg.split('>', 1)[1].rsplit('</svg>', 1)[0]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
            f'<defs><clipPath id="r"><rect x="{inset}" y="{inset}" width="{size}" height="{size}" rx="{radius}"/></clipPath></defs>'
            f'<g clip-path="url(#r)"><g transform="translate({inset} {inset}) scale({scale})">{body}</g></g>'
            f'<rect x="{inset + 4}" y="{inset + 4}" width="{size - 8}" height="{size - 8}" rx="{radius - 4}" '
            f'fill="none" stroke="#E4C4AE" stroke-width="8"/></svg>')


def png(svg, size, flatten=False):
    image = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size)))
    return image.convert('RGB') if flatten else image.convert('RGBA')


def save(image, *parts):
    path = os.path.join(REPO, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)
    print('wrote', os.path.relpath(path, REPO))


# iOS: full-bleed and opaque; the system applies the mask
save(png(ICON, 1024, flatten=True), 'ios', 'App', 'Assets.xcassets', 'AppIcon.appiconset', 'icon.png')

# macOS: Apple's grid puts the rounded body at 824/1024 with a ~185 px corner radius
mac = rounded(ICON, radius=185, inset=100)
mac_dir = ('desktop', 'macos', 'App', 'Assets.xcassets', 'AppIcon.appiconset')
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f'icon_{points}x{points}{"@2x" if scale == 2 else ""}.png'
        save(png(mac, points * scale), *mac_dir, name)
        images.append(f'{{"filename":"{name}","idiom":"mac","scale":"{scale}x","size":"{points}x{points}"}}')
with open(os.path.join(REPO, *mac_dir, 'Contents.json'), 'w') as f:
    f.write('{"images":[' + ','.join(images) + '],"info":{"author":"xcode","version":1}}\n')

# Windows and the browser extension: a softly rounded square
soft = rounded(ICON, radius=200)
win_dir = ('desktop', 'windows', 'src', 'main', 'resources')
save(png(soft, 512), *win_dir, 'icon.png')
ico_path = os.path.join(REPO, 'desktop', 'windows', 'icon.ico')
png(soft, 256).save(ico_path, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
print('wrote', os.path.relpath(ico_path, REPO))
for size in (16, 32, 48, 128):
    save(png(soft, size), 'extension', 'icons', f'icon-{size}.png')

# Mac menu bar: black template images, tinted by macOS to suit the menu bar
menu_bar = open(os.path.join(HERE, 'menubar.svg')).read()
menu_dir = ('desktop', 'macos', 'App', 'Assets.xcassets', 'MenuBarIcon.imageset')
for scale in (1, 2, 3):
    save(png(menu_bar, 18 * scale), *menu_dir, f'menubar@{scale}x.png')
with open(os.path.join(REPO, *menu_dir, 'Contents.json'), 'w') as f:
    f.write('{"images":[' + ','.join(
        f'{{"filename":"menubar@{s}x.png","idiom":"universal","scale":"{s}x"}}' for s in (1, 2, 3))
        + '],"info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}}\n')

# Windows installer artwork (Inno Setup's modern wizard; see desktop/windows/packaging/squirrel.iss):
# the side panel of its first and last pages, and the corner image of the others, each at 100% and
# 200% display scale.
MARK = open(os.path.join(HERE, 'mark.svg')).read().split('>', 1)[1].rsplit('</svg>', 1)[0]
GRADIENT = ('<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
            '<stop offset="0" stop-color="#FFF7F0"/><stop offset="1" stop-color="#F7DCC8"/></linearGradient>')
side = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 164 314"><defs>{GRADIENT}</defs>'
        f'<rect width="164" height="314" fill="url(#bg)"/>'
        f'<g transform="translate(22 72) scale(0.5)">{MARK}</g>'
        f'<text x="82" y="226" text-anchor="middle" font-family="Helvetica Neue, Arial, sans-serif" '
        f'font-size="22" font-weight="700" fill="#A8461F">Squirrel</text></svg>')
corner = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 55 55"><rect width="55" height="55" fill="#FFFFFF"/>'
          f'<g transform="translate(1.5 1.5) scale(0.2167)">{MARK}</g></svg>')
packaging = os.path.join(REPO, 'desktop', 'windows', 'packaging')
for svg, (w, h), name in [(side, (164, 314), 'wizard'), (corner, (55, 55), 'wizard-small')]:
    for scale, suffix in [(1, ''), (2, '-2x')]:
        image = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=w * scale,
                                                       output_height=h * scale))).convert('RGB')
        image.save(os.path.join(packaging, f'{name}{suffix}.bmp'))

# Sanity check that Android's copy of the mark still matches
android = open(os.path.join(REPO, 'android', 'app', 'src', 'main', 'res', 'drawable', 'ic_launcher_foreground.xml')).read()
for d in re.findall(r' d="([^"]+)"', open(os.path.join(HERE, 'mark.svg')).read()):
    if d not in android:
        print('WARNING: ic_launcher_foreground.xml is out of date with mark.svg')
        break
