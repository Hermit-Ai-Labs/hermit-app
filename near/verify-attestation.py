#!/usr/bin/env python3
"""Verify NEAR AI Cloud TEE attestation the way Hermit's Private Cloud mode does, step by step.

No API key needed for attestation. With NEARAI_API_KEY set, it also sends one tiny completion and checks the
response signature against the attested model signer.

    python3 -m venv .venv && .venv/bin/pip install -r near/requirements.txt
    .venv/bin/python near/verify-attestation.py                       # live, default model
    .venv/bin/python near/verify-attestation.py --model z-ai/glm-5.3-flash
    .venv/bin/python near/verify-attestation.py --report Packages/HermitKit/Tests/HermitCloudTests/Fixtures/qwen-report.json \
        --nonce "$(cat Packages/HermitKit/Tests/HermitCloudTests/Fixtures/qwen-report.nonce)" --offline
    NEARAI_API_KEY=... .venv/bin/python near/verify-attestation.py --sdk   # also cross-check with NEAR's official SDK
    (--sdk needs Python 3.12+ and `.venv/bin/pip install -r near/requirements-sdk.txt` first)

Checks follow https://docs.near.ai/cloud/verification (gateway attestation, model attestations,
quote/nonce/signer reference, response signatures, image provenance). Exit code 1 if any required check fails.

It also checks that the enclave runs what NEAR publishes, which Hermit's app only does in part:
  - the guest OS: MRTD, RTMR1 and RTMR2 are recomputed from the image NEAR publishes in
    github.com/nearai/dstack-images (firmware, kernel, command line, initramfs) and compared with the quote;
  - NEAR's own containers: each digest must carry a GitHub build attestation (Sigstore) from NEAR's repository;
  - the model's containers: the compose manager's signed action log must name tagged files in
    github.com/nearai/cvm-compose-files, with matching hashes.
With --offline the OS check uses the values pinned below and the rest is skipped.
Nothing is stored: the report is only written to disk when you pass --save.
"""
import argparse, asyncio, base64, hashlib, http.client, io, json, os, re, secrets, ssl, struct, sys, tarfile, time, urllib.parse, uuid

import requests

API = "https://cloud-api.near.ai/v1"
NRAS = "https://nras.attestation.nvidia.com/v3/attest/gpu"
DEFAULT_MODEL = "Qwen/Qwen3.8-27B"
ACCEPTED_TCB = {"UpToDate"}

# What NEAR publishes. Sources and what each proves: docs/NEAR.md, "Is it NEAR's software?".
OS_IMAGES = "https://github.com/nearai/dstack-images/releases/download/os-image-mr/mr_{}.tar.gz"
COMPOSE_REPO = "nearai/cvm-compose-files"
GITHUB_ACTIONS = "https://token.actions.githubusercontent.com"
# Docker Hub image -> the GitHub repository whose Actions build must have signed that digest.
IMAGE_SOURCES = {
    "nearaidev/cloud-api": "nearai/cloud-api",              # the gateway
    "nearaidev/cvm-ingress": "nearai/cvm-ingress",          # the gateway's TLS front
    "nearaidev/compose-manager": "nearai/compose-manager",  # deploys the model containers
    "nearaidev/vllm-proxy-rs": "nearai/inference-proxy",    # holds the model enclave's signing key
}
# os_image_hash -> (name, MRTD for QEMU 8 and QEMU 9+, RTMR1, RTMR2). This script recomputed them from NEAR's
# tarballs on 2026-11-12; they are only used with --offline. The app pins the same values
# (HermitCloud/Attestation.swift, knownOSImages). RTMR1 holds for VMs with 2 GB or at least 2.75 GB of memory.
_MRTD = {"7fe60787222bd394cb516abca2435f22f035ab2cc9c0a4b4b3b148e46297f3d931a237b72f359052c6e657d8c1409173",
         "df4d77c857de652bd0fafa343a2026b51071ee03773d076d283abf1a7d36ff91ffa279ee4a617ac664f7e2a2c8d5891b"}
_RTMR1 = "4ae609807c765916a31d724786ed74bcb97e168a9d937b04936aeef2015c907eba5ac352c6bcd749c246fd62ffb659ec"
KNOWN_OS_IMAGES = {
    "8db40cb23008d6213668b5816702d100b37b859a8a5bfd18d938ae3a1b3715bd": ("dstack-0.5.12", _MRTD, _RTMR1,
        "764489f277a8540189761e72b4238ba36d4d647e11bd958d8ab5522af2a4867b0ff63e06b0c4967f1857236244040a5d"),
    "91fd5d69ccee3e5ea4f2aeb8c9b632c4358c4ecfc29ba1aa6fb1e402af209829": ("dstack-nvidia-0.5.12", _MRTD, _RTMR1,
        "bd67ab7554dc27ab03a077bc1447a1a67d0624ff547c4c809a8626f12d6a89712f8ec60e781e99b98208574065d21a71"),
}

results = []  # (scope, check, ok, detail)


def check(scope, name, ok, detail=""):
    results.append((scope, name, ok, detail))
    mark = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
    print(f"  [{mark}] {name}" + (f"  ({detail})" if detail else ""))
    return ok


def _json(v):
    return json.loads(v) if isinstance(v, str) else v


# --- Intel TDX quote v4, read straight from the bytes (the same parser Hermit uses in Swift) ---------------
def parse_td_quote(raw: bytes) -> dict:
    version, = struct.unpack_from("<H", raw, 0)
    tee_type, = struct.unpack_from("<I", raw, 4)
    body = raw[48:48 + 584]
    return {
        "version": version, "tee_type": tee_type,
        "td_attributes": body[120:128], "mr_td": body[136:184], "mr_config_id": body[184:232],
        "rt_mr": [body[328 + 48 * i: 376 + 48 * i] for i in range(4)], "report_data": body[520:584],
    }


def replay_rtmr3(event_log) -> bytes:
    rtmr3 = bytes(48)
    for e in _json(event_log):
        if e.get("imr") != 3:
            continue
        d = hashlib.sha384(struct.pack("<I", e["event_type"]) + b":" + e["event"].encode() + b":"
                           + bytes.fromhex(e.get("event_payload") or "")).digest()
        if e.get("digest") and bytes.fromhex(e["digest"]) != d:
            raise ValueError(f"digest mismatch for event {e['event']}")
        rtmr3 = hashlib.sha384(rtmr3 + d).digest()
    return rtmr3


# --- The guest OS: recompute MRTD, RTMR1 and RTMR2 from the image NEAR publishes ---------------------------
# A port of the TDX parts of dstack-mr (github.com/Dstack-TEE/dstack, dstack/dstack-mr/src: tdvf.rs, kernel.rs,
# machine.rs). RTMR0 is not recomputed: it needs QEMU's ACPI tables for the exact virtual machine.
def sha384(b: bytes) -> bytes:
    return hashlib.sha384(b).digest()


def replay(digests) -> bytes:
    mr = bytes(48)
    for d in digests:
        mr = sha384(mr + d)
    return mr


def tdvf_sections(fw: bytes):
    """The TDVF metadata sections of an OVMF image: (data offset, raw size, guest address, size, type, attributes)."""
    off = len(fw) - 32
    if fw[off - 16:off] != uuid.UUID("96b582de-1fb2-45f7-baea-a366c55a082d").bytes_le:
        raise ValueError("firmware has no GUID table")
    tables = fw[off - 18 - struct.unpack_from("<H", fw, off - 18)[0]:off - 18]
    o, want, data = len(tables), uuid.UUID("e47a6535-984a-4798-865e-4685a7bf8ec2").bytes_le, None
    while o > 18:
        n, = struct.unpack_from("<H", tables, o - 18)
        if not 18 <= n <= o:
            raise ValueError("bad GUID table entry")
        if tables[o - 16:o] == want:
            data = tables[o - n:o - 18]
            break
        o -= n
    if not data:
        raise ValueError("firmware has no TDX metadata")
    meta = len(fw) - struct.unpack("<I", data[-4:])[0]
    sig, _, ver, count = struct.unpack_from("<4sIII", fw, meta)
    if sig != b"TDVF" or ver != 1 or count > 64:
        raise ValueError("bad TDVF descriptor")
    return [struct.unpack_from("<IIQQII", fw, meta + 16 + 32 * i) for i in range(count)]


def mrtd(fw: bytes, two_pass: bool) -> bytes:
    """MRTD as the TDX module builds it: MEM.PAGE.ADD for each page, MR.EXTEND for each 256 bytes of measured pages.
    QEMU 8 adds a section's pages first and extends after (two passes); QEMU 9 and later interleave them."""
    h = hashlib.sha384()

    def add(s, page):
        if not s[5] & 2:  # not PAGE_AUG
            h.update(b"MEM.PAGE.ADD".ljust(16, b"\0") + struct.pack("<Q", s[2] + page * 4096) + bytes(104))

    def extend(s, page):
        if s[5] & 1:  # MR_EXTEND
            for i in range(16):
                at = page * 4096 + i * 256
                h.update(b"MR.EXTEND".ljust(16, b"\0") + struct.pack("<Q", s[2] + at) + bytes(104))
                h.update(fw[s[0] + at:s[0] + at + 256])

    for s in tdvf_sections(fw):
        pages = range(s[3] // 4096)
        if two_pass:
            for p in pages: add(s, p)
            for p in pages: extend(s, p)
        else:
            for p in pages: add(s, p); extend(s, p)
    return h.digest()


def authenticode_sha384(d: bytes) -> bytes:
    """The PE/COFF Authenticode hash OVMF measures for the kernel: headers without checksum and certificate
    directory, then each section in file order."""
    pe, = struct.unpack_from("<I", d, 0x3c)
    if d[pe:pe + 4] != b"PE\0\0":
        raise ValueError("kernel is not a PE image")
    coff, opt = pe + 4, pe + 24
    count, = struct.unpack_from("<H", d, coff + 2)
    opt_size, = struct.unpack_from("<H", d, coff + 16)
    checksum = opt + 64
    cert = opt + (112 if struct.unpack_from("<H", d, opt)[0] == 0x20b else 96) + 4 * 8
    headers, = struct.unpack_from("<I", d, opt + 60)
    if not cert + 8 <= headers <= len(d):
        raise ValueError("bad PE headers")
    h = hashlib.sha384(d[:checksum] + d[checksum + 4:cert] + d[cert + 8:headers])
    done, sections = headers, []
    for i in range(count):
        size, ptr = struct.unpack_from("<II", d, opt + opt_size + 40 * i + 16)
        if size:
            sections.append((ptr, size))
    for ptr, size in sorted(sections):
        h.update(d[ptr:ptr + size])
        done += size
    cert_addr, cert_size = struct.unpack_from("<II", d, cert)
    if cert_addr and cert_size and len(d) - done > cert_size:
        h.update(d[done:len(d) - cert_size])
    if len(d) % 8:
        h.update(bytes(8 - len(d) % 8))
    return h.digest()


def qemu_patched_kernel(kernel: bytes, initrd_size: int, memory: int) -> bytes:
    """The kernel as QEMU hands it to OVMF: it fills in the Linux setup header (loader type, heap, command line
    and initrd addresses) before the firmware measures the image."""
    k = bytearray(kernel)
    protocol, = struct.unpack_from("<H", k, 0x206)
    if len(k) < 0x1000 or protocol < 0x20c:
        raise ValueError("kernel boot protocol too old")
    real, cmdline = (0x10000, 0x20000) if k[0x211] & 1 else (0x90000, 0x9a000)
    k[0x210] = 0xb0   # type_of_loader: QEMU
    k[0x211] |= 0x80  # CAN_USE_HEAP
    struct.pack_into("<I", k, 0x224, cmdline - real - 0x200)
    struct.pack_into("<I", k, 0x228, cmdline)
    initrd_max = 0xffffffff if struct.unpack_from("<H", k, 0x236)[0] & 2 else 0x37ffffff
    low = 0xB0000000 if memory < 0xB0000000 else 0x80000000
    initrd_max = min(initrd_max, min(memory, low) - 0x28000 - 1)
    struct.pack_into("<II", k, 0x218, (initrd_max - initrd_size) & ~4095, initrd_size)
    return bytes(k)


_os_images = {}


def published_os_image(os_hash: str, memory: int):
    """Download NEAR's measurement tarball for this os_image_hash, check its own hashes, and recompute
    (name, MRTDs, RTMR1, RTMR2) from the firmware, kernel, command line and initramfs inside."""
    if not re.fullmatch(r"[0-9a-f]{64}", os_hash):
        raise ValueError("no os-image-hash in the event log")
    if os_hash not in _os_images:
        r = requests.get(OS_IMAGES.format(os_hash), timeout=120)
        if r.status_code == 404:
            raise ValueError("NEAR publishes no image with this hash")
        r.raise_for_status()
        with tarfile.open(fileobj=io.BytesIO(r.content), mode="r:gz") as tar:  # read in memory, nothing is extracted
            f = {m.name.removeprefix("./"): tar.extractfile(m).read() for m in tar if m.isfile() and m.size < 1 << 28}
        if hashlib.sha256(f["sha256sum.txt"]).hexdigest() != os_hash:
            raise ValueError("tarball is not the image with this hash")
        for line in f["sha256sum.txt"].decode().splitlines():
            want, name = line.split()
            if hashlib.sha256(f[name]).hexdigest() != want:
                raise ValueError(f"{name} does not match the image's sha256sum.txt")
        _os_images[os_hash] = f
    f = _os_images[os_hash]
    meta = json.loads(f["metadata.json"])
    fw, kernel, initrd = f[meta["bios"]], f[meta["kernel"]], f[meta["initrd"]]
    rtmr1 = replay([authenticode_sha384(qemu_patched_kernel(kernel, len(initrd), memory)),
                    sha384(b"Calling EFI Application from Boot Option"), sha384(bytes(4)),
                    sha384(b"Exit Boot Services Invocation"), sha384(b"Exit Boot Services Returned with Success")])
    rtmr2 = replay([sha384((meta["cmdline"] + " initrd=initrd").encode("utf-16-le") + b"\0\0"), sha384(initrd)])
    name = KNOWN_OS_IMAGES.get(os_hash, [f"dstack {meta.get('version', '?')}"])[0]
    return name, {mrtd(fw, True).hex(), mrtd(fw, False).hex()}, rtmr1.hex(), rtmr2.hex()


def check_os_image(scope, report, q, offline):
    log = _json(report["event_log"])
    check(scope, "Event log replays to RTMR0, RTMR1 and RTMR2",
          all(replay(bytes.fromhex(e["digest"]) for e in log if e.get("imr") == i) == q["rt_mr"][i] for i in range(3)))
    # The OS image hash comes from the RTMR3 event log, which the check above tied to the quote.
    os_hash = next((e.get("event_payload", "") for e in log if e.get("imr") == 3 and e.get("event") == "os-image-hash"), "")
    title = "Guest OS image is one NEAR publishes"
    try:
        if offline:
            if os_hash not in KNOWN_OS_IMAGES:
                check(scope, title, None, f"skipped with --offline, {os_hash[:12]}… is not pinned in this script")
                return
            (name, mrtds, rtmr1, rtmr2), src = KNOWN_OS_IMAGES[os_hash], "values pinned in this script"
        else:
            memory = int(_json(report.get("info", {}).get("vm_config") or "{}").get("memory_size") or 1 << 33)
            (name, mrtds, rtmr1, rtmr2), src = published_os_image(os_hash, memory), "recomputed from the download"
    except Exception as e:  # noqa: BLE001
        check(scope, title, False, f"{os_hash[:12]}…: {e}")
        return
    check(scope, title, True, f"{name}, nearai/dstack-images mr_{os_hash[:12]}…, {src}")
    check(scope, "MRTD matches that image's firmware", q["mr_td"].hex() in mrtds, f"{q['mr_td'].hex()[:16]}…")
    check(scope, "RTMR1 matches that image's kernel", q["rt_mr"][1].hex() == rtmr1, f"{rtmr1[:16]}…")
    check(scope, "RTMR2 matches that image's command line and initramfs", q["rt_mr"][2].hex() == rtmr2,
          f"{rtmr2[:16]}…, the command line pins the root filesystem")


# --- The containers: digests, and who built NEAR's own images -------------------------------------------
def split_image(ref: str):
    """'repo[:tag]@sha256:digest' -> (repo, digest); digest is None when the image is not pinned.
    '${VAR:-default}' reads as its default."""
    ref = str(ref).strip("\"'")
    m = re.fullmatch(r"\$\{\w+:-(.+)\}", ref)
    ref = (m[1] if m else ref).removeprefix("docker.io/")
    m = re.fullmatch(r"([^@$]+?)(?::[\w.-]+)?@sha256:([0-9a-f]{64})", ref)
    return (m[1], m[2]) if m else (ref, None)


_provenance = {}  # (image, digest) -> (ok, detail, workflow)


def provenance(image, digest, offline):
    """Is there a GitHub artifact attestation for this digest, signed through Sigstore by a GitHub Actions run of
    NEAR's repository for this image? Returns (True/False/None, detail). None means it could not be checked."""
    src = IMAGE_SOURCES[image]
    if offline:
        return None, "skipped with --offline"
    if (image, digest) in _provenance:
        return _provenance[image, digest][:2]
    try:
        from cryptography import x509
        from sigstore.models import Bundle
        from sigstore.verify import Verifier, policy
    except ImportError:
        return None, "needs sigstore: pip install -r near/requirements.txt"
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    try:
        r = requests.get(f"https://api.github.com/repos/{src}/attestations/sha256:{digest}", params={"per_page": 100},
                         headers=headers, timeout=30)
        if r.status_code in (403, 429) and r.headers.get("x-ratelimit-remaining") == "0":
            return None, "GitHub's API limit for this address is used up: set GITHUB_TOKEN or try again in an hour"
        if r.status_code == 404:
            return False, f"github.com/{src} has no build attestation for sha256:{digest[:12]}…"
        r.raise_for_status()
        verifier = _provenance.setdefault("verifier", None) or Verifier.production()  # Sigstore's public-good root, through TUF
        _provenance["verifier"] = verifier
        who = policy.AllOf([policy.OIDCIssuer(GITHUB_ACTIONS), policy.GitHubWorkflowRepository(src)])
        why = "no attestation returned"
        for a in r.json().get("attestations", []):
            try:
                bundle = Bundle.from_json(json.dumps(a["bundle"]))
                kind, payload = verifier.verify_dsse(bundle, who)  # certificate, signature, transparency log, identity
                subjects = json.loads(payload).get("subject", [])
                if kind != "application/vnd.in-toto+json" or not any(
                        s.get("digest", {}).get("sha256") == digest and s.get("name", "").removeprefix("docker.io/") == image
                        for s in subjects):
                    raise ValueError("the signed statement is for another artifact")
                cert = bundle.signing_certificate
                san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value \
                    .get_values_for_type(x509.UniformResourceIdentifier)[0]
                prefix = f"https://github.com/{src}/"
                if not san.startswith(prefix + ".github/workflows/"):
                    raise ValueError(f"signed by {san}")
                commit = cert.extensions.get_extension_for_oid(x509.ObjectIdentifier("1.3.6.1.4.1.57264.1.3")).value.value.decode()
                workflow, _, ref = san.removeprefix(prefix).partition("@")
                out = (True, f"sha256:{digest[:12]}…, github.com/{src} {workflow.rsplit('/', 1)[-1]}@{ref}, commit {commit[:7]}", workflow)
                _provenance[image, digest] = out
                return out[:2]
            except Exception as e:  # noqa: BLE001
                why = str(e) or type(e).__name__
        return False, why
    except Exception as e:  # noqa: BLE001
        return False, str(e)


def check_images(scope, images, offline, where, note=""):
    """`images`: image references as written in a compose file. NEAR's own must have build provenance; the rest
    are listed as not checked."""
    others, ours = [], {}
    for image, digest in sorted({split_image(i) for i in images}, key=lambda x: (x[0], x[1] or "")):
        if image in IMAGE_SOURCES and digest:
            ours.setdefault(image, []).append(provenance(image, digest, offline))
        else:
            others.append(image if digest else f"{image} (no digest)")
    for image, found in ours.items():  # one line per image; every digest of it must pass
        oks = [ok for ok, _ in found]
        check(scope, f"Built from NEAR's repository: {image}{note}", False if False in oks else None if None in oks else True,
              "; ".join(dict.fromkeys(detail for _, detail in found)))
    others = list(dict.fromkeys(others))
    if others:
        check(scope, f"Who built the other {len(others)} image(s) {where}", None, ", ".join(others))


async def dcap(scope, name, raw, q, offline):
    """Quote signature chain and TCB status (Intel DCAP via dcap-qvl, collateral from PCCS). Returns whether
    dcap-qvl read the same report data and RTMR3 as our parser, or None if it did not verify."""
    if offline:
        check(scope, name, None, "skipped with --offline")
        return None
    import dcap_qvl
    try:
        v = await dcap_qvl.get_collateral_and_verify(raw)
        body = json.loads(v.to_json())["report"]["TD10"]
        check(scope, name, v.status in ACCEPTED_TCB, f"TCB {v.status}" + (f", advisories {v.advisory_ids}" if v.advisory_ids else ""))
        return bytes.fromhex(body["report_data"]) == q["report_data"] and bytes.fromhex(body["rt_mr3"]) == q["rt_mr"][3]
    except Exception as e:  # noqa: BLE001
        check(scope, name, False, str(e))
        return None


def repo_tags(repo):
    """Every tag of a public GitHub repository and the commit it points at, from git's own ref listing."""
    r = requests.get(f"https://github.com/{repo}/info/refs", params={"service": "git-upload-pack"}, timeout=60)
    r.raise_for_status()
    tags = {}
    for sha, name in re.findall(r"[0-9a-f]{4}([0-9a-f]{40}) refs/tags/([^\n\0]+)", r.content.decode("latin-1")):
        if name.endswith("^{}"):
            tags[name[:-3]] = sha  # an annotated tag's commit
        else:
            tags.setdefault(name, sha)
    return tags


async def verify_compose_manager(scope, report, q, nonce, offline):
    """The model enclave's measured compose only starts a launcher and NEAR's compose manager; the model containers
    are deployed later from github.com/nearai/cvm-compose-files. The manager keeps a log of what it deployed and
    signs it with a TDX quote: report data = SHA-256(actions as compact JSON, keys sorted) || our nonce."""
    cm = report.get("compose_manager_attestation")
    if not cm:
        check(scope, "Compose manager's deployment log", None, "none in this report, so the model containers are not checked")
        return
    raw = bytes.fromhex(cm.get("quote") or cm["intel_quote"])
    cq = parse_td_quote(raw)
    await dcap(scope, "Compose manager quote: Intel DCAP (dcap-qvl)", raw, cq, offline)
    check(scope, "Compose manager quote has this enclave's measurements",
          cq["mr_td"] == q["mr_td"] and cq["rt_mr"] == q["rt_mr"] and cq["mr_config_id"] == q["mr_config_id"]
          and cq["td_attributes"] == q["td_attributes"], "MRTD, RTMR0 to RTMR3 and MRCONFIGID equal")
    actions = cm.get("actions") or []
    h = hashlib.sha256(json.dumps(actions, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).digest()
    check(scope, "Compose manager quote binds its action log and our nonce",
          cq["report_data"] == h + bytes.fromhex(nonce), f"{len(actions)} actions, sha256 {h.hex()[:16]}…")

    started = [a for a in actions if a.get("action") == "compose_manager_started"]
    check_images(scope, [started[-1].get("image", "")] if started else [], offline, "", ", the one the log says is running")
    up = {}  # service -> the compose_up that last started it, unless a compose_down followed
    for a in actions:
        if a.get("action") == "compose_up":
            for s in a.get("services") or ["*"]:
                up[s] = a
        elif a.get("action") == "compose_down":
            for s in a.get("services") or [s for s, u in up.items() if u.get("file") == a.get("file")]:
                up.pop(s, None)
    files = sorted({(a.get("tag", ""), a.get("commit", ""), a.get("file", ""), a.get("file_sha256", "")) for a in up.values()})
    title = f"Deployed compose files are tagged files in {COMPOSE_REPO}"
    if offline or not files:
        check(scope, title, None, "skipped with --offline" if offline else "the log has no deployment")
        return
    try:
        import yaml
        tags, docs = repo_tags(COMPOSE_REPO), {}
        for tag, commit, file, sha in files:
            if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[\w.-]+(/[\w.-]+)*", file) or ".." in file:
                raise ValueError(f"bad file reference {file}@{commit[:12]}")
            if tags.get(tag) != commit:
                raise ValueError(f"{commit[:12]} is not tag {tag} of {COMPOSE_REPO}")
            r = requests.get(f"https://raw.githubusercontent.com/{COMPOSE_REPO}/{commit}/{file}", timeout=60)
            r.raise_for_status()
            if hashlib.sha256(r.content).hexdigest() != sha:
                raise ValueError(f"{file} at {tag} does not have the logged sha256")
            docs[commit, file] = yaml.safe_load(r.content).get("services") or {}
    except Exception as e:  # noqa: BLE001
        check(scope, title, False, str(e))
        return
    names = sorted({f[0] for f in files}, key=lambda t: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", t)])
    check(scope, title, True, f"{len(files)} file version(s) behind the {len(up)} services the log has up, tags {names[0]} to {names[-1]}, sha256 equal")
    images = []
    for s, a in up.items():
        services = docs[a["commit"], a["file"]]
        images += [v.get("image") for k, v in services.items() if (s == "*" or k == s) and isinstance(v, dict) and v.get("image")]
    check_images(scope, images, offline, "those files deploy")


async def verify_report(scope, report, nonce, offline):
    print(f"\n{scope}: signer {report.get('signing_address')} ({report.get('signing_algo')})")
    raw = bytes.fromhex(report["intel_quote"])
    q = parse_td_quote(raw)
    check(scope, "Quote is Intel TDX v4", q["version"] == 4 and q["tee_type"] == 0x81, f"version {q['version']}, tee 0x{q['tee_type']:x}")

    # 1. Quote signature chain and TCB status (Intel DCAP via dcap-qvl, collateral from PCCS).
    same = await dcap(scope, "Intel DCAP quote verification (dcap-qvl)", raw, q, offline)
    if same is not None:
        check(scope, "Local quote parser matches dcap-qvl", same)

    check(scope, "TDX debug mode off", q["td_attributes"][0] & 1 == 0, f"td_attributes {q['td_attributes'].hex()}")

    # 2. Nonce and signer bound in the quote's report data: signer (zero-padded to 32) || client nonce.
    check(scope, "Echoed nonce matches ours", (report.get("request_nonce") or "").lower() == nonce.lower())
    check(scope, "Quote report data ends with our nonce", q["report_data"][32:] == bytes.fromhex(nonce))
    ident = bytes.fromhex(report["signing_address"].removeprefix("0x"))
    want = {"ecdsa": 20, "ed25519": 32}.get(report["signing_algo"])
    fp = report.get("tls_cert_fingerprint")
    bound = hashlib.sha256(ident + bytes.fromhex(fp)).digest() if fp else ident.ljust(32, b"\0")
    check(scope, "Quote report data binds the signing address", want == len(ident) and q["report_data"][:32] == bound)
    if report.get("report_data"):
        check(scope, "HTTP report_data equals quote report data", bytes.fromhex(report["report_data"]) == q["report_data"])

    # 3. Measured configuration: MRCONFIGID = 01 || sha256(app_compose) || 15 zero bytes.
    app_compose = _json(report["info"]["tcb_info"])["app_compose"]
    ch = hashlib.sha256(app_compose.encode()).digest()
    check(scope, "MRCONFIGID matches app_compose", q["mr_config_id"] == b"\x01" + ch + bytes(15), f"compose sha256 {ch.hex()[:16]}…")

    # 4. Runtime event log replays to RTMR3.
    try:
        check(scope, "Event log replays to RTMR3", replay_rtmr3(report["event_log"]) == q["rt_mr"][3])
    except ValueError as e:
        check(scope, "Event log replays to RTMR3", False, str(e))

    # 5. GPU evidence (model reports): nonce inside the NVIDIA payload, then NVIDIA NRAS verdict.
    if report.get("nvidia_payload"):
        gpu = _json(report["nvidia_payload"])
        check(scope, "GPU evidence carries our nonce", str(gpu.get("nonce", "")).lower() == nonce.lower(),
              f"{len(gpu.get('evidence_list', []))} GPUs, arch {gpu.get('arch')}")
        if offline:
            check(scope, "NVIDIA NRAS GPU verdict", None, "skipped with --offline")
        else:
            try:
                r = requests.post(NRAS, json=gpu, timeout=60, headers={"Accept": "application/json"})
                r.raise_for_status()
                token = r.json()[0][1]
                payload = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
                check(scope, "NVIDIA NRAS GPU verdict", payload.get("x-nvidia-overall-att-result") is True,
                      f"eat_nonce {str(payload.get('eat_nonce', ''))[:12]}…")
            except Exception as e:  # noqa: BLE001
                check(scope, "NVIDIA NRAS GPU verdict", False, str(e))

    # 6. Is it NEAR's software? The guest OS, then the containers the measured compose starts.
    check_os_image(scope, report, q, offline)
    images = re.findall(r"^\s*image:\s*(\S+)", json.loads(app_compose).get("docker_compose_file", ""), re.M)
    unpinned = [i for i, d in map(split_image, images) if not d]
    check(scope, "Every image in the measured compose is pinned by digest", bool(images) and not unpinned,
          ", ".join(unpinned) or f"{len(set(images))} images")
    check_images(scope, images, offline, "in the measured compose")
    if report.get("model_name"):
        await verify_compose_manager(scope, report, q, nonce, offline)


class Gateway:
    """One TLS connection to cloud-api.near.ai, kept open so the report and the completion share it."""
    def __init__(self):
        self.c = http.client.HTTPSConnection("cloud-api.near.ai", context=ssl.create_default_context(), timeout=120)
        self.c.connect()
        self.sock = self.c.sock

    def peer_spki_sha256(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
        cert = x509.load_der_x509_certificate(self.c.sock.getpeercert(binary_form=True))
        return hashlib.sha256(cert.public_key().public_bytes(serialization.Encoding.DER,
                                                            serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()

    def same_connection(self):
        return self.c.sock is self.sock

    def request(self, method, path, body=None, headers=None):
        self.c.request(method, path, body=body, headers=headers or {})
        r = self.c.getresponse()
        data = r.read()
        if r.status >= 300:
            raise RuntimeError(f"{method} {path}: HTTP {r.status} {data[:200]!r}")
        return data


def verify_completion(gw, model, model_signers, gateway_signer, key):
    """One non-streamed completion; the model enclave signs <model>:<sha256(request)>:<sha256(response)>."""
    from eth_account import Account
    from eth_account.messages import encode_defunct
    print("\nCompletion")
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": "Reply with the word ok."}],
                       "stream": False, "max_tokens": 16}, separators=(",", ":")).encode()
    raw = gw.request("POST", "/v1/chat/completions", body=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "x-no-aliasing": "true",
        "Accept-Encoding": "identity", "Accept": "application/json"})
    check("completion", "Prompt sent on the attested TLS connection", gw.same_connection())
    chat_id = json.loads(raw)["id"]
    req_h, resp_h = hashlib.sha256(body).hexdigest(), hashlib.sha256(raw).hexdigest()
    sig = None
    for _ in range(5):
        s = requests.get(f"{API}/signature/{chat_id}", params={"signing_algo": "ecdsa"}, timeout=30,
                         headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
        if s.status_code == 200 and "signature" in s.json():
            sig = s.json(); break
        time.sleep(1)
    if not check("completion", "Signature available", sig is not None, chat_id):
        return
    kind = sig.get("signature_kind")
    expected = f"{model}:{req_h}:{resp_h}" if kind == "provider_tee" else f"{req_h}:{resp_h}"
    check("completion", "Signed text covers our exact request and response bytes", sig["text"] == expected, f"kind {kind}")
    rec = Account.recover_message(encode_defunct(text=sig["text"]), signature=sig["signature"])
    signers = model_signers if kind == "provider_tee" else [gateway_signer]
    match = [a for a in signers if a and a.lower() == rec.lower()]
    check("completion", "Signer is the attested " + ("model enclave" if kind == "provider_tee" else "gateway"), len(match) == 1, rec)


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--report", help="verify a saved report instead of fetching one (needs --nonce)")
    ap.add_argument("--nonce", help="the nonce the saved report was fetched with")
    ap.add_argument("--save", help="write the fetched report to this file")
    ap.add_argument("--offline", action="store_true", help="skip the network verifiers (Intel collateral, NVIDIA NRAS)")
    ap.add_argument("--sdk", action="store_true", help="also run NEAR's official SDK verify(model)")
    a = ap.parse_args()

    gw = None
    if a.report:
        if not a.nonce:
            sys.exit("--report needs --nonce")
        nonce, report = a.nonce, json.load(open(a.report))
        print(f"Saved report {a.report}, nonce {nonce}")
    else:
        nonce = secrets.token_hex(32)  # fresh 32 random bytes, generated here
        print(f"Model {a.model}\nNonce {nonce} (fresh, from this machine)")
        gw = Gateway()  # no API key is sent on this connection before the report is verified
        q = urllib.parse.urlencode({"model": a.model, "provider": "near", "signing_algo": "ecdsa", "nonce": nonce,
                                    "include_tls_fingerprint": "true"})
        raw = gw.request("GET", f"/v1/attestation/report?{q}", headers={"Accept": "application/json", "x-no-aliasing": "true"})
        report = json.loads(raw)
        if a.save:
            open(a.save, "wb").write(raw)

    await verify_report("Gateway", report["gateway_attestation"], nonce, a.offline)
    if gw:
        fp = (report["gateway_attestation"].get("tls_cert_fingerprint") or "").lower()
        peer = gw.peer_spki_sha256()
        check("Gateway", "This TLS connection ends at the key the gateway quote binds", fp == peer, f"peer SPKI sha256 {peer[:16]}…")
    models = report.get("model_attestations") or []
    check("Model", "Model evidence returned", bool(models), f"{len(models)} candidate(s)")
    for i, m in enumerate(models):
        await verify_report(f"Model {m.get('model_name', a.model)} #{i + 1}", m, nonce, a.offline)

    key = os.environ.get("NEARAI_API_KEY")
    if key and gw:
        verify_completion(gw, a.model, [m["signing_address"] for m in models], report["gateway_attestation"]["signing_address"], key)
    else:
        print("\nCompletion")
        check("completion", "Response signature", None, "set NEARAI_API_KEY to send one completion and verify its signature")

    if a.sdk and not a.offline:
        print("\nNEAR official SDK (nearai-inference-sdk) verify(model)")
        try:
            try:
                from nearai_inference_sdk import InferenceClient
            except ImportError as e:
                raise RuntimeError("needs Python 3.12+ and: pip install -r near/requirements-sdk.txt") from e
            async with InferenceClient(key) as c:
                v = await c.verify(a.model)
            check("sdk", "SDK gateway verification", True, f"TCB {v.gateway.tcb_status}")
            check("sdk", "SDK model verification", len(v.models) > 0, f"{len(v.models)} verified model report(s)")
            # NEAR's own provenance helper on the gateway's measured compose, with the policy this script used.
            from nearai_inference_sdk import ImageProvenancePolicy, verify_deployment_image_provenance
            gw_compose = _json(report["gateway_attestation"]["info"]["tcb_info"])["app_compose"]
            policies = {k[0]: ImageProvenancePolicy(repository=IMAGE_SOURCES[k[0]], workflow=v[2])
                        for k, v in _provenance.items() if isinstance(k, tuple) and v[0] and f"{k[0]}@sha256:{k[1]}" in gw_compose}
            if policies:
                await verify_deployment_image_provenance(gw_compose, policies, os.environ.get("GITHUB_TOKEN"))
            check("sdk", "SDK image provenance for the gateway's containers", True if policies else None, ", ".join(policies) or "nothing to compare")
        except Exception as e:  # noqa: BLE001
            check("sdk", "SDK verify(model)", False, str(e))

    failed = [r for r in results if r[2] is False]
    print(f"\n{sum(1 for r in results if r[2])} passed, {len(failed)} failed, {sum(1 for r in results if r[2] is None)} skipped")
    print("Not checked here: RTMR0 (the virtual hardware tables) against a recomputed value, who built the images listed as\n"
          "skipped above, whether the logged deployment is still what runs, and the gateway-to-model hop (see docs/NEAR.md).")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    asyncio.run(main())
