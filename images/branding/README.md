# OneClick icon

The woodpecker is a soft, oversized portrait inspired by the quiet.md app's warm
porcelain background, rounded animal silhouette and minimal dot eyes. A muted
terracotta crest, rounded warm-gray beak and ivory cheek keep OneClick's own
identity. Gentle vector gradients give the portrait depth without outlines,
embedded bitmaps or decorative highlights. The breast runs off the bottom edge.

- `oneclick-mark.svg`: editable source of the transparent color mark.
- `oneclick-app-icon.svg`: generated close-up, clipped to an ivory rounded square.
- `oneclick-mark-mono.svg`: independently editable 22 pt menu bar mark.
- `preview.png`: generated 512 px app icon preview.
- `menu-bar-preview.png`: generated light/dark menu mark at 1×, 2× and 3×.

Palette: charcoal `#343330`, terracotta `#CA8175`, warm gray `#B9B4AB`,
ivory `#E3DFD7`, porcelain `#F6F3EE`.

After editing `oneclick-mark.svg`, regenerate the assets from the repository root:

```sh
python3 -m venv .build/icon-tools
.build/icon-tools/bin/pip install cairosvg pillow
.build/icon-tools/bin/python scripts/generate-icons.py
```

CairoSVG also needs Cairo installed on the host (`brew install cairo` on macOS).
The exporter renders each app icon size from SVG and produces vector PDFs for
the settings logo and the adaptive menu bar template. The menu bar has its own
rounded silhouette, shorter crest, broader beak and larger eye, drawn directly
on a tightly cropped canvas displayed at 22 pt. Its enclosed cheek cutout remains legible on light and dark
bars. Edit `oneclick-mark-mono.svg` independently; the exporter preserves it and
regenerates the template PDF and previews.
