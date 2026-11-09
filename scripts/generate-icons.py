#!/usr/bin/env python3
"""Export OneClick's SVG mark to the macOS asset catalog.

Requires CairoSVG and Pillow: python3 -m pip install cairosvg pillow
Run from any directory: python3 scripts/generate-icons.py
"""

import copy
import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "images/branding"
ASSETS = ROOT / "OneClick/Assets.xcassets"
NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", NS)


def svg_bytes(element):
    return ET.tostring(element, encoding="utf-8", xml_declaration=True)


def write_manifest(directory, images, **properties):
    manifest = {"images": images, "info": {"author": "xcode", "version": 1}}
    if properties:
        manifest["properties"] = properties
    (directory / "Contents.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    mark = ET.parse(BRANDING / "oneclick-mark.svg").getroot()
    app = ET.Element(f"{{{NS}}}svg", {
        "width": "1024", "height": "1024", "viewBox": "0 0 256 256", "fill": "none",
    })
    ET.SubElement(app, f"{{{NS}}}title").text = "OneClick app icon"
    ET.SubElement(app, f"{{{NS}}}desc").text = "A soft woodpecker portrait on a warm porcelain tile."
    tile = {
        "x": "25", "y": "25", "width": "206", "height": "206",
        "rx": "46",
    }
    defs = ET.SubElement(app, f"{{{NS}}}defs")
    for definition in mark.find(f"{{{NS}}}defs"):
        defs.append(copy.deepcopy(definition))
    background = ET.SubElement(defs, f"{{{NS}}}linearGradient", {
        "id": "porcelain", "x1": "51", "y1": "25", "x2": "204", "y2": "231",
        "gradientUnits": "userSpaceOnUse",
    })
    ET.SubElement(background, f"{{{NS}}}stop", {"stop-color": "#F6F3EE"})
    ET.SubElement(background, f"{{{NS}}}stop", {"offset": "1", "stop-color": "#ECE8E1"})
    clip = ET.SubElement(defs, f"{{{NS}}}clipPath", {"id": "tile"})
    ET.SubElement(clip, f"{{{NS}}}rect", tile)
    ET.SubElement(app, f"{{{NS}}}rect", {**tile, "fill": "url(#porcelain)"})
    portrait = ET.SubElement(app, f"{{{NS}}}g", {"clip-path": "url(#tile)"})
    for element in mark:
        if element.tag in (f"{{{NS}}}path", f"{{{NS}}}circle"):
            portrait.append(copy.deepcopy(element))
    app_svg = svg_bytes(app)
    (BRANDING / "oneclick-app-icon.svg").write_bytes(app_svg)

    # Export each declared slot directly from the vector source, including 16 px.
    app_dir = ASSETS / "AppIcon.appiconset"
    entries = json.loads((app_dir / "Contents.json").read_text())["images"]
    for entry in entries:
        pixels = int(entry["size"].split("x")[0]) * int(entry["scale"][:-1])
        cairosvg.svg2png(bytestring=app_svg, write_to=str(app_dir / entry["filename"]),
                        output_width=pixels, output_height=pixels)

    # PDFs retain vector geometry in the settings logo and menu bar.
    logo_dir = ASSETS / "Logo.imageset"
    cairosvg.svg2pdf(bytestring=app_svg, write_to=str(logo_dir / "OneClick.pdf"))
    write_manifest(logo_dir, [{"filename": "OneClick.pdf", "idiom": "universal"}],
                   **{"preserves-vector-representation": True})

    # The menu mark has its own 18 pt geometry, rather than a reduced app portrait.
    mono_svg = (BRANDING / "oneclick-mark-mono.svg").read_bytes()
    menu_dir = ASSETS / "MenuBar.imageset"
    cairosvg.svg2pdf(bytestring=mono_svg, write_to=str(menu_dir / "OneClick.pdf"))
    write_manifest(menu_dir, [{"filename": "OneClick.pdf", "idiom": "mac"}],
                   **{"preserves-vector-representation": True,
                      "template-rendering-intent": "template"})

    # A transparent PNG preview is convenient outside SVG-aware design tools.
    cairosvg.svg2png(bytestring=app_svg, write_to=str(BRANDING / "preview.png"),
                    output_width=512, output_height=512)
    preview = Image.new("RGB", (720, 160), "#E8E8E8")
    for x, size in zip((24, 180, 270, 336, 382), (128, 64, 32, 24, 16)):
        png = cairosvg.svg2png(bytestring=app_svg, output_width=size, output_height=size)
        icon = Image.open(io.BytesIO(png))
        preview.paste(icon, (x, (160 - size) // 2), icon)
    for x, background, foreground in ((468, "#F6F3EE", "#343330"),
                                       (588, "#343330", "#FFFFFF")):
        preview.paste(background, (x, 24, x + 104, 136))
        png = cairosvg.svg2png(bytestring=mono_svg, output_width=36, output_height=36)
        alpha = Image.open(io.BytesIO(png)).getchannel("A")
        preview.paste(foreground, (x + 34, 62, x + 70, 98), alpha)
    (ROOT / ".build").mkdir(exist_ok=True)
    preview.save(ROOT / ".build/oneclick-icon-sizes.png")
    menu_preview = Image.new("RGB", (480, 112), "#F5F5F5")
    menu_preview.paste("#282828", (240, 0, 480, 112))
    for origin, foreground in ((0, "#222222"), (240, "#FFFFFF")):
        for center, size in ((40, 18), (112, 36), (192, 54)):
            png = cairosvg.svg2png(bytestring=mono_svg, output_width=size, output_height=size)
            alpha = Image.open(io.BytesIO(png)).getchannel("A")
            menu_preview.paste(foreground,
                               (origin + center - size // 2, (112 - size) // 2), alpha)
    menu_preview.save(BRANDING / "menu-bar-preview.png")
    print("Exported app icons, vector PDFs, SVGs and previews.")


if __name__ == "__main__":
    main()
