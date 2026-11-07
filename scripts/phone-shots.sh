#!/bin/zsh
# Screenshots of every iPhone screen from the real app in the simulator (Debug build, launch arguments pick the page).
#   zsh scripts/phone-shots.sh [name ...]      default: all. Output: ~/hermit/shots/<name>.png
set -uo pipefail
cd "${0:A:h}/.."
DD=~/hermit/dd-sim
OUT=~/hermit/shots
SIM=${SIM:-"iPhone 17 Pro"}
BID=my.hermit.ios

SHOTS=(
  "welcome|-hermitUser|"
  "home|-hermitRoute home"
  "home-markets|-hermitRoute home -hermitScrollEnd YES"
  "drawer|-hermitRoute home -hermitDrawer YES"
  "trade-markets|-hermitRoute trade -hermitTab markets"
  "trade-positions|-hermitRoute trade -hermitTab positions"
  "trade-strategies|-hermitRoute trade -hermitTab strategies"
  "earn-defi|-hermitRoute earn -hermitTab defi"
  "earn-arb|-hermitRoute earn -hermitTab arb"
  "earn-airdrops|-hermitRoute earn -hermitTab airdrops"
  "earn-reverse|-hermitRoute earn -hermitTab reverse"
  "earn-positions|-hermitRoute earn -hermitTab positions"
  "payments-schedule|-hermitRoute payments -hermitTab schedule"
  "payments-payees|-hermitRoute payments -hermitTab payees"
  "payments-transfer|-hermitRoute payments -hermitTab transfer"
  "payments-apis|-hermitRoute payments -hermitTab apis"
  "wallets|-hermitRoute wallets"
  "sheet-add-wallet|-hermitRoute wallets -hermitTab add"
  "sheet-create-wallet|-hermitRoute wallets -hermitTab create"
  "sheet-import-wallet|-hermitRoute wallets -hermitTab import"
  "explore|-hermitRoute explore"
  "calendar|-hermitRoute calendar"
  "projects|-hermitRoute projects"
  "automations|-hermitRoute automations"
  "connectors|-hermitRoute connectors"
  "files|-hermitRoute files"
  "settings-profile|-hermitRoute settings -hermitTab profile"
  "settings-safety|-hermitRoute settings -hermitTab safety"
  "settings-memory|-hermitRoute settings -hermitTab memory"
  "settings-models|-hermitRoute settings -hermitTab models"
  "settings-home|-hermitRoute settings -hermitTab home"
)

~/hermit/xg/xcodegen/bin/xcodegen generate -q
xcodebuild -project Hermit.xcodeproj -scheme HermitiOS -configuration Debug -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
APP="$DD/Build/Products/Debug-iphonesimulator/Hermit.app"
[[ -d "$APP" ]] || { echo "Simulator build failed"; exit 1; }

UDID=$(xcrun simctl list devices available | grep -m1 "$SIM (" | grep -oE "[0-9A-F-]{36}")
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
xcrun simctl install "$UDID" "$APP"
mkdir -p "$OUT"; rm -f "$OUT"/*.png
for entry in $SHOTS; do
  name=${entry%%|*}; args=${entry#*|}
  (( $# )) && [[ ${@[(Ie)$name]} -eq 0 ]] && continue
  xcrun simctl terminate "$UDID" $BID 2>/dev/null
  if [[ $name == welcome ]]; then
    xcrun simctl launch "$UDID" $BID -hermitUser "" >/dev/null
  else
    xcrun simctl launch "$UDID" $BID -hermitUser Rahul ${=args} >/dev/null
  fi
  sleep ${WAIT:-4}
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 && echo "shot $name"
done
