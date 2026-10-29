#!/bin/bash
# Runs on the Mac: builds scripts/model-check with xcodebuild and runs it against ~/hermit/models,
# holding the shared build lock the whole time.
L=~/hermit/.buildlock
until mkdir "$L" 2>/dev/null; do sleep 5; done
trap 'rmdir "$L"' EXIT
cd ~/hermit/wt/${1:-model}/scripts/model-check || exit 1
xcodebuild -scheme model-check -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath ~/hermit/dd-model-check build 2>&1 | grep -E "error:|BUILD" | tail -30
~/hermit/dd-model-check/Build/Products/Release/model-check ~/hermit/models ${2:-}
