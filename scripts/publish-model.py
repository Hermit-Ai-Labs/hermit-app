#!/usr/bin/env python3
"""Publish a Hermit model to the download mirror (models.hermit.my, Cloudflare R2) and print its in-app pin.

  sudo -n python3 scripts/publish-model.py --repo rahulol/Hermit-1.2-4B-MLX-4bit --revision <hf commit> --local <dir> [--upload]

1. Lists the Hugging Face repo at that exact commit and checks every local file against it (LFS files by sha256, the
   rest by git blob sha1), so the mirror can only ever hold the bytes Hugging Face has.
2. Cuts files over PIECE bytes into pieces of PIECE bytes and hashes each one. Pieces are what the app downloads in
   parallel, and each stays under Cloudflare's 512 MB cache limit so it is served from the nearest edge, not the bucket.
3. With --upload, puts <repo>/<revision>/<file> (small files), <repo>/<revision>/<file>.parts/<NNN>.bin (pieces) and
   <repo>/<revision>/manifest.json in the R2 bucket, all immutable with a one-year cache. Objects already there with
   the right size are skipped.
4. Prints the model's entry for `ModelPins.all` (Packages/HermitKit/Sources/HermitModel/ModelPins.swift); paste it
   there and set the same revision on the model in ModelCatalog. The app checks every byte against the pin, whatever
   source it came from. Then publish the same folder to ModelScope (scripts/publish-modelscope.py) for mainland China.

R2 credentials come from the house Cloudflare config (CF_CONFIG), read as root and never printed.
"""
import argparse, hashlib, json, os, sys, urllib.request

PIECE = 128 << 20          # 128 MiB
BUCKET = 'hermit-models'
CF_CONFIG = os.environ.get('CF_CONFIG', '/home/ubuntu2/.config/cloudflare.json')


def wanted(path):  # same rule as ModelCatalog.wanted
    return '/' not in path and path.endswith(('.safetensors', '.json', '.jinja'))


def hf_tree(repo, rev):
    with urllib.request.urlopen(f'https://huggingface.co/api/models/{repo}/tree/{rev}', timeout=60) as r:
        return [f for f in json.load(r) if f['type'] == 'file' and wanted(f['path'])]


def sha256_range(path, start, length):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        f.seek(start)
        left = length
        while left:
            b = f.read(min(8 << 20, left))
            if not b: raise SystemExit(f'{path}: short read')
            h.update(b); left -= len(b)
    return h.hexdigest()


def git_blob_sha1(path):
    data = open(path, 'rb').read()
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def build_manifest(repo, rev, local):
    files = []
    for f in sorted(hf_tree(repo, rev), key=lambda f: f['size']):
        p = os.path.join(local, f['path'])
        if not os.path.exists(p): raise SystemExit(f'missing locally: {f["path"]}')
        size = os.path.getsize(p)
        if size != f['size']: raise SystemExit(f'{f["path"]}: size {size} != HF {f["size"]}')
        sha = sha256_range(p, 0, size)
        if f.get('lfs'):
            if sha != f['lfs']['oid']: raise SystemExit(f'{f["path"]}: sha256 differs from HF lfs.oid')
        elif git_blob_sha1(p) != f['oid']:
            raise SystemExit(f'{f["path"]}: git blob differs from HF')
        entry = {'path': f['path'], 'size': size, 'sha256': sha}
        if size > PIECE:
            entry['pieces'] = [sha256_range(p, o, min(PIECE, size - o)) for o in range(0, size, PIECE)]
        files.append(entry)
        print(f'  ok {f["path"]} {size}' + (f' ({len(entry["pieces"])} pieces)' if 'pieces' in entry else ''), file=sys.stderr)
    return {'model': repo, 'revision': rev, 'pieceSize': PIECE, 'files': files}


def upload(manifest, local):
    import boto3
    from botocore.config import Config
    C = json.load(open(CF_CONFIG))
    s3 = boto3.client('s3', endpoint_url=C['r2_endpoint'], aws_access_key_id=C['r2_access_key'],
                      aws_secret_access_key=C['r2_secret'], region_name='auto',
                      config=Config(retries={'max_attempts': 5}))
    prefix = f'{manifest["model"]}/{manifest["revision"]}'
    cache = 'public, max-age=31536000, immutable'

    def put(key, body, ctype):
        try:
            if s3.head_object(Bucket=BUCKET, Key=key)['ContentLength'] == len(body):
                print(f'  have {key}', file=sys.stderr); return
        except s3.exceptions.ClientError:
            pass
        s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType=ctype, CacheControl=cache)
        print(f'  put  {key} {len(body)}', file=sys.stderr)

    from concurrent.futures import ThreadPoolExecutor
    jobs = []
    for f in manifest['files']:
        p = os.path.join(local, f['path'])
        if 'pieces' in f:
            for i in range(len(f['pieces'])):
                jobs.append((f'{prefix}/{f["path"]}.parts/{i:03d}.bin', p, i * PIECE, min(PIECE, f['size'] - i * PIECE), 'application/octet-stream'))
        else:
            ctype = 'application/json' if f['path'].endswith('.json') else 'text/plain; charset=utf-8'
            jobs.append((f'{prefix}/{f["path"]}', p, 0, f['size'], ctype))

    def run(job):
        key, p, start, length, ctype = job
        with open(p, 'rb') as fh:
            fh.seek(start); body = fh.read(length)
        put(key, body, ctype)

    with ThreadPoolExecutor(4) as pool:
        list(pool.map(run, jobs))
    put(f'{prefix}/manifest.json', json.dumps(manifest, indent=1).encode(), 'application/json')


def swift_pin(m):
    lines = [f'        ModelPin(revision: "{m["revision"]}", pieceSize: {m["pieceSize"]}, files: [']
    for f in m['files']:
        pieces = ''
        if 'pieces' in f:
            pieces = ', pieces: [\n' + ''.join(f'                "{h}",\n' for h in f['pieces']) + '            ]'
        lines.append(f'            .init(path: "{f["path"]}", size: {f["size"]}, sha256: "{f["sha256"]}"{pieces}),')
    lines.append('        ]),')
    return f'    // {m["model"]}\n    "{m["model"]}":\n' + '\n'.join(lines)


if __name__ == '__main__':
    a = argparse.ArgumentParser()
    a.add_argument('--repo', required=True)
    a.add_argument('--revision', required=True, help='full Hugging Face commit sha')
    a.add_argument('--local', required=True)
    a.add_argument('--upload', action='store_true')
    a.add_argument('--manifest-out')
    args = a.parse_args()
    m = build_manifest(args.repo, args.revision, args.local)
    if args.manifest_out:
        json.dump(m, open(args.manifest_out, 'w'), indent=1)
    if args.upload:
        upload(m, args.local)
    print(swift_pin(m))
