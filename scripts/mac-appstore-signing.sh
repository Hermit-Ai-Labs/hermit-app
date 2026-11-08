#!/bin/zsh
# One-time Mac App Store signing setup on the team Mac, through the App Store Connect API (~/hermit/asc.py, key in
# ~/hermit/asc.env). Safe to re-run: each step checks what exists.
#   1. A Mac Installer Distribution certificate (signs the .pkg). Its private key is made here and stays in
#      ~/hermit/certs and ~/hermit/signing.keychain-db.
#   2. The "Hermit Mac App Store" provisioning profile for my.hermit.mac with the shared Apple Distribution certificate.
set -euo pipefail
H=~/hermit; C=$H/certs; KC=$H/signing.keychain-db; KCPW="$(cat $H/.kc)"
asc() { python3 $H/asc.py "$@"; }
json() { python3 -c "import sys,json; s=sys.stdin.read().split('\n',1); d=json.loads(s[1]); $1"; }
security unlock-keychain -p "$KCPW" "$KC"

# 1. Installer certificate
if ! security find-certificate -c "Mac Installer Distribution" "$KC" >/dev/null 2>&1 && \
   ! security find-certificate -c "3rd Party Mac Developer Installer" "$KC" >/dev/null 2>&1; then
  [[ -f $C/MAC_INSTALLER.key ]] || openssl genrsa -out $C/MAC_INSTALLER.key 2048 2>/dev/null
  chmod 600 $C/MAC_INSTALLER.key
  openssl req -new -key $C/MAC_INSTALLER.key -subj "/CN=Hermit Mac Installer/C=IN" -out $C/MAC_INSTALLER.csr
  CSR=$(grep -v "CERTIFICATE REQUEST" $C/MAC_INSTALLER.csr | tr -d '\n')
  asc POST /v1/certificates "{\"data\":{\"type\":\"certificates\",\"attributes\":{\"certificateType\":\"MAC_INSTALLER_DISTRIBUTION\",\"csrContent\":\"$CSR\"}}}" > $C/MAC_INSTALLER.json
  head -1 $C/MAC_INSTALLER.json
  python3 -c "import json,base64,sys; d=json.loads(open('$C/MAC_INSTALLER.json').read().split('\n',1)[1]); open('$C/MAC_INSTALLER.cer','wb').write(base64.b64decode(d['data']['attributes']['certificateContent'])); print('cert', d['data']['id'], d['data']['attributes']['name'])"
  security import $C/MAC_INSTALLER.key -k "$KC" -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/xcodebuild
  security import $C/MAC_INSTALLER.cer -k "$KC"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
fi
security find-identity -v "$KC" | grep -iE "installer" || echo "installer identity missing"

# 2. Provisioning profile
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES"
EXIST=$(asc GET "/v1/profiles?filter[name]=Hermit%20Mac%20App%20Store" | json "print(d['data'][0]['id'] if d['data'] else '')")
if [[ -z $EXIST ]]; then
  BID=$(asc GET "/v1/bundleIds?filter[identifier]=my.hermit.mac" | json "print([x['id'] for x in d['data'] if x['attributes']['identifier']=='my.hermit.mac'][0])")
  CERT=$(asc GET "/v1/certificates?filter[certificateType]=DISTRIBUTION" | json "print(d['data'][0]['id'])")
  asc POST /v1/profiles "{\"data\":{\"type\":\"profiles\",\"attributes\":{\"name\":\"Hermit Mac App Store\",\"profileType\":\"MAC_APP_STORE\"},\"relationships\":{\"bundleId\":{\"data\":{\"type\":\"bundleIds\",\"id\":\"$BID\"}},\"certificates\":{\"data\":[{\"type\":\"certificates\",\"id\":\"$CERT\"}]}}}}" > $H/mac-profile.json
  head -1 $H/mac-profile.json
  EXIST=$(json "print(d['data']['id'])" < $H/mac-profile.json)
fi
asc GET "/v1/profiles/$EXIST" | json "
import base64,plistlib,os
a=d['data']['attributes']; raw=base64.b64decode(a['profileContent'])
p=os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles/'+a['uuid']+'.provisionprofile')
open(p,'wb').write(raw); print('profile', a['name'], a['profileState'], a['uuid'])"
