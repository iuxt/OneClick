# OneClick icon

The woodpecker is a large head portrait with a swept red crest, a long pointed
beak and a diagonal ivory face stripe. The neck and beak are cropped by the app
tile so the bird fills the icon. It has no gradients, shadows or embedded bitmaps.

- `oneclick-mark.svg`: editable source of the transparent color mark.
- `oneclick-app-icon.svg`: generated close-up, clipped to an ivory rounded square.
- `oneclick-mark-mono.svg`: generated transparent menu bar mark.
- `preview.png`: generated 512 px app icon preview.

Palette: deep green `#192D2C`, vermilion `#E84632`, ivory `#F4F0E8`.

After editing `oneclick-mark.svg`, regenerate the assets from the repository root:

```sh
python3 -m venv .build/icon-tools
.build/icon-tools/bin/pip install cairosvg pillow
.build/icon-tools/bin/python scripts/generate-icons.py
```

CairoSVG also needs Cairo installed on the host (`brew install cairo` on macOS).
The exporter renders each app icon size from SVG and produces vector PDFs for
the settings logo and the adaptive menu bar template.
