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

# Windows installer artwork (WiX's WixUIDialogBmp and WixUIBannerBmp; see desktop/windows/packaging).
# The installer draws its text over the white parts, so the squirrel stays on the left panel and
# the banner's right end.
MARK = open(os.path.join(HERE, 'mark.svg')).read().split('>', 1)[1].rsplit('</svg>', 1)[0]
GRADIENT = ('<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
            '<stop offset="0" stop-color="#FFF7F0"/><stop offset="1" stop-color="#F7DCC8"/></linearGradient>')


def bitmap(svg, width, height):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(), output_width=width,
                                                  output_height=height))).convert('RGB')


dialog = (f'<svg xmlns="http://www.w3.org/2000/svg" width="493" height="312" viewBox="0 0 493 312">'
          f'<defs>{GRADIENT}</defs><rect width="493" height="312" fill="#FFFFFF"/>'
          f'<rect width="164" height="312" fill="url(#bg)"/><rect x="163" width="1" height="312" fill="#E4C4AE"/>'
          f'<g transform="translate(22 66) scale(0.5)">{MARK}</g>'
          f'<text x="82" y="222" text-anchor="middle" font-family="Helvetica Neue, Arial, sans-serif" '
          f'font-size="22" font-weight="700" fill="#A8461F">Squirrel</text></svg>')
banner = (f'<svg xmlns="http://www.w3.org/2000/svg" width="493" height="58" viewBox="0 0 493 58">'
          f'<defs>{GRADIENT}</defs><rect width="493" height="58" fill="#FFFFFF"/>'
          f'<rect x="435" width="58" height="58" fill="url(#bg)"/><rect x="435" width="1" height="58" fill="#E4C4AE"/>'
          f'<g transform="translate(439 4) scale(0.2083)">{MARK}</g></svg>')
packaging = os.path.join(REPO, 'desktop', 'windows', 'packaging')
os.makedirs(packaging, exist_ok=True)
bitmap(dialog, 493, 312).save(os.path.join(packaging, 'dialog.bmp'))
bitmap(banner, 493, 58).save(os.path.join(packaging, 'banner.bmp'))

# Sanity check that Android's copy of the mark still matches
android = open(os.path.join(REPO, 'android', 'app', 'src', 'main', 'res', 'drawable', 'ic_launcher_foreground.xml')).read()
for d in re.findall(r' d="([^"]+)"', open(os.path.join(HERE, 'mark.svg')).read()):
    if d not in android:
        print('WARNING: ic_launcher_foreground.xml is out of date with mark.svg')
        break
