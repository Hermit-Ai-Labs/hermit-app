#!/bin/zsh
# Archive the iPhone app and upload it to TestFlight. Runs on the team Mac.
#   zsh scripts/release-ios.sh            bumps the build number, archives, uploads
# Needs an App Store Connect API key (App Manager or Admin) in ~/hermit/asc.env:
#   ASC_KEY_ID=...  ASC_ISSUER_ID=...  ASC_KEY_PATH=~/hermit/AuthKey_<id>.p8
# Signing is automatic: xcodebuild uses the key to create the distribution certificate and profile.
set -euo pipefail
cd "${0:A:h}/.."
source ~/hermit/asc.env
KC=~/hermit/signing.keychain-db
TEAM=4G5YW2XP2B
DD=~/hermit/dd-ios-release
OUT=~/hermit/release/ios
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "${ASC_KEY_PATH/#\~/$HOME}" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

security unlock-keychain -p "$(cat ~/hermit/.kc)" "$KC"
# Upload builds need a fresh build number; a timestamp is always higher than the last one.
BUILD=$(date -u +%Y%m%d%H%M)
~/hermit/xg/xcodegen/bin/xcodegen generate -q
rm -rf "$OUT"; mkdir -p "$OUT"
xcodebuild -project Hermit.xcodeproj -scheme HermitiOS -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" -archivePath "$OUT/Hermit.xcarchive" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" archive | grep -E "error:|warning: .*entitlement|ARCHIVE" || true
[[ -d "$OUT/Hermit.xcarchive" ]] || { echo "Archive failed"; exit 1; }

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Hermit.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT" "${AUTH[@]}"
echo "Uploaded build $BUILD. It shows in TestFlight after Apple processes it (5 to 30 minutes)."
