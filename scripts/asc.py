#!/usr/bin/env python3
"""App Store Connect API from the Mac, signed with the .p8 through openssl (no extra Python packages).
   asc.py GET /v1/certificates            asc.py POST /v1/certificates '{"data":...}'
Reads ~/hermit/asc.env. Prints the JSON response."""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

env = dict(l.strip().split("=", 1) for l in open(os.path.expanduser("~/hermit/asc.env")) if "=" in l)
KEY = os.path.expanduser(env["ASC_KEY_PATH"])

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der):
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } -> 64 raw bytes
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
    out = b""
    for _ in range(2):
        assert der[i] == 2; n = der[i + 1]; v = der[i + 2:i + 2 + n]; i += 2 + n
        out += v.lstrip(b"\0").rjust(32, b"\0")
    return out

def token():
    h = b64(json.dumps({"alg": "ES256", "kid": env["ASC_KEY_ID"], "typ": "JWT"}).encode())
    p = b64(json.dumps({"iss": env["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 900,
                        "aud": "appstoreconnect-v1"}).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY], input=f"{h}.{p}".encode(), capture_output=True, check=True).stdout
    return f"{h}.{p}.{b64(der_to_raw(sig))}"

def call(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=body.encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()

if __name__ == "__main__":
    st, out = call(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    print(st); print(out)
