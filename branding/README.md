# Squirrel branding

Deliberately quiet: one mark, one colour.

- **Mark:** an acorn, white on the brand colour (`mark.svg`, `icon.svg`). Squirrels stash acorns
  for later; Squirrel stashes videos.
- **Brand colour:** `#B8532A`, with an icon gradient from `#DE7443` to `#A2401D`.
- **Accent in apps:** `#B8532A` in light mode and `#F2976F` in dark mode, as the tint on Apple
  platforms and in the extension. The Android and Windows apps use a Material 3 "fidelity" scheme
  generated from `#B8532A` (`ui/Theme.kt` in each).
- **Warnings** (formats the device can't play) stay orange, `#E8710A`, so they don't read as the accent.

## Regenerating icons

```bash
pip install cairosvg pillow
python3 branding/render_icons.py
```

That writes the iOS, Mac, Windows and extension icons from `icon.svg`. Android's launcher and
notification icons are vector drawables that reuse `mark.svg`'s paths
(`android/app/src/main/res/drawable/ic_launcher_foreground.xml` and `ic_notification.xml`). The
script warns if they drift apart.
