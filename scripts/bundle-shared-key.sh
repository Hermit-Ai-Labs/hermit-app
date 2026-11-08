#!/bin/bash
# Writes Hermit's shared keys into the app bundle, masked, for TestFlight builds: the NEAR AI Cloud key
# (HermitCloud/Resources/shared.bin) and the NEAR Intents 1Click partner key (HermitWallet/Resources/Bundled/intents.bin).
# Sources: ~/.secrets/nearai.env (NEARAI_API_KEY) and ~/.secrets/oneclick.env (ONECLICK_JWT) on the build server.
# The output files are gitignored; never commit them.
#   bash scripts/bundle-shared-key.sh          (write)
#   bash scripts/bundle-shared-key.sh --remove (build without a shared key)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)/Packages/HermitKit/Sources"
OUT="$ROOT/HermitCloud/Resources/shared.bin"
OUT2="$ROOT/HermitWallet/Resources/Bundled/intents.bin"
if [[ "${1:-}" == "--remove" ]]; then rm -f "$OUT" "$OUT2"; echo "shared keys removed"; exit 0; fi
set -a; source "$HOME/.secrets/nearai.env"; [[ -f "$HOME/.secrets/oneclick.env" ]] && source "$HOME/.secrets/oneclick.env"; set +a
umask 077
python3 - "$OUT" "$OUT2" <<'PY'
import base64, os, sys
mask = b"hermit-private-cloud"
def write(path, value):
    key = value.strip().encode()
    open(path, "wb").write(base64.b64encode(bytes(b ^ mask[i % len(mask)] for i, b in enumerate(key))))
write(sys.argv[1], os.environ["NEARAI_API_KEY"]); print("NEAR AI key written")
if os.environ.get("ONECLICK_JWT"): write(sys.argv[2], os.environ["ONECLICK_JWT"]); print("1Click partner key written")
PY
