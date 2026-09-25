"""Render every app icon from branding/icon.svg and branding/mark.svg.

    pip install cairosvg pillow
    python3 branding/render_icons.py

The Android icon is a vector drawable that reuses mark.svg's paths directly
(android/app/src/main/res/drawable/ic_launcher_foreground.xml), so update both
if the mark changes.
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
    """The square icon clipped to a rounded square, `inset` px in from each edge (1024 grid)."""
    size = 1024 - 2 * inset
    scale = size / 1024
    body = svg.split('>', 1)[1].rsplit('</svg>', 1)[0]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
            f'<defs><clipPath id="r"><rect x="{inset}" y="{inset}" width="{size}" height="{size}" rx="{radius}"/></clipPath></defs>'
            f'<g clip-path="url(#r)"><g transform="translate({inset} {inset}) scale({scale})">{body}</g></g></svg>')


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

# Sanity check that Android's copy of the mark still matches
android = open(os.path.join(REPO, 'android', 'app', 'src', 'main', 'res', 'drawable', 'ic_launcher_foreground.xml')).read()
for d in re.findall(r' d="([^"]+)"', open(os.path.join(HERE, 'mark.svg')).read()):
    if d not in android:
        print('WARNING: ic_launcher_foreground.xml is out of date with mark.svg')
        break
