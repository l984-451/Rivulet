#!/usr/bin/env python3
"""Builds the macOS icons (824pt body on a 1024 canvas, shadow) from the iOS full-bleed art. Run from the repo root."""
from PIL import Image, ImageDraw, ImageFilter

S, BODY, R = 1024, 824, 185
IOS = "RivuletiOS/Assets.xcassets/"
MAC = "RivuletMac/Assets.xcassets/"


def mac(src):
    k = 4  # supersampled mask for clean edges
    mask = Image.new("L", (BODY * k, BODY * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, BODY * k - 1, BODY * k - 1), R * k, fill=255)
    mask = mask.resize((BODY, BODY), Image.LANCZOS)
    off = (S - BODY) // 2
    shadow_a = Image.new("L", (S, S), 0)
    shadow_a.paste(mask.point(lambda v: int(v * 0.4)), (off, off + 10))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(shadow_a.filter(ImageFilter.GaussianBlur(12)))
    out = Image.alpha_composite(out, shadow)
    body = Image.open(src).convert("RGB").resize((BODY, BODY), Image.LANCZOS).convert("RGBA")
    body.putalpha(mask)
    out.alpha_composite(body, (off, off))
    return out


for name in ("AppIconSimpleColor", "AppIconSimpleWhite", "AppIconPixel"):
    mac(f"{IOS}{name}.appiconset/icon-1024.png").save(f"{MAC}{name}.imageset/icon-1024.png")

master = mac(f"{IOS}AppIcon.appiconset/Rivulet-iOS-1024.png")
for px in (16, 32, 64, 128, 256, 512, 1024):
    img = master.resize((px, px), Image.LANCZOS)
    for pt, scale in ((px, 1), (px // 2, 2)):
        if pt in (16, 32, 128, 256, 512):
            img.save(f"{MAC}AppIcon.appiconset/icon_{pt}x{pt}@{scale}x.png")
