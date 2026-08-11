<div align="center">

<img src="Branding/logo_glow_transparent.png" alt="Rivulet" width="220">

# Rivulet

**A native tvOS video app for Plex and Live TV.**
Built for simplicity.

<a href="https://apps.apple.com/us/app/rivulet-for-plex/id6756892857">
  <img src="https://img.shields.io/badge/Download_on_the-App_Store-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download on the App Store">
</a>
&nbsp;
<a href="https://testflight.apple.com/join/TcCsF5As">
  <img src="https://img.shields.io/badge/Join_the-TestFlight_Beta-0D96F6?style=for-the-badge&logo=apple&logoColor=white" alt="Join the TestFlight Beta">
</a>

<br><br>

![tvOS 26+](https://img.shields.io/badge/tvOS-26+-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-PolyForm_NC_1.0.0-blue)
![Not for sale](https://img.shields.io/badge/⚠_not_for_sale-Noncommercial_only-red)

</div>

---

<div align="center">

<img src="Screenshots/AppStore/01_home-hero.png" alt="Home" width="100%">

</div>

<div align="center">

<img src="Screenshots/AppStore/02_home-rows.png" alt="Home rows" width="49%">
<img src="Screenshots/AppStore/06_sidebar.png" alt="Sidebar" width="49%">
<img src="Screenshots/AppStore/03_detail-sintel.png" alt="Media detail" width="49%">
<img src="Screenshots/AppStore/04_detail-expanded.png" alt="Expanded detail" width="49%">

</div>

---

## Why this exists

This project has fairly *opinionated* designs and logic, with a few focal points:

- **Simplicity** — What is the best design to get me to the media I want to watch.
- **Live TV** — Plex's live TV is, to put it nicely, sub-par. I've spent too long trying to get it to work well for me (kudos if you don't have this problem). I don't want live TV in a separate app, so this solves my problems. You might could use this just for live tv. Go for it.
- **HomePod Integration** — The Plex app has never worked well when setting HomePod as the default audio output on my Apple TV. It hurts to have a HomePod sitting there collecting dust while my sub-par tv speakers play sound. This app helps the hurt.
- **Direct Play** — No server transcoding. The bar I'm chasing is Infuse. This was frustratingly built because Apple's frameworks can't direct play most video containers, and the third-party players that handle the trickier formats can't use Apple's HomePod controls.
- **Apple TV+ Inspired** — The UI takes heavy inspiration from Apple's own TV app. Clean, focused, and native-feeling.

## Features

### Video Player

Playback runs on [AetherEngine](https://github.com/superuser404notfound/AetherEngine): FFmpeg demuxing, remuxed to HLS-fMP4, handed to Apple's frameworks. Direct play is the primary path. A Plex server transcode is only the fallback when a file has no direct-play URL, or when startup fails.

- **Video** — H.264 and HEVC through VideoToolbox. AV1, VP9, MPEG-2, VC-1, and MPEG-4 Part 2 fall back to software decode.
- **HDR** — HDR10, HDR10+, HLG, and Dolby Vision. DV profiles 5 and 8.1 play with full Dolby Vision. Profile 7 plays as its HDR10 base layer.
- **Audio** — AAC, AC3, E-AC3 (including Atmos / JOC), TrueHD, DTS, DTS-HD MA, FLAC, ALAC, MP3, and PCM.
- **Subtitles** — Text (SRT, ASS/SSA) and bitmap (PGS, DVB).

### Live TV

- Dispatcharr and generic M3U/XMLTV sources
- Plex Live TV
- Channel guide, favorites, and recently watched
- Multi-stream mode: watch several channels at once in a grid, or promote one to focus while the others play muted

Dispatcharr and Plex Live TV are tested regularly. Generic M3U/XMLTV is wired up but less battle-tested. Feedback welcome.

### Discover and Watchlist

Browse trending and upcoming titles, add to your Plex watchlist, and see at a glance what you already own on your server.

### Insights

While something is playing, pull up Insights for cast and trivia on what's on screen. Work in progress, so coverage and accuracy will keep improving.

### Music

- Album, artist, and playlist browsing, modeled on Apple's Music app for tvOS.
- Lyrics display (synced when the source provides timestamps, static otherwise).
- Real-time audio visualizer on the Now Playing screen.
- System Now Playing controls. HomePod, AirPods, Siri Remote, Control Center all work.

Chasing Plexamp on the features side. Long way to go.

---

> [!IMPORTANT]
> ## Rivulet is free, but not for sale.
>
> Licensed under [PolyForm Noncommercial 1.0.0](LICENSE). You may **clone it, run it, modify it, share it, and contribute back** for personal, educational, research, hobby, or any other noncommercial use.
>
> You may **not** sell Rivulet, charge for access to it, or bundle it (or any derivative of it) into a paid app, product, or service. **Anything derived from this code inherits the same restriction.** I'd rather give this away than watch someone else charge for it.

---

## Requirements

- Apple TV running tvOS 26 or later
- Xcode 26+ for building
- Plex Media Server (for Plex features)
- M3U/XMLTV source or Dispatcharr (for Live TV)

## Building

```bash
git clone https://github.com/l984-451/Rivulet.git
cd Rivulet

# One-time: both app targets read Secrets.swift and will not compile without it.
# The placeholder values are fine for a local build.
cp RivuletCore/Config/Secrets.swift.template RivuletCore/Config/Secrets.swift

open Rivulet.xcodeproj

# Or from the command line
xcodebuild -scheme Rivulet -destination 'generic/platform=tvOS' build

# The iOS/iPadOS app has its own scheme
xcodebuild -scheme "Rivulet iOS" -destination 'generic/platform=iOS' build
```

## Repository layout

```
Rivulet/           The tvOS app — all primary surfaces are UIKit
RivuletiOS/        The iOS/iPadOS app (early) — SwiftUI, touch-first
RivuletCore/       Code compiled into both apps: the Plex client and models,
                   auth, IPTV parsers, TMDB, watch-progress policy, security,
                   diagnostics
TopShelfExtension/ Apple TV home-screen Top Shelf
RivuletTests/      Unit tests (run with the Rivulet scheme)
```

Two rules keep the platforms from taxing each other, and both are enforced or
documented in `.swiftlint.yml` and `CLAUDE.md`:

- **One client per service.** Anything that encodes how Plex, TMDB, or an IPTV
  source actually behaves lives in `RivuletCore/`, once. The platform folders
  hold UI and per-platform state only — a bug fixed in shared code is fixed for
  both apps by construction.
- **No `#if os(...)` in shared code** (lint-enforced). Where platforms genuinely
  differ, the app injects the difference at launch instead of branching in the
  shared file.

## Contributing

I welcome all contributions from any level of developer. I welcome contributions from LLMs too as long as they are checked and tested.

**If you do contribute, please build and test on an actual Apple TV. The simulator is close, but does not mimic the Apple TV fully.**

By submitting a pull request, you agree to license your contribution under the same terms as Rivulet (PolyForm Noncommercial 1.0.0, see [LICENSE](LICENSE)).

## License

Rivulet is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

Everything here is free to use, read, fork, and build on. The only thing you can't do is sell it. I'd rather give this away than watch someone else charge for it.

In short: clone it, run it, modify it, share it, contribute back, for personal, educational, research, hobby, or other noncommercial use. You may not use Rivulet (or anything derived from it) for commercial purposes, including selling it, charging for access to it, or bundling it into a paid product or service.

This restriction is not decorative. If you ship Rivulet's code (in whole or in part, modified or not) inside something you sell, you are infringing the copyright in this project. If you spot a commercial app built on this code, please [open an issue](../../issues) so it can be reported to the relevant platform (App Store, GitHub, etc.).

Third-party components retain their original licenses. FFmpeg is included under LGPL-2.1+; libdovi under MIT. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine) — the playback engine
- [FFmpeg](https://ffmpeg.org/) — demuxing, decoding, and remuxing
- [libdovi](https://github.com/quietvoid/dovi_tool) — Dolby Vision RPU handling
- [Plex](https://plex.tv/) — media server platform
- [Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) — IPTV management
- [TMDB](https://www.themoviedb.org/) — artwork and metadata for Discover

---

<div align="center">

Rivulet is not affiliated with or endorsed by Plex, Inc.

</div>
