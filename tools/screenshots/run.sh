#!/bin/zsh
# run.sh <udid> <device folder name>: erase, build Debug, install, shoot into docs/release/screenshots/raw/<name>.
set -e
UDID=$1; NAME=$2; ROOT=${0:A:h}/../..
xcrun simctl shutdown $UDID 2>/dev/null || true
xcrun simctl erase $UDID && xcrun simctl boot $UDID && xcrun simctl bootstatus $UDID >/dev/null
xcodebuild -project $ROOT/Rivulet.xcodeproj -scheme "Rivulet iOS" -configuration Debug -derivedDataPath /tmp/dd-rivulet-shots \
  -destination "id=$UDID" build -quiet
xcrun simctl install $UDID /tmp/dd-rivulet-shots/Build/Products/Debug-iphonesimulator/*.app
${0:A:h}/shoot.sh $UDID "$ROOT/docs/release/screenshots/raw/$NAME"
