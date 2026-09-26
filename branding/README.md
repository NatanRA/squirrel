# Squirrel branding

One mascot, one colour.

- **Mark:** a chestnut squirrel sitting up with its eyes shut in a smile, holding an acorn,
  on a warm cream background. Squirrels stash acorns for later; Squirrel stashes videos.
  `squirrel.py` is the only place its shapes live.
- **Launch animation:** each app opens with the squirrel hopping up, fluffing out its tail,
  tilting its head and giving a little hop of joy (about a second; tap or click to skip, and
  Reduce Motion shows it still). `LaunchSplash.swift` (iOS, Mac) and `LaunchSplash.kt` (Android,
  Windows) draw it from the generated `SquirrelArt` files with the same timeline.
- **Squirrel colours:** fur `#C0582C`, belly `#FFE2CC`, acorn `#8A3515` and `#4E1C0A`. Icon
  background: a gradient from `#FFF7F0` to `#F7DCC8`. Launch background: `#FFF7F0`, or
  `#1E1712` in dark mode.
- **Brand colour:** `#B8532A`.
- **Accent in apps:** `#B8532A` in light mode and `#F2976F` in dark mode, as the tint on Apple
  platforms and in the extension. The Android and Windows apps use a Material 3 "fidelity" scheme
  generated from `#B8532A` (`ui/Theme.kt` in each).
- **Warnings** (formats the device can't play) stay orange, `#E8710A`, so they don't read as the accent.

## Regenerating icons

```bash
pip install cairosvg pillow
python3 branding/squirrel.py && python3 branding/render_icons.py
```

`squirrel.py` writes `icon.svg`, `mark.svg`, Android's launcher, themed-icon and notification
drawables, and the `SquirrelArt` shape files for the launch animation. `render_icons.py` then
writes the iOS, Mac, Windows and extension icons from `icon.svg`.
