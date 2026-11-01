#!/bin/zsh
# PLEX_TOKEN=… shoot-tv.sh <udid> <raw dir> [shot ...]: tvOS shots for the README and the App Store, from the demo
# libraries (see demo/README.md). Needs the Debug app installed and serve.sh running; writes Screenshots/tvOS
# and Screenshots/AppStore at the end. Shots: home rows detail below sidebar whatson multiview insights music setup.
U=$1; RAW=${2:A}; shift 2; ROOT=${0:A:h}/../..
: ${PLEX_TOKEN:?set PLEX_TOKEN}
SERVER=${PLEX_SERVER:-http://192.168.1.140:32410}; LIVE=http://$(ipconfig getifaddr en0):8765
DETAIL=${DETAIL_KEY:-117} ALBUM=${ALBUM_KEY:-217}
# Every other server on the account stays out of the shots.
HIDE=$(curl -s "https://plex.tv/api/v2/resources?X-Plex-Token=$PLEX_TOKEN&X-Plex-Client-Identifier=rivulet-shots" \
  -H Accept:application/json | python3 -c "import json,sys;print('('+','.join(r['clientIdentifier'] for r in json.load(sys.stdin) if 'server' in r['provides'])+')')")
ARGS=(-screenshotToken $PLEX_TOKEN -screenshotServer $SERVER -screenshotLiveTV $LIVE -plexDisabledServers $HIDE)
mkdir -p $RAW

shot() {  # shot <name> <wait> [ENV=value ...]
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate $U com.gstudios.rivulet >/dev/null 2>&1
  env ${@/#/SIMCTL_CHILD_} xcrun simctl launch $U com.gstudios.rivulet $ARGS >/dev/null
  sleep $wait
  xcrun simctl io $U screenshot --type=png $RAW/$name.png >/dev/null 2>&1 && echo $RAW/$name.png
}
want() { [[ ${#WANT} -eq 0 || ${WANT[(Ie)$1]} -gt 0 ]] }
WANT=($@)

# The hero pages on its own; 28 s lands on The Saltwater Hours.
want home && shot home 28
want rows && shot rows 28 RIVULET_FOCUS_MOVES=down,down RIVULET_FOCUS_DELAY=12
want detail && shot detail 20 RIVULET_OPEN_DETAIL=$DETAIL
want music && shot music 20 RIVULET_OPEN_LIBRARY=Music RIVULET_MUSIC_OPEN=album:$ALBUM
want music && shot musiclibrary 18 RIVULET_OPEN_LIBRARY=Music
want music && shot nowplaying 25 RIVULET_OPEN_LIBRARY=Music RIVULET_MUSIC_OPEN=play:$ALBUM
want whatson && shot whatson 25 RIVULET_OPEN_LIBRARY="Live TV"
want multiview && shot multiview 40 RIVULET_OPEN_LIBRARY="Live TV" RIVULET_MULTIVIEW="Arena Sports,Wild Earth"
# Playback moves the title's resume point; put it back for the next run.
INS=(RIVULET_AUTOPLAY=1 RIVULET_AUTOPLAY_KEY=$DETAIL RIVULET_AUTOPLAY_DURATION=40 RIVULET_AUTOPLAY_CHROME=1
     RIVULET_AUTOPLAY_PANE=insights RIVULET_AUTOPLAY_TRIVIA=${0:A:h}/demo/trivia.json)
want insights && shot insights 18 $INS && shot cast 20 $INS RIVULET_AUTOPLAY_MOVES=right,right
want insights && curl -s -X PUT "$SERVER/:/progress?key=$DETAIL&identifier=com.plexapp.plugins.library&time=4224000&state=stopped&X-Plex-Token=$PLEX_TOKEN"
if want setup; then  # a fresh install with nothing signed in
  APP=$(xcrun simctl get_app_container $U com.gstudios.rivulet app)
  cp -R $APP /tmp/rivulet-shots.app && xcrun simctl uninstall $U com.gstudios.rivulet && xcrun simctl install $U /tmp/rivulet-shots.app
  rm -rf /tmp/rivulet-shots.app
  xcrun simctl launch $U com.gstudios.rivulet >/dev/null; sleep 12
  xcrun simctl io $U screenshot --type=png $RAW/setup.png >/dev/null 2>&1 && echo $RAW/setup.png
fi

python3 - $RAW $ROOT <<'EOF'
import os, sys
from PIL import Image
raw, root = sys.argv[1:3]
readme = {"home": "01-home", "detail": "02-detail", "whatson": "03-whats-on", "multiview": "04-multiview",
          "insights": "05-insights-trivia", "cast": "06-insights-cast", "music": "07-music-album",
          "musiclibrary": "08-music-library", "nowplaying": "09-now-playing"}
store = ["home", "rows", "detail", "whatson", "multiview", "insights", "music", "setup"]
for name, out in readme.items():
    if os.path.exists(f"{raw}/{name}.png"):
        Image.open(f"{raw}/{name}.png").convert("RGB").resize((1920, 1080), Image.LANCZOS).save(f"{root}/Screenshots/tvOS/{out}.jpg", quality=88)
for n, name in enumerate(store, 1):
    if os.path.exists(f"{raw}/{name}.png"):
        Image.open(f"{raw}/{name}.png").convert("RGB").resize((1920, 1080), Image.LANCZOS).save(f"{root}/Screenshots/AppStore/{n:02d}-{name}.png")
EOF
