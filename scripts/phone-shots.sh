#!/bin/zsh
# Screenshots of every iPhone screen from the real app in the simulator (Debug build, launch arguments pick the page).
#   zsh scripts/phone-shots.sh [name ...]      default: all. Output: $OUT/<name>.png (default ~/hermit/shots)
#   SIM="Hermit NEAR" DD=~/hermit/dd-near OUT=~/hermit/shots-near NOBUILD=1 zsh scripts/phone-shots.sh wallets-w
# Launch arguments (DEBUG only, AppModel / DebugLaunch.swift; -hermitSteps YES opens a reply's tool steps):
#   -hermitRoute <page> -hermitTab <tab or wallets flow> -hermitDrawer YES -hermitSheet <sheet> -hermitScroll bottom|<y>
#   -hermitDapp <url> -hermitDappAsk connect|sign|sol-connect|sol-tx (Explore's in-app browser, Pages/Browser/DappBrowser.swift)
#   -hermitTestWallet YES (memory-only vault with the public "abandon … about" phrase) -hermitMode cloud -hermitAsk <text>
# Per shot, @dark shoots in dark appearance and @xl at a larger Dynamic Type size; @w adds the test wallet.
set -uo pipefail
cd "${0:A:h}/.."
DD=${DD:-~/hermit/dd-sim}
OUT=${OUT:-~/hermit/shots}
SIM=${SIM:-"iPhone 17 Pro"}
BID=my.hermit.ios

SHOTS=(
  "welcome|-hermitUser|"
  "home|-hermitRoute home"
  "home-w|@w -hermitRoute home"
  "home-markets|-hermitRoute home -hermitScrollEnd YES"
  "home-cloud|-hermitRoute home -hermitMode cloud"
  "home-xl|@xl -hermitRoute home"
  "home-dark|@dark -hermitRoute home"
  "drawer|-hermitRoute home -hermitDrawer YES"
  "sheet-models|-hermitRoute home -hermitSheet models"
  "chat-cloud|@w -hermitSteps YES -hermitRoute home -hermitMode cloud -hermitAsk What_is_my_NEAR_balance_and_what_would_I_get_for_1_USDC_on_Base_in_NEAR?"
  "chat-send|@w -hermitSteps YES -hermitRoute home -hermitMode cloud -hermitAsk Send_1_USDT_on_NEAR_to_alice.near"
  "chat-swap|@w -hermitSteps YES -hermitRoute home -hermitMode cloud -hermitAsk Swap_5_USDT_on_NEAR_to_NEAR"
  "chat-bridge|@w -hermitSteps YES -hermitRoute home -hermitMode cloud -hermitAsk Bridge_1_SOL_on_Solana_to_USDC_on_Base"
  "chat-steps|@w -hermitSteps YES -hermitRoute home -hermitMode cloud -hermitAsk What_are_my_balances,_and_what_would_I_get_for_5_USDT_on_NEAR_in_NEAR?"
  "projects|-hermitRoute projects"
  "automations|-hermitRoute automations"
  "calendar|-hermitRoute calendar"
  "trade-markets|-hermitRoute trade -hermitTab markets"
  "trade-order|-hermitRoute trade -hermitTab markets -hermitScroll bottom"
  "trade-positions|-hermitRoute trade -hermitTab positions"
  "earn-positions|-hermitRoute earn -hermitTab positions"
  "earn-defi|-hermitRoute earn -hermitTab defi"
  "earn-arb|-hermitRoute earn -hermitTab arb"
  "earn-reverse|-hermitRoute earn -hermitTab reverse"
  "sheet-earn-deposit|@w -hermitRoute earn -hermitTab defi -hermitSheet earn-deposit"
  "payments-schedule|-hermitRoute payments -hermitTab schedule"
  "payments-payees|-hermitRoute payments -hermitTab payees"
  "payments-transfer|-hermitRoute payments -hermitTab transfer"
  "sheet-new-payment|-hermitRoute payments -hermitTab schedule -hermitSheet new-payment"
  "sheet-new-payee|-hermitRoute payments -hermitTab payees -hermitSheet new-payee"
  "wallets|-hermitRoute wallets"
  "wallets-w|@w -hermitRoute wallets"
  "wallets-w-bottom|@w -hermitRoute wallets -hermitScroll bottom"
  "wallets-security|@w -hermitRoute wallets -hermitTab security"
  "wallets-security-bottom|@w -hermitRoute wallets -hermitTab security -hermitScroll bottom"
  "wallets-dark|@dark @w -hermitRoute wallets"
  "wallets-xl|@xl @w -hermitRoute wallets"
  "sheet-picker|@w -hermitRoute wallets -hermitSheet picker"
  "sheet-add-wallet|-hermitRoute wallets -hermitTab add"
  "sheet-import-wallet|-hermitRoute wallets -hermitTab import"
  "sheet-quote|@w -hermitRoute wallets -hermitTab quote"
  "sheet-quote-empty|-hermitRoute wallets -hermitTab quote"
  "sheet-swap|@w -hermitRoute wallets -hermitTab swap"
  "sheet-bridge|@w -hermitRoute wallets -hermitTab bridge"
  "sheet-send|@w -hermitRoute wallets -hermitTab send"
  "sheet-receive|@w -hermitRoute wallets -hermitTab receive"
  "sheet-transfer|@w -hermitRoute wallets -hermitTab transfer"
  "sheet-history|@w -hermitRoute wallets -hermitTab history"
  "sheet-fund|@w -hermitRoute wallets -hermitSheet fund"
  "sheet-fund-any|@w -hermitRoute wallets -hermitSheet fund-any"
  "sheet-fund-hl|@w -hermitRoute trade -hermitSheet fund-hyperliquid"
  "sheet-fund-empty|-hermitRoute wallets -hermitSheet fund"
  "dialog-remove|@w -hermitRoute wallets -hermitSheet remove"
  "dialog-remove-dark|@dark @w -hermitRoute wallets -hermitSheet remove"
  "sheet-swap-dark|@dark @w -hermitRoute wallets -hermitTab swap"
  "sheet-approval|@w -hermitRoute wallets -hermitSheet approval"
  "sheet-approval-xl|@xl @w -hermitRoute wallets -hermitSheet approval"
  "status-pending|@w -hermitRoute wallets -hermitSheet status-pending"
  "status-processing|@w -hermitRoute wallets -hermitSheet status-processing"
  "status-success|@w -hermitRoute wallets -hermitSheet status-success"
  "status-refunded|@w -hermitRoute wallets -hermitSheet status-refunded"
  "status-failed|@w -hermitRoute wallets -hermitSheet status-failed"
  "status-incomplete|@w -hermitRoute wallets -hermitSheet status-incomplete"
  "sheet-proof|-hermitRoute home -hermitMode cloud -hermitSheet proof"
  "explore|-hermitRoute explore"
  "browser|@w -hermitRoute explore -hermitDapp https://app.uniswap.org/swap"
  "browser-connect|@w -hermitRoute explore -hermitDapp https://app.uniswap.org/swap -hermitDappAsk connect"
  "browser-sign|@w -hermitRoute explore -hermitDapp https://app.aave.com -hermitDappAsk sign"
  "browser-sol-connect|@w -hermitRoute explore -hermitDapp https://jup.ag -hermitDappAsk sol-connect"
  "browser-sol-tx|@w -hermitRoute explore -hermitDapp https://jup.ag -hermitDappAsk sol-tx"
  "settings-sites|-hermitRoute settings -hermitTab sites"
  "connectors|-hermitRoute connectors"
  "sheet-mcp|-hermitRoute connectors -hermitSheet mcp"
  "settings-profile|-hermitRoute settings -hermitTab profile"
  "settings-safety|-hermitRoute settings -hermitTab safety"
  "settings-memory|-hermitRoute settings -hermitTab memory"
  "settings-models|-hermitRoute settings -hermitTab models"
  "settings-cloud|-hermitRoute settings -hermitTab cloud"
  "settings-cloud-bottom|-hermitRoute settings -hermitTab cloud -hermitScroll bottom"
  "settings-home|-hermitRoute settings -hermitTab home"
)

if [[ -z ${NOBUILD:-} ]]; then
  ~/hermit/xg/xcodegen/bin/xcodegen generate -q
  xcodebuild -project Hermit.xcodeproj -scheme HermitiOS -configuration Debug -destination "platform=iOS Simulator,name=$SIM" \
    -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$DD/SourcePackages" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" | tail -5
fi
APP="$DD/Build/Products/Debug-iphonesimulator/Hermit.app"
[[ -d "$APP" ]] || { echo "Simulator build failed"; exit 1; }

UDID=$(xcrun simctl list devices available | grep -m1 "$SIM (" | grep -oE "[0-9A-F-]{36}")
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
xcrun simctl install "$UDID" "$APP"
mkdir -p "$OUT"; (( $# )) || rm -f "$OUT"/*.png
for entry in $SHOTS; do
  name=${entry%%|*}; args=${entry#*|}
  (( $# )) && [[ ${@[(Ie)$name]} -eq 0 ]] && continue
  xcrun simctl terminate "$UDID" $BID 2>/dev/null
  look=light; size=large; extra=()
  [[ $args == *@dark* ]] && look=dark
  [[ $args == *@xl* ]] && size=extra-extra-large
  [[ $args == *@w* ]] && extra=(-hermitTestWallet YES)
  args=${args//@dark/}; args=${args//@xl/}; args=${args//@w/}
  xcrun simctl ui "$UDID" appearance $look
  xcrun simctl ui "$UDID" content_size $size
  if [[ $name == welcome ]]; then
    xcrun simctl launch "$UDID" $BID -hermitUser "" >/dev/null
  else
    # -hermitAsk text uses _ for spaces (one shell word).
    a=(${=args}); for (( i = 2; i <= $#a; i++ )); do [[ ${a[i-1]} == -hermitAsk ]] && a[i]=${a[i]//_/ }; done
    [[ $args == *-hermitMode* ]] || extra+=(-hermitMode device)
    xcrun simctl launch "$UDID" $BID -hermitUser Rahul $extra "${a[@]}" >/dev/null
  fi
  w=${WAIT:-5}; [[ $name == chat-* ]] && w=${CHATWAIT:-40}; [[ $name == sheet-proof || $name == sheet-quote* || $name == home-cloud ]] && w=12; [[ $name == browser* ]] && w=20
  sleep $w
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1 && echo "shot $name"
done
xcrun simctl ui "$UDID" appearance light; xcrun simctl ui "$UDID" content_size large
