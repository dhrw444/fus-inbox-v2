#!/usr/bin/env python3
"""推送后校验：逐个文件比对本地与远端的 md5 + sha256。

## 为什么不能只看推送脚本打印的 ✓

`push.py` 打印 `✓ main → 9677b6d8` 的时候，实际情况是：
- 提交信息丢了（变成 `update`）
- 远端残留 45 个本地已删的文件
- 远端 142 个文件 vs 本地 97 个

「命令成功返回」和「内容真的对」是两件事。

## 三条判据，全过才算一致

1. **数量一致** —— 远端文件数 == 本地文件数。多出来的是删了没同步的残留
2. **md5 一致** —— 逐文件。md5 快，先用来筛
3. **sha256 一致** —— 逐文件。GitHub 只给 blob 的 sha1，md5/sha256 得自己算

用法：
    python3 tool/verify_remote.py
"""

import base64
import hashlib
import json
import os
import subprocess
import sys

REPO = 'dhrw444/fus-inbox-v2'
BRANCH = 'main'
TOKEN = os.environ['GITHUB_TOKEN']

SKIP_DIRS = {'.git', '.dart_tool', 'build', '.idea', 'windows/flutter/ephemeral'}
SKIP_FILES = {'.DS_Store'}


def api(path):
    r = subprocess.run(
        ['curl', '-sS', '--max-time', '120',
         '-H', 'Authorization: Bearer ' + TOKEN,
         '-H', 'Accept: application/vnd.github+json',
         'https://api.github.com' + path],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError('curl 失败: %s' % r.stderr.strip()[:200])
    return json.loads(r.stdout)


def local_files():
    out = []
    for root, dirs, files in os.walk('.'):
        dirs[:] = [
            d for d in dirs
            if os.path.relpath(os.path.join(root, d)) not in SKIP_DIRS
        ]
        for f in files:
            if f in SKIP_FILES:
                continue
            p = os.path.relpath(os.path.join(root, f))
            if any(p == s or p.startswith(s + os.sep) for s in SKIP_DIRS):
                continue
            out.append(p)
    return sorted(out)


def hashes(raw):
    return hashlib.md5(raw).hexdigest(), hashlib.sha256(raw).hexdigest()


def fetch_blob(sha):
    d = api('/repos/%s/git/blobs/%s' % (REPO, sha))
    if 'content' not in d:
        raise RuntimeError('blob %s 拿不到: %s' % (sha[:8], str(d)[:160]))
    return base64.b64decode(d['content'])


def main():
    files = local_files()
    print('  本地文件: %d' % len(files))

    ref = api('/repos/%s/git/ref/heads/%s' % (REPO, BRANCH))
    if 'object' not in ref:
        print('  ✗ 拿不到远端 ref: %s' % str(ref)[:200])
        return 1
    head = ref['object']['sha']
    print('  远端 HEAD: %s' % head[:12])

    commit = api('/repos/%s/git/commits/%s' % (REPO, head))
    tree = api('/repos/%s/git/trees/%s?recursive=1' % (REPO, commit['tree']['sha']))
    remote = {t['path']: t['sha'] for t in tree.get('tree', []) if t['type'] == 'blob'}
    print('  远端文件: %d' % len(remote))
    print()

    # ── 判据 1：数量 ──
    only_local = sorted(set(files) - set(remote))
    only_remote = sorted(set(remote) - set(files))
    print('  ── 判据 1：数量 ──')
    print('    本地独有: %d 个' % len(only_local))
    for p in only_local[:10]:
        print('      + %s' % p)
    print('    远端独有: %d 个' % len(only_remote))
    for p in only_remote[:10]:
        print('      - %s' % p)
    count_ok = not only_local and not only_remote
    print('    结果: %s' % ('✓ 一致' if count_ok else '✗ 不一致'))

    # ── 判据 2/3：逐文件 md5 + sha256 ──
    print()
    print('  ── 判据 2/3：md5 + sha256 ──')
    md5_bad, sha_bad = [], []
    checked = 0
    for p in files:
        if p not in remote:
            continue
        raw_local = open(p, 'rb').read()
        lmd5, lsha = hashes(raw_local)
        raw_remote = fetch_blob(remote[p])
        rmd5, rsha = hashes(raw_remote)
        checked += 1
        if lmd5 != rmd5:
            md5_bad.append(p)
        if lsha != rsha:
            sha_bad.append(p)
    print('    逐文件比对: %d 个' % checked)
    print('    md5 不一致: %d 个' % len(md5_bad))
    for p in md5_bad[:10]:
        print('      ! %s' % p)
    print('    sha256 不一致: %d 个' % len(sha_bad))
    for p in sha_bad[:10]:
        print('      ! %s' % p)

    print()
    all_ok = count_ok and not md5_bad and not sha_bad and checked == len(files)
    if all_ok:
        print('  ✓ 全部一致：%d 个文件，数量/md5/sha256 三项全过' % len(files))
        return 0
    print('  ✗ 校验未通过')
    return 1


if __name__ == '__main__':
    sys.exit(main())
