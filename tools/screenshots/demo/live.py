"""live.py <content.json> <raw dir> <library dir> <out dir> <base url> [--guide-only]: fictional Live TV.

Channel logos, an M3U, an XMLTV guide and a 30 s looping clip per channel (slow push-in on the art, the
channel bug, a ticker on news and sports); serve.sh streams the clips as live HLS. Guide times are relative
to now, so rerun with --guide-only right before shooting.
"""
import datetime, hashlib, json, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

C, RAW, LIB, OUT, BASE = json.load(open(sys.argv[1])), *sys.argv[2:6]
GUIDE_ONLY = "--guide-only" in sys.argv
BOLD, SEMI = "/Library/Fonts/SF-Pro-Display-Heavy.otf", "/Library/Fonts/SF-Pro-Display-Semibold.otf"
COLORS = {"News": "#c62828", "Sports": "#1565c0", "Documentary": "#2e7d32", "Cooking": "#ef6c00", "Travel": "#00838f",
          "Talk": "#6a1b9a", "Movie": "#37474f", "Kids": "#f9a825", "Comedy": "#d81b60"}
TICKER = {"Premier Football Live": "HARBOR CITY 2  NORTHGATE 1   67'", "Hoops Tonight": "BAY CITY 88  LAKESHORE 84   Q4 3:12"}
DESC = {
    "Meridian Morning": "The day's top stories, weather and traffic, live from the Meridian newsroom.",
    "World Report": "Correspondents around the globe on the stories shaping the week.",
    "Premier Football Live": "Harbor City and Northgate meet under the lights with the title race on the line.",
    "Hoops Tonight": "Bay City hosts Lakeshore in a rematch of last spring's semifinal.",
    "Coastal Open, Round 3": "Moving day on the cliffs, with the leaders three shots apart.",
    "Into the Highlands": "A year with the snow leopards of the high mountains.",
    "Ocean Giants": "Following humpback whales on their longest migration.",
    "Fire and Salt": "Simple dishes cooked over open flame, start to finish in thirty minutes.",
    "Coastal Villages": "Cliffside towns, harbor markets and the best seafood on the coast.",
    "The Late Hour": "Comedy, conversation and music to close out the night.",
}
art = {}
for ch in C["live"]:
    # The golf channel's first render carries model-drawn lettering, so it airs second.
    first, second = (2, 1) if ch["number"] == 203 else (1, 2)
    art[ch["program"]] = f"{RAW}/live-{ch['number']}-{first}.png"
    art[ch["program"] + " (Encore)"] = f"{RAW}/live-{ch['number']}-{second}.png"
for m in C["movies"]:
    art[m["title"]] = f"{LIB}/movies/{m['title']} ({m['year']})/fanart.jpg"
    DESC[m["title"]] = m["summary"]
for s in C["shows"]:
    art[s["title"]] = f"{LIB}/tv/{s['title']} ({s['year']})/fanart.jpg"
    DESC[s["title"]] = s["summary"]

CHANNELS = [(c["number"], c["channel"], c["genre"], [c["program"], c["program"] + " (Encore)", c["program"]]) for c in C["live"]] + [
    (601, "Cinema One", "Movie", ["Neon Meridian", "Atlas Drift", "Cold Harbor Line"]),
    (602, "Cinema Classics", "Movie", ["The Saltwater Hours", "The Last Orchard", "Emberfall"]),
    (603, "Family Plus", "Kids", ["Paper Kites", "Moss & Pebble", "Wild Signal"]),
    (604, "Laugh Track", "Comedy", ["The Night Shift Diner", "The Night Shift Diner", "The Late Hour"]),
]
art_name = lambda p: f"art-{hashlib.md5(p.encode()).hexdigest()[:10]}.jpg"
os.makedirs(OUT, exist_ok=True)


def logo(num, name, genre):
    font = ImageFont.truetype(BOLD, 64)
    w = int(font.getlength(name)) + 64
    img = Image.new("RGBA", (w, 110), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, w - 1, 109), 22, fill=COLORS[genre])
    d.text((w / 2, 55), name, font=font, fill="white", anchor="mm")
    img.save(f"{OUT}/logo-{num}.png")


def clip(num, genre, src, program):
    path = f"{OUT}/clip-{num}.mp4"
    if os.path.exists(path):
        return
    bug = Image.open(f"{OUT}/logo-{num}.png")
    bug.thumbnail((260, 60))
    overlay = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
    overlay.alpha_composite(bug, (1920 - bug.width - 70, 60))
    if genre in ("News", "Sports"):
        d = ImageDraw.Draw(overlay)
        d.rectangle((0, 900, 1920, 980), fill=(10, 20, 40, 215))
        d.rectangle((0, 900, 240, 980), fill=COLORS[genre])
        d.text((120, 940), "LIVE", font=ImageFont.truetype(BOLD, 40), fill="white", anchor="mm")
        d.text((280, 940), TICKER.get(program, "WEATHER: SUNNY, HIGH OF 72 ACROSS THE COAST TODAY"),
               font=ImageFont.truetype(SEMI, 40), fill="white", anchor="lm")
    Image.open(src).convert("RGB").resize((1920, 1080)).save(f"{OUT}/_frame.png")
    overlay.save(f"{OUT}/_overlay.png")
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-loop", "1", "-i", f"{OUT}/_frame.png",
                    "-i", f"{OUT}/_overlay.png", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-filter_complex",
                    "[0]scale=3840:2160,zoompan=z='1+0.0004*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=900:s=1280x720:fps=30[v];"
                    "[1]scale=1280:720[o];[v][o]overlay,format=yuv420p",
                    "-t", "30", "-c:v", "libx264", "-preset", "veryfast", "-b:v", "2500k", "-g", "60", "-keyint_min", "60",
                    "-sc_threshold", "0", "-c:a", "aac", "-b:a", "64k", "-shortest", path], check=True)


for num, name, genre, progs in CHANNELS:
    if not GUIDE_ONLY:
        logo(num, name, genre)
        clip(num, genre, art[progs[0]], progs[0])
    for p in set(progs):
        if not os.path.exists(f"{OUT}/{art_name(p)}"):
            Image.open(art[p]).convert("RGB").resize((1280, 720)).save(f"{OUT}/{art_name(p)}", quality=88)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
fmt = lambda t: t.strftime("%Y%m%d%H%M%S +0000")
m3u, xml = ["#EXTM3U"], ['<?xml version="1.0" encoding="UTF-8"?>', "<tv>"]
for i, (num, name, genre, progs) in enumerate(CHANNELS):
    cid = f"demo{num}"
    m3u += [f'#EXTINF:-1 tvg-id="{cid}" tvg-chno="{num}" tvg-logo="{BASE}/logo-{num}.png" group-title="{genre}",{name}',
            f"{BASE}/live-{num}/index.m3u8"]
    xml.append(f'<channel id="{cid}"><display-name>{esc(name)}</display-name><icon src="{BASE}/logo-{num}.png"/></channel>')
    start = now - datetime.timedelta(minutes=12 + (i * 9) % 40)
    for p, length in zip(progs, (60 + (i % 3) * 30, 60, 90)):
        stop = start + datetime.timedelta(minutes=length)
        title = p.replace(" (Encore)", "")
        xml.append(f'<programme channel="{cid}" start="{fmt(start)}" stop="{fmt(stop)}"><title>{esc(title)}</title>'
                   f'<desc>{esc(DESC.get(title, ""))}</desc><category>{genre}</category>'
                   f'<icon src="{BASE}/{art_name(p)}" width="1280" height="720"/></programme>')
        start = stop
xml.append("</tv>")
open(f"{OUT}/demo.m3u", "w").write("\n".join(m3u) + "\n")
open(f"{OUT}/guide.xml", "w").write("\n".join(xml) + "\n")
print(f"{OUT}: {len(CHANNELS)} channels")
