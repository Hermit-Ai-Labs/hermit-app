#!/bin/zsh
# Signed, notarized Hermit.dmg that anyone can double-click. Runs on the team Mac after ~/hermit/setup-signing.sh.
#   zsh scripts/release-mac.sh
# Output: ~/hermit/release/Hermit-<version>.dmg
set -euo pipefail
cd "${0:A:h}/.."
KC=~/hermit/signing.keychain-db
TEAM=4G5YW2XP2B
DD=~/hermit/dd-release
OUT=~/hermit/release

security unlock-keychain -p "$(cat ~/hermit/.kc)" "$KC"
ID=$(security find-identity -v -p codesigning "$KC" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$ID" ]] || { echo "No Developer ID Application identity in $KC. Run ~/hermit/setup-signing.sh first."; exit 1; }
echo "Signing as: $ID"

~/hermit/xg/xcodegen/bin/xcodegen generate -q
xcodebuild -project Hermit.xcodeproj -scheme Hermit -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$ID" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KC --timestamp" ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO clean build | grep -E "error|BUILD" || true
APP="$DD/Build/Products/Release/Hermit.app"
codesign --verify --deep --strict --verbose=1 "$APP"
# Apple refuses debug entitlements in notarized apps
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then echo "get-task-allow is still in the build"; exit 1; fi

VER=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info" CFBundleVersion)
mkdir -p "$OUT"; DMG="$OUT/Hermit-$VER.dmg"; rm -f "$DMG"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Hermit" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --sign "$ID" --keychain "$KC" --timestamp "$DMG"

echo "Notarizing (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile hermit-notary --keychain "$KC" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "Ready: $DMG (version $VER, build $BUILD)"
