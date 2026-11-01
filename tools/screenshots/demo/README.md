# Demo content for screenshots

Every title, channel, album and person in the README and App Store screenshots is made up, so no shot
shows copyrighted media. `content.json` defines all of it: movies, shows and episodes, Live TV channels,
cast and albums, each with its image prompt and the chosen render seed.

1. **Art**: `render.py content.json <raw dir>` on a CUDA GPU (FLUX.1-schnell, Apache-2.0; needs the
   diffusers package and a Hugging Face token that has accepted the model's terms).
2. **Libraries**: `build.py content.json <raw dir> <library dir> [cast-thumbs.json]` writes Kodi-style
   NFOs, posters with set titles, clear logos and placeholder video. Copy `movies/`, `tv/`, `music/` and
   `cast/` to the Plex server and add them as libraries named `Movies-demo`, `TV Shows-demo` and
   `Music-demo` (agents `tv.plex.agents.nfo.movie`, `tv.plex.agents.nfo.series` and
   `tv.plex.agents.none`), plus a photo library `Cast`. Plex's photo transcoder refuses LAN image URLs,
   so headshots must come from that library: write its `{file name: thumb path}` map to
   `cast-thumbs.json` and rerun `build.py`. Set some resume points (`/:/progress`) for Continue Watching.
3. **Live TV**: `live.py content.json <raw dir> <library dir> <live dir> http://<this Mac>:8765`, then
   `../serve.sh <live dir>`.
4. **Shots**: `PLEX_TOKEN=… ../shoot-tv.sh <tvOS udid> <raw dir>` (README and App Store tvOS) and
   `PLEX_TOKEN=… ../shoot.sh <udid> <out dir>` per iPhone and iPad, then `../caption.py`.

The libraries live on the test server (`PLEX_SERVER`, default `http://192.168.1.140:32410`). Both apps'
DEBUG screenshot modes show only libraries ending in `-demo`.
