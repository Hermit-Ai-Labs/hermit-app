#!/bin/zsh
# Build a development copy and install it on a connected iPhone. Runs on the team Mac.
#   zsh scripts/run-iphone.sh [device-id]     (default: the first connected iPhone)
set -euo pipefail
cd "${0:A:h}/.."
source ~/hermit/asc.env
KC=~/hermit/signing.keychain-db
DD=~/hermit/dd-ios-dev
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "${ASC_KEY_PATH/#\~/$HOME}" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
DEV=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available|connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')}
[[ -n "$DEV" ]] || { echo "No iPhone connected"; exit 1; }
security unlock-keychain -p "$(cat ~/hermit/.kc)" "$KC"
~/hermit/xg/xcodegen/bin/xcodegen generate -q
xcodebuild -project Hermit.xcodeproj -scheme HermitiOS -configuration Release -destination "generic/platform=iOS" \
  -derivedDataPath "$DD" DEVELOPMENT_TEAM=4G5YW2XP2B CODE_SIGN_STYLE=Automatic "${AUTH[@]}" build | grep -E "error:|BUILD" || true
APP="$DD/Build/Products/Release-iphoneos/Hermit.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
xcrun devicectl device install app --device "$DEV" "$APP"
xcrun devicectl device process launch --device "$DEV" my.hermit.ios || echo "Installed. Unlock the iPhone and open Hermit."
