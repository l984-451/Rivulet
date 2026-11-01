#!/bin/zsh
# PLEX_TOKEN=… shoot.sh <simulator udid> <out dir>: iOS and iPadOS shots from the demo libraries (see
# demo/README.md). Needs the Debug iOS app installed and serve.sh running. Shows only "…-demo" libraries (see
# RivuletiOS/IOSScreenshotMode.swift). Captions: caption.py.
UDID=$1; OUT=$2; SERVER=${PLEX_SERVER:-http://192.168.1.140:32410}
: ${PLEX_TOKEN:?set PLEX_TOKEN}
LIVE=http://$(ipconfig getifaddr en0):8765
# Every other server on the account stays out of the shots.
HIDE=$(curl -s "https://plex.tv/api/v2/resources?X-Plex-Token=$PLEX_TOKEN&X-Plex-Client-Identifier=rivulet-shots" \
  -H Accept:application/json | python3 -c "import json,sys;print('('+','.join(r['clientIdentifier'] for r in json.load(sys.stdin) if 'server' in r['provides'])+')')")
mkdir -p $OUT

shot() {
  local name=$1; shift
  xcrun simctl terminate $UDID com.gstudios.rivulet >/dev/null 2>&1
  xcrun simctl launch $UDID com.gstudios.rivulet -screenshotToken $PLEX_TOKEN -screenshotServer $SERVER \
    -plexDisabledServers $HIDE "$@" >/dev/null
  sleep ${WAIT:-16}
  xcrun simctl io $UDID screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 && echo "$OUT/$name.png"
}

xcrun simctl status_bar $UDID override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
shot 01-home -screenshotTab home
# Guide times are real, so this one shot shows the real clock.
xcrun simctl status_bar $UDID override --time "$(date +%H:%M)"
shot 06-livetv -screenshotTab live-tv -screenshotLiveTV $LIVE
xcrun simctl status_bar $UDID override --time "9:41"
shot 02-movie -screenshotOpen "Neon Meridian"
shot 03-show -screenshotOpen "Harbor Lights"
shot 04-library -screenshotOpen "Movies"
shot 05-shows -screenshotOpen "TV Shows"
