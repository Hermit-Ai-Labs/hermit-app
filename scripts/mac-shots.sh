#!/bin/zsh
# Screenshots of every Mac screen from the real app, in ONE background launch that never shows a window or takes focus
# (Debug build; HermitUI/Debug/MacTour.swift parks the window off-screen below the desktop and captures it).
# Run under ~/hermit/.buildlock.
#   zsh scripts/mac-shots.sh [name,name]     default: all. Output: ~/hermit/mac-shots/<name>.png
#   NOBUILD=1 skips the build; DD and OUT override the DerivedData and output folders.
set -uo pipefail
cd "${0:A:h}/.."
DD=${DD:-~/hermit/dd}
OUT=${OUT:-~/hermit/mac-shots}
CONT=~/Library/Containers/my.hermit.mac/Data/tmp/shots
if [[ -z ${NOBUILD:-} ]]; then
  ~/hermit/xg/xcodegen/bin/xcodegen generate -q
  xcodebuild -project Hermit.xcodeproj -scheme Hermit -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DD" build 2>&1 | grep -E "error:|BUILD" | sort -u | tail -8
fi
APP="$DD/Build/Products/Debug/Hermit.app"
[[ -d "$APP" ]] || { echo "Mac build failed"; exit 1; }
# Only a real Mac Hermit counts (Contents/MacOS); the iOS simulator's Hermit process (under CoreSimulator) doesn't.
pgrep -f "Hermit.app/Contents/MacOS/Hermit" >/dev/null && { echo "Hermit is running; not touching it"; exit 1; }
rm -rf "$CONT"; mkdir -p "$OUT"; rm -f "$OUT"/*.png
# -g: don't bring to the front. -j: launch hidden. -W: wait until the tour quits.
# Watchdog: quits the tour if it hangs. Its output goes nowhere so ssh doesn't wait on it.
( sleep 420; pkill -f "Debug/Hermit.app/Contents/MacOS/Hermit" ) >/dev/null 2>&1 </dev/null &!
# ARGS: extra launch arguments, e.g. ARGS="-hermitFresh YES -hermitUser Rahul -hermitTestWallet YES" for store art.
open -g -j -n -W "$APP" --args -hermitTour "${1:-all}" -hermitTourWait ${WAIT:-4} ${=ARGS:-}
pkill -f "sleep 420" 2>/dev/null
cp "$CONT"/*.png "$OUT/" 2>/dev/null; cp "$CONT/tour.log" "$OUT/" 2>/dev/null; tail -5 "$OUT/tour.log" 2>/dev/null
ls "$OUT" | wc -l | xargs echo "shots:"
