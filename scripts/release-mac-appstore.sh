#!/bin/zsh
# Archive the Mac app for the Mac App Store and upload it to TestFlight. Runs on the team Mac.
#   zsh scripts/release-mac-appstore.sh      bumps the build number, archives, exports a signed .pkg, uploads
# App Store Connect app: "Hermit - Private AI for Mac" (Apple ID 6831778645, bundle my.hermit.mac).
# Needs ~/hermit/asc.env (App Manager key) and, once, scripts/mac-appstore-signing.sh: the Apple Distribution and
# Mac Installer Distribution certificates in signing.keychain-db and the "Hermit Mac App Store" profile.
# The direct-download build (Developer ID, notarized .dmg) is scripts/release-mac.sh.
set -euo pipefail
cd "${0:A:h}/.."
source ~/hermit/asc.env
KC=~/hermit/signing.keychain-db
TEAM=4G5YW2XP2B
DD=~/hermit/dd-mac-appstore
OUT=~/hermit/release/mac-appstore
PROFILE="Hermit Mac App Store"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "${ASC_KEY_PATH/#\~/$HOME}" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

security unlock-keychain -p "$(cat ~/hermit/.kc)" "$KC"
APPID=$(security find-identity -v -p codesigning "$KC" | awk '/Apple Distribution/ {print $2; exit}')
[[ -n "$APPID" ]] || { echo "No Apple Distribution identity in $KC"; exit 1; }
security find-identity -v "$KC" | grep -qE "Mac Developer Installer|Mac Installer Distribution" || { echo "No installer identity: run scripts/mac-appstore-signing.sh"; exit 1; }
# Upload builds need a fresh build number; a timestamp is always higher than the last one.
BUILD=$(date -u +%Y%m%d%H%M)
~/hermit/xg/xcodegen/bin/xcodegen generate -q
rm -rf "$OUT"; mkdir -p "$OUT"
xcodebuild -project Hermit.xcodeproj -scheme Hermit -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" -archivePath "$OUT/Hermit.xcarchive" CURRENT_PROJECT_VERSION="$BUILD" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APPID" PROVISIONING_PROFILE_SPECIFIER="$PROFILE" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--keychain $KC" archive 2>&1 | grep -E "error:|warning: .*entitlement|ARCHIVE" || true
[[ -d "$OUT/Hermit.xcarchive" ]] || { echo "Archive failed"; exit 1; }
APP="$OUT/Hermit.xcarchive/Products/Applications/Hermit.app"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -qE "app-sandbox" || { echo "The archive isn't sandboxed"; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then echo "get-task-allow is still in the build"; exit 1; fi

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
  <key>provisioningProfiles</key><dict>
    <key>my.hermit.mac</key><string>$PROFILE</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Hermit.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT" "${AUTH[@]}"
echo "Uploaded build $BUILD. It shows in TestFlight after Apple processes it (5 to 30 minutes)."
