#!/bin/zsh
# App Store screenshots: PLEX_TOKEN=… shoot.sh <simulator udid> <out dir>. Needs the Debug iOS app installed.
# Shows only the server's "…-demo" libraries (see RivuletiOS/IOSScreenshotMode.swift). Captions: caption.py.
UDID=$1; OUT=$2; SERVER=${PLEX_SERVER:-http://192.168.1.140:32400}
: ${PLEX_TOKEN:?set PLEX_TOKEN}
mkdir -p $OUT

shot() {
  local name=$1; shift
  xcrun simctl terminate $UDID com.gstudios.rivulet >/dev/null 2>&1
  xcrun simctl launch $UDID com.gstudios.rivulet -screenshotToken $PLEX_TOKEN -screenshotServer $SERVER "$@" >/dev/null
  sleep ${WAIT:-8}
  xcrun simctl io $UDID screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 && echo "$OUT/$name.png"
}

xcrun simctl status_bar $UDID override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
shot 01-home -screenshotTab home
shot 02-movie -screenshotOpen "Sintel"
shot 03-show -screenshotOpen "Pioneer One"
shot 04-library -screenshotOpen "Movies"
shot 05-shows -screenshotOpen "TV Shows"
