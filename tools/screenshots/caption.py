"""caption.py <shots dir> <out dir>: headline over a rounded screenshot that bleeds off the bottom, at the shot's size."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS, OUT = sys.argv[1], sys.argv[2]
ORDER = [  # (shot, headline, background)
    ("01-home", "Your library,\nbeautifully at home", "#E3ECF7"),
    ("02-movie", "Every film,\nfront and center", "#F7E3E1"),
    ("03-show", "Pick up right\nwhere you left off", "#E4F2E7"),
    ("04-library", "Browse your whole\ncollection", "#F3EBDD"),
    ("05-shows", "All your shows,\none tap away", "#ECE4F5"),
]
FONT = "/Library/Fonts/SF-Pro-Display-Bold.otf"
os.makedirs(OUT, exist_ok=True)
for n, (name, text, bg) in enumerate(ORDER, 1):
    shot = Image.open(f"{SHOTS}/{name}.png").convert("RGB")
    W, H = shot.size
    phone = W / H < 0.6
    if phone:
        # Dynamic Island: 126 x 37 pt, 11 pt from the top, on a 3x screen.
        iw, ih, top_pt = 126 * 3, 37 * 3, 11 * 3
        ImageDraw.Draw(shot).rounded_rectangle(((W - iw) // 2, top_pt, (W + iw) // 2, top_pt + ih), ih // 2, fill="black")
    canvas = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype(FONT, int(W * 0.085))
    top = int(H * 0.06)
    box = draw.multiline_textbbox((0, 0), text, font=font, spacing=int(W * 0.015), align="center")
    draw.multiline_text(((W - (box[2] - box[0])) / 2, top), text, font=font, fill="#2A2230",
                        spacing=int(W * 0.015), align="center")
    scale = 0.84
    sw, sh = int(W * scale), int(H * scale)
    small = shot.resize((sw, sh), Image.LANCZOS)
    # iPad screens have far smaller corners; a phone radius clips their status bar.
    radius = int(sw * (0.12 if phone else 0.03))
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius, fill=255)
    x, y = (W - sw) // 2, top + (box[3] - box[1]) + int(H * 0.05)
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 12, x + sw, y + sh + 12), radius, fill=90)
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    canvas.paste(Image.new("RGB", (W, H), "#000000"), (0, 0), shadow)
    # Thin bezel.
    bezel = Image.new("L", (sw + 16, sh + 16), 0)
    ImageDraw.Draw(bezel).rounded_rectangle((0, 0, sw + 15, sh + 15), radius + 8, fill=255)
    canvas.paste(Image.new("RGB", (sw + 16, sh + 16), "#1C1C1E"), (x - 8, y - 8), bezel)
    canvas.paste(small, (x, y), mask)
    canvas.save(f"{OUT}/{n:02d}-{name.split('-', 1)[1]}.png")
print("ok")
