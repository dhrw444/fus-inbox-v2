#!/usr/bin/env python3
"""把当前目录推成一个 Git commit（走 GitHub API）。

沙箱里的 git 对象库是坏的（`fatal: invalid mode for object creation: copy`），
所有推送都走 API。

用法：
    python3 tool/push.py "提交信息"
"""
import base64
import json
import os
import subprocess
import sys

REPO = 'dhrw444/fus-inbox-v2'
BRANCH = 'main'
TOKEN = os.environ['GITHUB_TOKEN']

# 不推的目录：构建产物、缓存、旧代码。
SKIP_DIRS = {'.git', '.dart_tool', 'build', '.idea', 'windows/flutter/ephemeral'}
SKIP_FILES = {'.DS_Store'}


def api(method, path, body=None):
    """调一次 API。返回解析后的 JSON。"""
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
    try:
        return json.loads(r.stdout)
    except Exception:
        return {'_raw': r.stdout[:300], '_err': r.stderr[:200]}


def collect():
    """列出要推的文件（相对路径）。"""
    out = []
    for root, dirs, files in os.walk('.'):
        # 用 relpath 而不是 `lstrip('./')` —— 后者是**按字符集**剥离，
        # 会把 `.dart_tool` 削成 `dart_tool`，于是跳过规则永远不命中。
        # （这个坑我踩过：它静默失效，最后在推 `dart_tool/package_config.json`
        #   时才炸出来。）
        rel = os.path.relpath(root)
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


def make_blob(path):
    """把文件变成 blob sha。

    **一律走 base64**，不再区分文本/二进制。

    原来文本走 utf8 是因为「base64 多三分之一体积」，但那点体积换来的是
    **一类静默失败**：`windows/flutter/CMakeLists.txt` 带 BOM、某些文件
    带 CRLF/奇异字符时，utf8 那条路建 blob 会失败 —— 而失败发生在推送
    中途，前面的 blob 已经建好了，重推要重来一遍。

    统一 base64 就没有「哪些文件算文本」这个判断了，也就没有判断错的可能。
    """
    raw = open(path, 'rb').read()
    r = api('POST', '/repos/%s/git/blobs' % REPO,
            {'content': base64.b64encode(raw).decode('ascii'),
             'encoding': 'base64'})
    return r.get('sha')


def main():
    # 提交信息从文件读 —— 多行中文经 shell 传参会撞上解析。
    msg_file = sys.argv[1] if len(sys.argv) > 1 else None
    message = (
        open(msg_file, encoding='utf-8').read()
        if msg_file and os.path.exists(msg_file) else 'update'
    )

    files = collect()
    print('  文件数: %d' % len(files))

    # 远端当前 HEAD（第一次推时仓库是空的）。
    ref = api('GET', '/repos/%s/git/ref/heads/%s' % (REPO, BRANCH))
    base_sha = ref.get('object', {}).get('sha') if 'object' in ref else None

    # **空仓库要先垫一个初始 commit。**
    #
    # GitHub 的 `POST /git/blobs` 在空仓库上直接回 409
    # （`Git Repository is empty.`）—— 它需要仓库里至少有一个 commit
    # 才能建对象。而 `PUT /contents/<path>` 恰好能做这件事：它会顺手
    # 建出初始 commit 和默认分支。
    if not base_sha:
        print('  空仓库：先垫一个初始 commit')
        seed = api('PUT', '/repos/%s/contents/README.md' % REPO, {
            'message': '初始化仓库',
            'content': base64.b64encode('# fus-inbox-v2\n'.encode()).decode(),
        })
        if 'commit' not in seed:
            print('  ✗ 初始 commit 失败: %s' % str(seed)[:300])
            return 1
        ref = api('GET', '/repos/%s/git/ref/heads/%s' % (REPO, BRANCH))
        base_sha = ref.get('object', {}).get('sha')
        if not base_sha:
            print('  ✗ 拿不到初始 commit')
            return 1

    parents = [base_sha]

    tree = []
    for p in files:
        sha = make_blob(p)
        if not sha:
            print('  ✗ blob 失败: %s' % p)
            return 1
        tree.append({'path': p, 'mode': '100755' if os.access(p, os.X_OK) else '100644',
                     'type': 'blob', 'sha': sha})
    print('  blob 完成')

    t = api('POST', '/repos/%s/git/trees' % REPO, {'tree': tree})
    if 'sha' not in t:
        print('  ✗ 建 tree 失败: %s' % str(t)[:300])
        return 1

    c = api('POST', '/repos/%s/git/commits' % REPO,
            {'message': message, 'tree': t['sha'], 'parents': parents})
    if 'sha' not in c:
        print('  ✗ 建 commit 失败: %s' % str(c)[:300])
        return 1
    print('  commit = %s' % c['sha'])

    if base_sha:
        r = api('PATCH', '/repos/%s/git/refs/heads/%s' % (REPO, BRANCH),
                {'sha': c['sha'], 'force': False})
    else:
        r = api('POST', '/repos/%s/git/refs' % REPO,
                {'ref': 'refs/heads/%s' % BRANCH, 'sha': c['sha']})
    if 'object' not in r and 'ref' not in r:
        print('  ✗ 更新 ref 失败: %s' % str(r)[:300])
        return 1
    print('  ✓ %s → %s' % (BRANCH, c['sha'][:12]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
