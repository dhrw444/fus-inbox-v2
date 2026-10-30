#!/usr/bin/env python3
"""把当前目录推成一个 Git commit（走 GitHub API）。

沙箱里的 git 对象库是坏的（`fatal: invalid mode for creation: copy`），
所有推送都走 API。

用法：
    python3 tool/push.py "提交信息"           # 直接给字符串
    python3 tool/push.py -f /tmp/msg.txt      # 从文件读（多行更稳）

## 三条硬约束（都是踩过坑之后加的）

**① 拿不到远端 ref 就停下，不许兜底。**

原来那段「空仓库 → 垫一个初始 commit」的逻辑差点把历史搞乱：一次
`Connection reset by peer` 让 `GET /git/ref/heads/main` 返回空，脚本
当成「仓库是空的」，建了个 `初始化仓库` 提交并 PATCH 了 main。

网络抖动和真空仓库从外面看起来一样，但后者几乎从不发生、前者经常发生。
兜底分支会把一次网络故障变成一次历史改写。

**② 本地删掉的文件，远端也要删。**

GitHub 建 tree 时，`{'path': ..., 'sha': None}` 就是删除标记。
原来只 add 不 delete，于是本地删了文件、远端永远留着 —— 一次推完
本地 97 个文件、远端 142 个，多出 45 个幽灵。

**③ 提交信息按字符串优先。**

`sys.argv[1]` 原来被当成文件路径：传字符串进去它读不到文件，就静默
退回 `'update'`，于是整条提交信息丢了。
"""

import base64
import json
import os
import subprocess
import sys

REPO = 'dhrw444/fus-inbox-v2'
BRANCH = 'main'
TOKEN = os.environ['GITHUB_TOKEN']

# 不推的目录：构建产物、缓存。
SKIP_DIRS = {'.git', '.dart_tool', 'build', '.idea', 'windows/flutter/ephemeral'}
SKIP_FILES = {'.DS_Store'}


def api(method, path, body=None):
    """调一次 API。网络失败时抛异常，不返回空 dict。"""
    args = [
        'curl', '-sS', '--max-time', '120', '-X', method,
        '-H', 'Authorization: Bearer ' + TOKEN,
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'Content-Type: application/json',
        'https://api.github.com' + path,
    ]
    if body is not None:
        args += ['--data-binary', '@-']
    r = subprocess.run(
        args, input=json.dumps(body) if body is not None else None,
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError('curl 失败(%d): %s' % (r.returncode, r.stderr.strip()[:200]))
    try:
        return json.loads(r.stdout)
    except Exception:
        raise RuntimeError('返回不是 JSON: %s' % r.stdout[:200])


def collect():
    """列出要推的文件（相对路径，排序）。"""
    out = []
    for root, dirs, files in os.walk('.'):
        # 用 relpath 而不是 `lstrip('./')` —— 后者按**字符集**剥离，
        # 会把 `.dart_tool` 削成 `dart_tool`，跳过规则永远不命中。
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


def remote_paths(tree_sha):
    """远端当前 tree 里的全部文件路径。"""
    d = api('GET', '/repos/%s/git/trees/%s?recursive=1' % (REPO, tree_sha))
    return {t['path'] for t in d.get('tree', []) if t['type'] == 'blob'}


def make_blob(path):
    """把文件变成 blob sha。

    一律走 base64，不区分文本/二进制。原来文本走 utf8 是为了省三分之一体积，
    但换来一类静默失败：带 BOM 或 CRLF 的文件建 blob 会失败，而失败发生在
    推送中途 —— 前面的 blob 已建好，重推要重来一遍。
    """
    raw = open(path, 'rb').read()
    r = api('POST', '/repos/%s/git/blobs' % REPO,
            {'content': base64.b64encode(raw).decode('ascii'),
             'encoding': 'base64'})
    return r.get('sha')


def main():
    # 提交信息：-f 走文件，否则当字符串。字符串**直接就是信息**，不当路径试。
    if len(sys.argv) > 1 and sys.argv[1] == '-f' and len(sys.argv) > 2:
        message = open(sys.argv[2], encoding='utf-8').read()
    elif len(sys.argv) > 1:
        message = sys.argv[1]
    else:
        message = 'update'

    files = collect()
    print('  本地文件数: %d' % len(files))

    # ── 拿远端 HEAD。失败就停，不兜底 ──
    ref = api('GET', '/repos/%s/git/ref/heads/%s' % (REPO, BRANCH))
    if 'object' not in ref:
        print('  ✗ 拿不到 %s 的 ref: %s' % (BRANCH, str(ref)[:200]))
        print('  网络问题还是真空仓库？先重跑一次再判断。不自动兜底。')
        return 1
    base_sha = ref['object']['sha']
    print('  远端 HEAD: %s' % base_sha[:12])

    base_commit = api('GET', '/repos/%s/git/commits/%s' % (REPO, base_sha))
    base_tree = base_commit['tree']['sha']
    remote = remote_paths(base_tree)
    print('  远端文件数: %d' % len(remote))

    # ── 建 tree：改动/新增带 blob，本地已删的带 sha=None ──
    tree = []
    for p in files:
        sha = make_blob(p)
        if not sha:
            print('  ✗ blob 失败: %s' % p)
            return 1
        tree.append({
            'path': p,
            'mode': '100755' if os.access(p, os.X_OK) else '100644',
            'type': 'blob',
            'sha': sha,
        })
    print('  blob 完成: %d 个' % len(files))

    gone = sorted(remote - set(files))
    for p in gone:
        tree.append({'path': p, 'mode': '100644', 'type': 'blob', 'sha': None})
    if gone:
        print('  删除远端残留: %d 个' % len(gone))
        for p in gone[:8]:
            print('    - %s' % p)
        if len(gone) > 8:
            print('    ... 还有 %d 个' % (len(gone) - 8))

    t = api('POST', '/repos/%s/git/trees' % REPO, {'tree': tree})
    if 'sha' not in t:
        print('  ✗ 建 tree 失败: %s' % str(t)[:300])
        return 1

    c = api('POST', '/repos/%s/git/commits' % REPO,
            {'message': message, 'tree': t['sha'], 'parents': [base_sha]})
    if 'sha' not in c:
        print('  ✗ 建 commit 失败: %s' % str(c)[:300])
        return 1
    print('  commit = %s' % c['sha'])

    r = api('PATCH', '/repos/%s/git/refs/heads/%s' % (REPO, BRANCH),
            {'sha': c['sha'], 'force': False})
    if 'object' not in r:
        print('  ✗ 更新 ref 失败: %s' % str(r)[:300])
        return 1
    print('  ✓ %s → %s' % (BRANCH, c['sha'][:12]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
