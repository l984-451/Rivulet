"""build.py <content.json> <raw dir> <library dir> [cast-thumbs.json]: the demo Plex libraries on disk.

Writes movies/, tv/, music/ and cast/ under <library dir>: Kodi-style NFOs, posters with set titles, clear
logos, and placeholder video (the backdrop as a still, 2 fps with a keyframe every 10 s; a longer GOP plays
black). Plex reads it with the NFO agents. Plex's photo transcoder refuses LAN image URLs, so cast headshots
live in their own photo library; pass its {file name: thumb path} map to point the NFOs at it.
"""
import json, os, random, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

C, RAW, LIB = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
THUMBS = json.load(open(sys.argv[4])) if len(sys.argv) > 4 else {}
rnd = random.Random(7)
ROLES = ["Wren", "Callum", "Nora", "Eli", "Marguerite", "Hollis", "June", "Abel", "Tess", "Rafe"]
esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;")


def raw(name, seed):
    return Image.open(f"{RAW}/{name}-{seed}.png").convert("RGB")


def text_image(m, size, fill=(255, 255, 255, 255)):
    """The title in its font with tracking; a leading "The" sits small and spaced above."""
    if m["title"].startswith("The "):
        small = text_image({**m, "title": "THE", "upper": True, "tracking": 0.5}, size * 0.32, fill)
        main = text_image({**m, "title": m["title"][4:]}, size, fill)
        gap = int(size * 0.12)
        img = Image.new("RGBA", (max(small.width, main.width), small.height + gap + main.height), (0, 0, 0, 0))
        img.alpha_composite(small, ((img.width - small.width) // 2, 0))
        img.alpha_composite(main, ((img.width - main.width) // 2, small.height + gap))
        return img
    font = ImageFont.truetype(m["font"], int(size), index=m.get("fontIndex", 0))
    text = m["title"].upper() if m.get("upper") else m["title"]
    track = size * m.get("tracking", 0)
    width = sum(font.getlength(c) for c in text) + track * (len(text) - 1)
    asc, desc = font.getmetrics()
    img = Image.new("RGBA", (int(width) + 8, asc + desc), (0, 0, 0, 0))
    x = 4
    for c in text:
        ImageDraw.Draw(img).text((x, 0), c, font=font, fill=fill)
        x += font.getlength(c) + track
    return img.crop(img.getbbox())


def with_shadow(img, radius, alpha):
    pad = radius * 3
    canvas = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    shadow = Image.new("RGBA", img.size, (0, 0, 0, alpha))
    shadow.putalpha(img.getchannel("A").point(lambda a: a * alpha // 255))
    canvas.paste(shadow, (pad, pad + radius // 3), shadow)
    canvas = canvas.filter(ImageFilter.GaussianBlur(radius))
    canvas.alpha_composite(img, (pad, pad))
    return canvas


def artwork(m, kind, d, tagline=None):
    """fanart.jpg, clearlogo.png and a titled poster.jpg for a movie or show."""
    raw(f"{kind}-{m['slug']}-backdrop", m["seeds"]["backdrop"]).crop((0, 4, 1920, 1084)).save(f"{d}/fanart.jpg", quality=92)
    logo = text_image(m, 220)
    logo.thumbnail((1400, 520))
    with_shadow(logo, 10, 110).save(f"{d}/clearlogo.png")
    poster = raw(f"{kind}-{m['slug']}-poster", m["seeds"]["poster"]).convert("RGBA")
    # Fades the bottom to black under the title, which also hides any lettering the model drew there.
    shade = Image.new("L", (1, 256))
    shade.putdata([min(255, max(0, int((y - 140) * 3.4))) for y in range(256)])
    poster.alpha_composite(Image.merge("RGBA", (Image.new("L", poster.size, 0),) * 3 + (shade.resize(poster.size),)))
    title = text_image(m, 160)
    title.thumbnail((int(poster.width * 0.84), 300))
    title = with_shadow(title, 8, 120)
    poster.alpha_composite(title, ((poster.width - title.width) // 2, poster.height - title.height - 90))
    if tagline:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Futura.ttc", 30)
        ImageDraw.Draw(poster).text((poster.width / 2, 70), tagline.upper(), font=font, fill=(255, 255, 255, 220), anchor="mm")
    poster.convert("RGB").save(f"{d}/poster.jpg", quality=92)


def still_video(img, minutes, path):
    if os.path.exists(path):
        return
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-loop", "1", "-framerate", "2", "-i", img,
                    "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", str(minutes * 60), "-vf", "scale=1280:720",
                    "-c:v", "libx264", "-preset", "veryfast", "-tune", "stillimage", "-crf", "30", "-g", "20",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "16k", path + ".tmp.mkv"], check=True)
    os.replace(path + ".tmp.mkv", path)


os.makedirs(f"{LIB}/cast", exist_ok=True)
cast_url = {}
for i, a in enumerate(C["actors"]):
    f = a["name"].lower().replace(" ", "-")
    raw(f"actor-{i}", a["seed"]).resize((400, 400)).save(f"{LIB}/cast/{f}.jpg", quality=90)
    cast_url[a["name"]] = THUMBS.get(f, "")
names = [a["name"] for a in C["actors"]]


def cast_xml(k):
    return "".join(f"<actor><name>{n}</name><role>{r}</role><thumb>{cast_url[n]}</thumb></actor>"
                   for n, r in zip(rnd.sample(names, k), rnd.sample(ROLES, k)))


for m in C["movies"]:
    d = f"{LIB}/movies/{m['title']} ({m['year']})"
    os.makedirs(d, exist_ok=True)
    artwork(m, "movie", d, m["tagline"])
    genres = "".join(f"<genre>{g}</genre>" for g in m["genres"])
    open(f"{d}/movie.nfo", "w").write(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<movie><title>{esc(m["title"])}</title><year>{m["year"]}</year>'
        f'<plot>{esc(m["summary"])}</plot><tagline>{esc(m["tagline"])}</tagline><mpaa>{m["rating"]}</mpaa>'
        f'{genres}<runtime>{m["minutes"]}</runtime><premiered>{m["year"]}-0{3 + len(m["slug"]) % 6}-14</premiered>'
        f'{cast_xml(4)}</movie>\n')
    still_video(f"{d}/fanart.jpg", m["minutes"], f"{d}/{m['title']} ({m['year']}).mkv")

for s in C["shows"]:
    d = f"{LIB}/tv/{s['title']} ({s['year']})"
    os.makedirs(f"{d}/Season 01", exist_ok=True)
    artwork(s, "show", d)
    Image.open(f"{d}/poster.jpg").save(f"{d}/season01-poster.jpg", quality=92)
    genres = "".join(f"<genre>{g}</genre>" for g in s["genres"])
    open(f"{d}/tvshow.nfo", "w").write(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<tvshow><title>{esc(s["title"])}</title><year>{s["year"]}</year>'
        f'<plot>{esc(s["summary"])}</plot><mpaa>{s["rating"]}</mpaa>{genres}<premiered>{s["year"]}-01-09</premiered>'
        f'{cast_xml(4)}</tvshow>\n')
    runtime = 22 if s["genres"][0] in ("Comedy", "Kids") else 48
    for i, ((title, plot, _), seed) in enumerate(zip(s["episodes"], s["seeds"]["episodes"]), 1):
        base = f"{d}/Season 01/{s['title']} ({s['year']}) - S01E{i:02d} - {title}"
        raw(f"show-{s['slug']}-e{i}", seed).crop((0, 4, 1920, 1084)).save(f"{base}-thumb.jpg", quality=90)
        open(f"{base}.nfo", "w").write(
            f'<?xml version="1.0" encoding="UTF-8"?>\n<episodedetails><title>{esc(title)}</title><season>1</season>'
            f'<episode>{i}</episode><plot>{esc(plot)}</plot><aired>{s["year"]}-{1 + i // 4:02d}-{(i * 7) % 28 + 1:02d}</aired>'
            f'<runtime>{runtime}</runtime></episodedetails>\n')
        still_video(f"{base}-thumb.jpg", runtime, f"{base}.mkv")

for a in C["albums"]:
    d = f"{LIB}/music/{a['artist']}/{a['title']}"
    os.makedirs(d, exist_ok=True)
    raw(f"album-{a['slug']}", a["seed"]).save(f"{d}/cover.jpg", quality=92)
    tracks = a.get("tracks") or [f"Track {n}" for n in range(1, 9)]
    for n, t in enumerate(tracks, 1):
        path = f"{d}/{n:02d} {t}.m4a"
        if not os.path.exists(path):
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                            "-t", str(rnd.randint(150, 290)), "-c:a", "aac", "-b:a", "8k",
                            "-metadata", f"title={t}", "-metadata", f"artist={a['artist']}", "-metadata", f"album_artist={a['artist']}",
                            "-metadata", f"album={a['title']}", "-metadata", f"track={n}/{len(tracks)}",
                            "-metadata", f"date={a['year']}", "-metadata", f"genre={a['genre']}", path], check=True)
print(LIB)
