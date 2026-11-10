#!/usr/bin/env python3
"""Publish a Hermit model to ModelScope (modelscope.cn), the download source for mainland China, then check it.

Needs a ModelScope account that owns the namespace in ModelSource.modelscopeOwner ("HermitAiLabs") and an access
token (modelscope.cn > Account settings > Access Token), in MODELSCOPE_TOKEN or in /home/mm/.secrets/modelscope.env as
MODELSCOPE_TOKEN=... (mode 600). The token is never printed.

  pip install -U modelscope
  python3 scripts/publish-modelscope.py --repo rahulol/Hermit-1.2-4B-MLX-4bit --local <dir>            # upload + check
  python3 scripts/publish-modelscope.py --repo rahulol/Hermit-1.2-4B-MLX-4bit --check-only            # check only

The local folder is checked against the app's pin first (the same bytes as Hugging Face at the pinned commit), so
ModelScope can only receive what the app accepts. The check afterwards fetches every file back from ModelScope and
compares its SHA-256 with the manifest on models.hermit.my. The app verifies every byte against its built-in pin anyway.
"""
import argparse, hashlib, json, os, sys, urllib.request

# Cloudflare's bot check refuses Python's default User-Agent on models.hermit.my
urllib.request.install_opener(urllib.request.build_opener())
urllib.request._opener.addheaders = [('User-Agent', 'hermit-publish/1.0')]

OWNER = 'HermitAiLabs'
MIRROR = 'https://models.hermit.my'
REVISIONS = {  # must match ModelCatalog
    'rahulol/Hermit-1.2-4B-MLX-4bit': '6183aaf929d66dc50f4b7c547d140fca57be54e6',
    'rahulol/Hermit-1.1-Lite-MLX-4bit': '52b8428909ab484f23945d317a32d4a63da57f49',
}


def token():
    t = os.environ.get('MODELSCOPE_TOKEN')
    p = '/home/mm/.secrets/modelscope.env'
    if not t and os.path.exists(p):
        for line in open(p):
            if line.startswith('MODELSCOPE_TOKEN='): t = line.split('=', 1)[1].strip().strip('"\'')
    if not t: raise SystemExit('no ModelScope token: set MODELSCOPE_TOKEN or write /home/mm/.secrets/modelscope.env')
    return t


def manifest(repo):
    with urllib.request.urlopen(f'{MIRROR}/{repo}/{REVISIONS[repo]}/manifest.json', timeout=30) as r:
        return json.load(r)


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(8 << 20), b''): h.update(b)
    return h.hexdigest()


def check_local(m, local):
    for f in m['files']:
        p = os.path.join(local, f['path'])
        if os.path.getsize(p) != f['size'] or sha256_file(p) != f['sha256']:
            raise SystemExit(f'local {f["path"]} does not match the pin')
        print('  local ok', f['path'], file=sys.stderr)


def upload(repo, m, local):
    from modelscope.hub.api import HubApi
    api = HubApi()
    api.login(token())
    target = f'{OWNER}/{repo.split("/")[1]}'
    try:
        api.create_repo(target, repo_type='model', visibility='public', license='apache-2.0', exist_ok=True)
    except TypeError:   # older SDKs
        from modelscope.hub.constants import Licenses, ModelVisibility
        try: api.create_model(target, visibility=ModelVisibility.PUBLIC, license=Licenses.APACHE_V2)
        except Exception as e:
            if 'exist' not in str(e).lower(): raise
    # Only the files the app downloads, plus the README for the model card.
    allow = [f['path'] for f in m['files']]
    if os.path.exists(os.path.join(local, 'README.md')): allow.append('README.md')
    api.upload_folder(repo_id=target, folder_path=local, allow_patterns=allow,
                      commit_message=f'Hermit release {REVISIONS[repo][:7]} (same files as huggingface.co/{repo})')
    print('uploaded to', target, file=sys.stderr)


def check_remote(repo, m):
    target = f'{OWNER}/{repo.split("/")[1]}'
    bad = 0
    for f in m['files']:
        url = f'https://www.modelscope.cn/models/{target}/resolve/master/{f["path"]}'
        h, n = hashlib.sha256(), 0
        with urllib.request.urlopen(url, timeout=120) as r:
            for b in iter(lambda: r.read(8 << 20), b''): h.update(b); n += len(b)
        ok = n == f['size'] and h.hexdigest() == f['sha256']
        bad += not ok
        print(f'  {"ok " if ok else "BAD"} {f["path"]} {n}', file=sys.stderr)
    # Byte ranges, which the app uses for pieces.
    big = max(m['files'], key=lambda f: f['size'])
    req = urllib.request.Request(f'https://www.modelscope.cn/models/{target}/resolve/master/{big["path"]}', headers={'Range': 'bytes=0-1023'})
    with urllib.request.urlopen(req, timeout=60) as r:
        print('  range request:', r.status, len(r.read()), 'bytes', file=sys.stderr)
    if bad: raise SystemExit(f'{bad} file(s) differ on ModelScope')
    print('ModelScope matches the pin', file=sys.stderr)


if __name__ == '__main__':
    a = argparse.ArgumentParser()
    a.add_argument('--repo', required=True, choices=sorted(REVISIONS))
    a.add_argument('--local')
    a.add_argument('--check-only', action='store_true')
    args = a.parse_args()
    m = manifest(args.repo)
    if not args.check_only:
        if not args.local: raise SystemExit('--local is required to upload')
        check_local(m, args.local)
        upload(args.repo, m, args.local)
    check_remote(args.repo, m)
