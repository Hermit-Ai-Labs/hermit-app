#!/bin/bash
# Runs on the Mac: builds scripts/agent-check with xcodebuild (holding the shared build lock), then runs the
# on-device tool loop against a model folder: agent-check <store root> <model id> [prompt ...]
# The store root holds <model id>/ with the model files and a .hermit-ready marker (see agent-check's main.swift).
L=~/hermit/.buildlock
until mkdir "$L" 2>/dev/null; do sleep 5; done
cd ~/hermit/near-app/scripts/agent-check || { rmdir "$L"; exit 1; }
xcodebuild -scheme agent-check -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath ~/hermit/dd-near build 2>&1 | grep -E "error:|BUILD" | tail -30
rmdir "$L"
~/hermit/dd-near/Build/Products/Release/agent-check "$@"
