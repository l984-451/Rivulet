"""creative.py <preview shots dir> <icon png> <out dir>: App Store Creative Assets (header, search results, universal).

Preview shots are full-screen iPad captures of each pattern in Preview; tiles are square crops from inside each chart.
"""
import glob, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS, ICON, OUT = sys.argv[1:4]
SIZES = {"universal": (5244, 2950), "header": (3840, 1646), "search": (3840, 2560)}
BG = "#F4EEE3"
FONT = "/Library/Fonts/SF-Pro-Display-Bold.otf"
FONT_TEXT = "/Library/Fonts/SF-Pro-Display-Medium.otf"


def tile(path, size):
    """The largest square inside the chart (non-background pixels, controls skipped), centered."""
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(int)
    h = a.shape[0]
    band = a[420:h - 320]
    diff = np.abs(band - band[2, 2]).sum(2) > 30
    rows = np.where(diff.mean(1) > 0.3)[0] + 420
    cols = np.where(diff.mean(0) > 0.3)[0]
    x0, x1, y0, y1 = cols.min(), cols.max(), rows.min(), rows.max()
    side = int(min(x1 - x0, y1 - y0) * 0.92)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    return im.crop((cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2)).resize((size, size), Image.LANCZOS)


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), radius, fill=255)
    return mask


def make(name, W, H, shots, icon):
    canvas = Image.new("RGB", (W, H), BG)
    t = int(H * 0.30)
    gap = int(t * 0.12)
    cols, rows = W // (t + gap) + 3, H // (t + gap) + 3
    shadow = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shadow)
    tiles = []
    k = 0
    for r in range(rows):
        for c in range(cols):
            x = (c - 1) * (t + gap) + (r % 2) * (t + gap) // 2 - gap
            y = (r - 1) * (t + gap) + int(H * 0.04)
            tiles.append((x, y, shots[k % len(shots)]))
            sd.rounded_rectangle((x, y + 18, x + t, y + t + 18), int(t * 0.08), fill=70)
            k += 3
    canvas.paste(Image.new("RGB", (W, H), "#3A2A20"), (0, 0), shadow.filter(ImageFilter.GaussianBlur(int(t * 0.06))))
    cache = {}
    for x, y, p in tiles:
        if p not in cache:
            cache[p] = tile(p, t)
        canvas.paste(cache[p], (x, y), rounded(cache[p], int(t * 0.08)))
    # Center card: icon, name, tagline. Kept inside the middle of the canvas, the safe area every placement keeps.
    title = ImageFont.truetype(FONT, int(H * 0.085))
    tag = ImageFont.truetype(FONT_TEXT, int(H * 0.042))
    d = ImageDraw.Draw(canvas)
    tb = d.textbbox((0, 0), "Meshmerize", font=title)
    gb = d.textbbox((0, 0), "Design needlepoint, stitch by stitch", font=tag)
    isz = int(H * 0.16)
    cw = max(tb[2], gb[2]) + int(H * 0.16)
    ch = isz + (tb[3] - tb[1]) + (gb[3] - gb[1]) + int(H * 0.17)
    cx, cy = (W - cw) // 2, (H - ch) // 2
    cs = Image.new("L", (W, H), 0)
    ImageDraw.Draw(cs).rounded_rectangle((cx, cy + 24, cx + cw, cy + ch + 24), int(H * 0.05), fill=120)
    canvas.paste(Image.new("RGB", (W, H), "#2A1E18"), (0, 0), cs.filter(ImageFilter.GaussianBlur(int(H * 0.03))))
    d.rounded_rectangle((cx, cy, cx + cw, cy + ch), int(H * 0.05), fill=BG)
    ic = icon.resize((isz, isz), Image.LANCZOS)
    y = cy + int(H * 0.05)
    canvas.paste(ic, ((W - isz) // 2, y), rounded(ic, int(isz * 0.225)))
    y += isz + int(H * 0.035)
    d.text(((W - tb[2]) // 2, y - tb[1]), "Meshmerize", font=title, fill="#2A2230")
    y += tb[3] - tb[1] + int(H * 0.03)
    d.text(((W - gb[2]) // 2, y - gb[1]), "Design needlepoint, stitch by stitch", font=tag, fill="#6B5E57")
    canvas.save(f"{OUT}/{name}-{W}x{H}.png")


os.makedirs(OUT, exist_ok=True)
shots = sorted(glob.glob(f"{SHOTS}/*.png"))
icon = Image.open(ICON).convert("RGB")
for name, (W, H) in SIZES.items():
    make(name, W, H, shots, icon)
print("ok")
