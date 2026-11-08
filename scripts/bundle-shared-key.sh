#!/bin/bash
# Writes Hermit's shared NEAR AI Cloud key into the app bundle, masked, for TestFlight builds.
# Source: NEARAI_API_KEY in ~/.secrets/nearai.env on the build server. The output file is gitignored; never commit it.
#   bash scripts/bundle-shared-key.sh          (write)
#   bash scripts/bundle-shared-key.sh --remove (build without a shared key)
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/HermitKit/Sources/HermitCloud/Resources/shared.bin"
if [[ "${1:-}" == "--remove" ]]; then rm -f "$OUT"; echo "shared key removed"; exit 0; fi
source "$HOME/.secrets/nearai.env"
umask 077
python3 - "$OUT" <<'PY'
import base64, os, sys
key = os.environ["NEARAI_API_KEY"].strip().encode(); mask = b"hermit-private-cloud"
open(sys.argv[1], "wb").write(base64.b64encode(bytes(b ^ mask[i % len(mask)] for i, b in enumerate(key))))
print("shared key written")
PY
